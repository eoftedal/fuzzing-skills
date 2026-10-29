#!/bin/bash
# Route 3b: build ONE variant of a system library the binding links, from its source tree,
# as an instrumented STATIC archive the harness links instead of the distro's shared object.
#
#   build_lib.sh VARIANT=plain|asan|pristine SRC=<library source dir> [OUT=$W/out]
#       [BUILD=cmake|meson|autotools|make]   (default: detected from SRC)
#       [CMAKE_ARGS="..."] [MESON_ARGS="..."] [CONFIGURE_ARGS="..."] [MAKE_ARGS="..."]
#       [TARGET=<make/ninja target>] [ARCHIVES="libfoo.a src/libbar.a"] [INC=<header dir>]
#       [EXTRA_CFLAGS="..."] [JOBS=N] [FRESH=1]
#
#   plain     afl-clang-fast                          (AFL_LLVM_DICT2FILE recorded)
#   asan      afl-clang-fast + AFL_USE_ASAN=1         (AFL_LLVM_DICT2FILE recorded)
#   pristine  clang -fsanitize=address, no AFL at all (triage's control build)
#
# Products, per variant:
#   OUT/<v>/lib-build/          the build tree (out of SRC, so SRC stays pristine and a
#                               self-test fault patched into SRC is picked up by a rebuild)
#   OUT/<v>/lib-build/build_lib.args   this run's arguments; rebuild_asan.sh replays them
#   OUT/<v>/lib/<archive>.a     what link_harness.sh links (LIB=) and derives ARCHIVE_LIBS from
#   OUT/<v>/lib/include/        SRC's public headers (INC=, else SRC/include, else SRC/*.h)
#                               plus the build tree's generated config headers, so the
#                               harness compiles against THIS build, not the distro's headers
#                               (link_harness.sh puts it first on the include path)
#   OUT/<v>/dict2file-lib.raw   the library's compare constants (build_addon.sh keeps it;
#                               link_harness.sh merges it into dict.afl)
# build_addon.sh keeps OUT/<v>/lib/ and dict2file-lib.raw, so the order of the two scripts
# does not matter.
#
#   CMAKE_ARGS  cmake always gets -DBUILD_SHARED_LIBS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5
#               (cmake 4 refuses projects that declare an older minimum) and
#               -DCMAKE_POSITION_INDEPENDENT_CODE=ON.  A project with its own static/shared
#               switches needs them here too (-DENABLE_SHARED=OFF -DENABLE_STATIC=ON style:
#               read its CMakeLists.txt `option(` lines), and TARGET= its static target
#               when the default target builds tools or tests as well.
#   CONFIGURE_ARGS  autotools always gets --disable-shared --enable-static; a tree with no
#               configure but a configure.ac / autogen.sh is bootstrapped first.
#   ARCHIVES    which archives to copy, as paths relative to the build tree or basenames
#               searched in it (default: every lib*.a in it).
#   FRESH=1     wipe the build tree and configure again.  Otherwise a re-run with the same
#               arguments only rebuilds what changed (the self-test's REBUILD).
#
# ABI: the distro's shared library was configured with options of its own, and a config
# header that differs (a library-version macro selecting the struct layout, say) makes the
# harness, the addon objects it links, and the archive disagree on structures.  After the
# build this script compares every generated header with a same-named one under
# /usr/include and prints the VERSION/ABI macros that differ; pass the option that makes
# them match via CMAKE_ARGS / CONFIGURE_ARGS and build again (new arguments start a fresh tree).
set -uo pipefail
for kv in "$@"; do case $kv in WORKSPACE=*) WORKSPACE=${kv#*=};; esac; done
WS=${WORKSPACE:-.}; [ -f "$WS/fuzz.env" ] && { set -a; . "$WS/fuzz.env"; set +a; }
ARGS=()
for kv in "$@"; do case $kv in *=*) export "$kv"; case ${kv%%=*} in VARIANT|OUT|WORKSPACE|FRESH|JOBS) ;; *) ARGS+=("$kv");; esac;; esac; done
VARIANT=${VARIANT:?set VARIANT=plain|asan|pristine}
SRC=${SRC:?set SRC=<library source dir>}
SRC=$(cd "$SRC" 2>/dev/null && pwd) || { echo "FAIL: SRC=$SRC is not a directory" >&2; exit 2; }
OUT=${OUT:-${W:+$W/out}}; OUT=${OUT:-out}
mkdir -p "$OUT/$VARIANT" && OUT=$(cd "$OUT" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
JOBS=${JOBS:-$(nproc)}
D=$OUT/$VARIANT; B=$D/lib-build; L=$D/lib

UNDEF="-include $HERE/undef_fuzzmode.h"
case $VARIANT in
  plain)    CC_=afl-clang-fast; CXX_=afl-clang-fast++; unset AFL_USE_ASAN; CF="$UNDEF" ;;
  asan)     CC_=afl-clang-fast; CXX_=afl-clang-fast++; export AFL_USE_ASAN=1
            CF="$UNDEF -fsanitize=address -fno-omit-frame-pointer" ;;
  pristine) CC_=clang; CXX_=clang++; unset AFL_USE_ASAN; CF="-fsanitize=address -fno-omit-frame-pointer" ;;
  *) echo "FAIL: VARIANT must be plain|asan|pristine" >&2; exit 2 ;;
esac
CF="-g -O2 -fPIC $CF ${EXTRA_CFLAGS:-}"
export CC=$CC_ CXX=$CXX_ CFLAGS="$CF" CXXFLAGS="$CF" AFL_QUIET=1
if [ "$VARIANT" = pristine ]; then unset AFL_LLVM_DICT2FILE AFL_LLVM_DICT2FILE_NO_MAIN
else export AFL_LLVM_DICT2FILE=$D/dict2file-lib.raw AFL_LLVM_DICT2FILE_NO_MAIN=1; fi

BUILD=${BUILD:-}
if [ -z "$BUILD" ]; then
  if   [ -f "$SRC/CMakeLists.txt" ]; then BUILD=cmake
  elif [ -f "$SRC/meson.build" ]; then BUILD=meson
  elif [ -x "$SRC/configure" ] || [ -f "$SRC/configure.ac" ] || [ -f "$SRC/configure.in" ]; then BUILD=autotools
  elif [ -f "$SRC/Makefile" ] || [ -f "$SRC/makefile" ]; then BUILD=make
  else echo "FAIL: no CMakeLists.txt, meson.build, configure(.ac) or Makefile in $SRC; pass BUILD=" >&2; exit 2; fi
  echo "  build system: $BUILD (detected; BUILD= overrides)"
fi
GEN=""; command -v ninja >/dev/null 2>&1 && GEN="-G Ninja"

# same arguments as the last configure -> incremental; anything else -> a fresh tree
ARGF=$B/build_lib.args
NEWARGS=$(printf '%s\n' "${ARGS[@]}" | grep -v '^BUILD='; echo "BUILD=$BUILD")
if [ "${FRESH:-0}" = 1 ] || [ ! -f "$ARGF" ] || [ "$(cat "$ARGF")" != "$NEWARGS" ]; then
  [ -d "$B" ] && echo "  fresh build tree ($([ "${FRESH:-0}" = 1 ] && echo FRESH=1 || echo 'arguments changed'))"
  rm -rf "$B"; mkdir -p "$B"; rm -f "$D/dict2file-lib.raw"; CONFIGURE=1
  # what this script put in lib/ last time (an archive build_addon.sh copied there stays)
  if [ -f "$L/.from-build_lib" ]; then
    while IFS= read -r f; do [ -n "$f" ] && rm -f "$L/$f"; done < "$L/.from-build_lib"; rm -rf "$L/.from-build_lib" "$L/include"
  fi
else echo "  incremental: same arguments as $ARGF (FRESH=1 to start over)"; CONFIGURE=0; fi
LOG=$B/build.log

echo "== configure + build ($VARIANT, $BUILD) in $B =="
run() { echo "+ $*" >> "$LOG"; "$@" >> "$LOG" 2>&1; }
fail() { echo "FAIL: $1; see $LOG" >&2; grep -m8 -E 'error|Error|CMake Error|not found' "$LOG" | cut -c1-160 | sed 's/^/      /' >&2; exit 1; }
case $BUILD in
  cmake)
    if [ "$CONFIGURE" = 1 ]; then
      # shellcheck disable=SC2086
      run cmake -S "$SRC" -B "$B" $GEN -DCMAKE_C_COMPILER="$CC_" -DCMAKE_CXX_COMPILER="$CXX_" \
          -DCMAKE_BUILD_TYPE=None -DCMAKE_C_FLAGS="$CF" -DCMAKE_CXX_FLAGS="$CF" \
          -DBUILD_SHARED_LIBS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
          ${CMAKE_ARGS:-} || fail "cmake configure"
    fi
    run cmake --build "$B" -j "$JOBS" ${TARGET:+--target $TARGET} || fail "cmake build${TARGET:+ (target $TARGET)}" ;;
  meson)
    if [ "$CONFIGURE" = 1 ]; then
      run meson setup "$B" "$SRC" --default-library=static --buildtype=plain ${MESON_ARGS:-} || fail "meson setup"
    fi
    run ninja -C "$B" -j "$JOBS" ${TARGET:-} || fail "ninja${TARGET:+ $TARGET}" ;;
  autotools)
    if [ -f "$SRC/config.status" ]; then
      echo "FAIL: $SRC was configured in-tree (config.status): an out-of-tree build refuses it." >&2
      echo "      Run 'make distclean' there, or copy the source to a fresh directory, and pass that as SRC=." >&2; exit 1
    fi
    if [ ! -x "$SRC/configure" ]; then
      echo "  bootstrapping: no configure script in $SRC"
      if [ -x "$SRC/autogen.sh" ]; then (cd "$SRC" && NOCONFIGURE=1 ./autogen.sh) >> "$LOG" 2>&1 || fail "autogen.sh"
      else (cd "$SRC" && autoreconf -fi) >> "$LOG" 2>&1 || fail "autoreconf -fi"; fi
    fi
    if [ "$CONFIGURE" = 1 ]; then
      # shellcheck disable=SC2086
      (cd "$B" && run "$SRC/configure" --disable-shared --enable-static CC="$CC_" CXX="$CXX_" CFLAGS="$CF" CXXFLAGS="$CF" ${CONFIGURE_ARGS:-}) \
        || fail "configure"
    fi
    # shellcheck disable=SC2086
    run make -C "$B" -j "$JOBS" ${MAKE_ARGS:-} ${TARGET:-} || fail "make${TARGET:+ $TARGET}" ;;
  make)
    # no out-of-tree support: the tree is copied (again on every run, so a patched SRC file
    # is newer than its object and make rebuilds it)
    cp -a "$SRC/." "$B/" || fail "copying $SRC"
    # shellcheck disable=SC2086
    run make -C "$B" -j "$JOBS" CC="$CC_" CXX="$CXX_" CFLAGS="$CF" CXXFLAGS="$CF" ${MAKE_ARGS:-} ${TARGET:-} || fail "make${TARGET:+ $TARGET}" ;;
  *) echo "FAIL: BUILD must be cmake|meson|autotools|make" >&2; exit 2 ;;
esac
printf '%s\n' "$NEWARGS" > "$ARGF"

echo "== archives -> $L =="
arch=()
if [ -n "${ARCHIVES:-}" ]; then
  for a in $ARCHIVES; do
    if [ -f "$B/$a" ]; then arch+=("$B/$a")
    else f=$(find "$B" -name "$(basename "$a")" -type f -not -path '*/CMakeFiles/*' | head -1)
         [ -n "$f" ] && arch+=("$f") || fail "archive $a not found in $B (ARCHIVES= relative to the build tree, or a basename)"; fi
  done
else
  while IFS= read -r f; do arch+=("$f"); done < <(find "$B" -name 'lib*.a' -type f -not -path '*/CMakeFiles/*' | sort)
  [ ${#arch[@]} -gt 0 ] || fail "no lib*.a in $B (a TARGET= that builds the static library? a CMAKE_ARGS/CONFIGURE_ARGS switch that enables it?)"
fi
mkdir -p "$L/include"
: > "$L/.from-build_lib"
for a in "${arch[@]}"; do cp "$a" "$L/" && basename "$a" >> "$L/.from-build_lib" && echo "  $(basename "$a")  ($(du -k "$a" | cut -f1) KB, from ${a#$B/})"; done
# headers: SRC's public ones first, then the build's generated ones (which win on a name clash)
if [ -n "${INC:-}" ]; then
  case $INC in /*) ID=$INC;; *) ID=$SRC/$INC;; esac
  [ -d "$ID" ] || fail "INC=$INC is not a directory"
  cp -a "$ID/." "$L/include/"
elif [ -d "$SRC/include" ]; then cp -a "$SRC/include/." "$L/include/"
else find "$SRC" -maxdepth 1 -name '*.h' -exec cp {} "$L/include/" \; ; fi
# every header in an out-of-tree build tree was generated by the build (a config header)
GENH=""
[ "$BUILD" != make ] && GENH=$(find "$B" -maxdepth 3 -name '*.h' -type f -not -path '*/CMakeFiles/*' | sort)
for h in $GENH; do cp "$h" "$L/include/"; done
echo "  headers: $(find "$L/include" -name '*.h' | wc -l) in $L/include ($(wc -w <<<"$GENH") generated by the build: $(for h in $GENH; do basename "$h"; done | paste -sd' ' -))"

echo "== verify =="
st=0
for a in "${arch[@]}"; do
  n=$(basename "$a"); syms=$(nm "$L/$n" 2>/dev/null)
  cov=$(grep -cE '__sanitizer_cov|__afl_' <<<"$syms"); asan=$(grep -c '__asan_report' <<<"$syms")
  case $VARIANT in
    plain)    [ "$cov" -gt 0 ] && echo "  ok: $n instrumented ($cov coverage references)" || { echo "  FAIL: $n has no __sanitizer_cov/__afl references: the compiler was not afl-clang-fast (a hard-coded CC in the project?)" >&2; st=1; } ;;
    asan)     [ "$cov" -gt 0 ] && [ "$asan" -gt 0 ] && echo "  ok: $n instrumented ($cov coverage, $asan ASAN references)" \
                || { echo "  FAIL: $n: coverage=$cov asan=$asan references; both must be non-zero" >&2; st=1; } ;;
    pristine) [ "$cov" = 0 ] && [ "$asan" -gt 0 ] && echo "  ok: $n uninstrumented by AFL ($asan ASAN references, no coverage)" \
                || { echo "  FAIL: $n: coverage=$cov (must be 0) asan=$asan (must be >0)" >&2; st=1; } ;;
  esac
done
[ "$VARIANT" != pristine ] && [ -s "$D/dict2file-lib.raw" ] && echo "  dict: $(wc -l < "$D/dict2file-lib.raw") raw compare constants in $D/dict2file-lib.raw (link_harness.sh merges them into dict.afl)"

echo "== ABI: the build's generated headers against the distro's =="
nabi=0
# "<macro>\t<distro value>\t<build value>" for every #define whose value differs
defdiff() { awk 'FNR == 1 { f++ }
  /^[ \t]*#[ \t]*define[ \t]+[A-Za-z_]/ { l = $0; sub(/\/\*.*/, "", l); sub(/^[ \t]*#[ \t]*define[ \t]+/, "", l)
    k = l; sub(/[ \t].*/, "", k); v = l; sub(/^[^ \t]+[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
    if (v == "") v = "(empty)"; val[f, k] = v; keys[k] = 1 }
  END { for (k in keys) { a = ((1, k) in val) ? val[1, k] : "(undefined)"; b = ((2, k) in val) ? val[2, k] : "(undefined)"
          if (a != b) print k "\t" a "\t" b } }' "$1" "$2" | LC_ALL=C sort; }
for h in $GENH; do
  hn=$(basename "$h")
  sys=$(find /usr/include /usr/local/include -name "$hn" -type f 2>/dev/null | head -1)
  [ -n "$sys" ] || continue
  diffs=$(defdiff "$sys" "$h")
  key=$(grep -E '^[A-Za-z0-9_]*(VERSION|ABI)[A-Za-z0-9_]*'$'\t' <<<"$diffs")
  echo "  $hn: distro $sys vs build: $(grep -c . <<<"$diffs") macro(s) differ"
  if [ -n "$key" ]; then
    nabi=$((nabi + 1))
    while IFS=$'\t' read -r k sv bv; do echo "    MISMATCH $k: distro $sv, build $bv"; done <<<"$key"
  fi
done
if [ "$nabi" -gt 0 ]; then
  echo "  WARN: a VERSION/ABI macro differs from the distro build the addon was compiled against: the archive"
  echo "        is a different ABI.  Find the option that sets it (grep the macro in $SRC's CMakeLists.txt /"
  echo "        configure.ac / meson_options.txt), pass it via CMAKE_ARGS/CONFIGURE_ARGS and re-run (new arguments start a fresh tree)"
else
  echo "  (no VERSION/ABI macro differs$([ -z "$GENH" ] && echo '; no generated header to compare'). Still compare by hand when the library has"
  echo "   build-time ABI switches: grep '#define .*VERSION' in the distro's installed config header and in"
  echo "   $L/include, and pass the matching option via CMAKE_ARGS/CONFIGURE_ARGS)"
fi
echo "  link it: link_harness.sh VARIANT=$VARIANT LIB=\"$(for a in "${arch[@]}"; do printf '%s ' "$L/$(basename "$a")"; done | sed 's/ $//')\" ...  (drops the matching -l<x>; -I$L/include first)"
exit $st
