#!/bin/bash
# Build ONE variant of a node-gyp addon with the compiler swapped, verify it, and
# snapshot the build products (addon, objects, vendored archives, makefile) into
# OUT/<variant>/.  Run it from the package directory (where binding.gyp is).
#
#   build_addon.sh VARIANT=plain|asan|pristine [OUT=/abs/path/to/fuzz/out] [TARGET=<gyp target_name>]
#                  [NODE_GYP=<node-gyp command>] [AFL_RT=<afl-compiler-rt.o>] [JOBS=N]
#                  [ADDON_CXX=g++] [EXTRA_CFLAGS="..."]
#
#   plain     afl-clang-fast, no sanitizer         -> throughput
#   asan      afl-clang-fast + AFL_USE_ASAN=1      -> bug finding
#   pristine  plain clang + ASAN, NO afl runtime   -> control for "did my instrumentation
#                                                     invent this bug?"; build it when you
#                                                     have a crash to cross-check
#
#   OUT        pass an ABSOLUTE path into your fuzz workspace; the default `out` lands
#              inside the package directory.
#   NODE_GYP   default: the package's own node_modules/.bin/node-gyp if the install brought
#              one, else the copy npm itself bundles (`npm root -g`/npm/node_modules/node-gyp),
#              else `npx node-gyp` (which refuses without network: "npx canceled due to
#              missing packages and no YES option").  May contain spaces ("node /path/x.js").
#   ADDON_CXX  compiler for the ADDON's own C++ TUs only, when they refuse to compile
#              under clang (node-addon-api 3.x).  The library (vendored gyp dependency)
#              still gets the variant compiler, which is where coverage comes from.
#              gcc-ASAN objects link against clang's ASAN runtime in practice, but if the
#              asan variant misbehaves, fuzz plain and keep asan for the library only.
#
# What it gets right so you do not have to, each learned on a real target:
#   * The AFL runtime is appended to LIBS INSIDE the generated makefile, not on the
#     make command line.  Command-line variables are exported to sub-makes, so a
#     dependency that runs its own `make` from a gyp action (a tarball-vendored compression
#     binding's library)
#     receives LIBS=.../afl-compiler-rt.o and fails to link its own archive.  Appending
#     also keeps the target's own LIBS (a vendored static library) intact.
#   * CC.target/CXX.target/LINK.target are overridden explicitly.  node-gyp bakes
#     whatever CC was exported at configure time in as a `?=` default, so a plain
#     `make CC=...` is silently ignored after that.
#   * LINK is clang++ with the AFL runtime named by path, because afl-clang-fast drops
#     the runtime from a -shared link and node refuses the addon (ERR_DLOPEN_FAILED:
#     undefined symbol: __afl_area_ptr).
#   * `build/` is removed before configure.  Deleting only `*.o` leaves libtool's `.lo`
#     markers behind, and the next variant then archives objects that no longer exist
#     (`ar: ...<member>.o: No such file or directory`).
#   * FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION, which afl-clang-fast defines, is
#     undefined again via -include undef_fuzzmode.h for the AFL variants.  Libraries
#     compile checks OUT under that macro (a compression library's dictionary id, a regex
#     engine's parser limits),
#     and the gate then fails -- or silently passes on a corpus too small to notice.
#   * The compiler is also EXPORTED during configure, for dependencies that run their
#     own configure script from binding.gyp and never see node-gyp's variables.
#   * Checks after the build: AFL runtime present, ASAN symbols present when they
#     should be, the LIBRARY objects/archives carry coverage symbols (a dropped
#     instrumentation passes the runtime check), and node can LOAD the addon.
#
# Not covered: cmake-js packages.  Those take CMAKE_C_COMPILER/CMAKE_CXX_COMPILER via
# `cmake-js compile --CDCMAKE_C_COMPILER=afl-clang-fast ...`; the checks below still apply.
set -uo pipefail
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
VARIANT=${VARIANT:?set VARIANT=plain|asan|pristine}
OUT=${OUT:-out}
if [ -z "${NODE_GYP:-}" ]; then
  if [ -x node_modules/.bin/node-gyp ]; then NODE_GYP=node_modules/.bin/node-gyp
  elif [ -f "$(npm root -g 2>/dev/null)/npm/node_modules/node-gyp/bin/node-gyp.js" ]; then
    NODE_GYP="node $(npm root -g)/npm/node_modules/node-gyp/bin/node-gyp.js"
  else NODE_GYP="npx node-gyp"; fi
fi
echo "  node-gyp: $NODE_GYP"
JOBS=${JOBS:-$(nproc)}
EXTRA_CFLAGS=${EXTRA_CFLAGS:-}
HERE=$(cd "$(dirname "$0")" && pwd)
[ -f binding.gyp ] || { echo "FAIL: no binding.gyp here; run from the package directory" >&2; exit 2; }
case $OUT in /*) ;; *) echo "note: OUT=$OUT is relative to $PWD; pass an absolute path into your fuzz workspace" >&2 ;; esac

UNDEF="-include $HERE/undef_fuzzmode.h"
case $VARIANT in
  plain)    CC_=afl-clang-fast; CXX_=afl-clang-fast++; unset AFL_USE_ASAN
            SAN="$UNDEF"; NEED_AFL=1; NEED_ASAN=0 ;;
  asan)     CC_=afl-clang-fast; CXX_=afl-clang-fast++; export AFL_USE_ASAN=1
            SAN="$UNDEF -fsanitize=address -fno-omit-frame-pointer"; NEED_AFL=1; NEED_ASAN=1 ;;
  pristine) CC_=clang; CXX_=clang++; unset AFL_USE_ASAN
            SAN="-fsanitize=address -fno-omit-frame-pointer"; NEED_AFL=0; NEED_ASAN=1 ;;
  *) echo "FAIL: VARIANT must be plain|asan|pristine" >&2; exit 2 ;;
esac
SAN="$SAN $EXTRA_CFLAGS"
ADDON_CXX_=${ADDON_CXX:-$CXX_}
RT=""
if [ "$NEED_AFL" = 1 ]; then
  RT=${AFL_RT:-$("$HERE/find_afl_rt.sh")} || exit 1
fi
export AFL_QUIET=1
mkdir -p "$OUT/$VARIANT"
LOG=$OUT/$VARIANT/build.log

echo "== configure ($VARIANT) =="
rm -rf build
CC=$CC_ CXX=$CXX_ CFLAGS="$SAN" CXXFLAGS="$SAN" LDFLAGS="${SAN//$UNDEF/}" $NODE_GYP configure > "$LOG" 2>&1 \
  || { echo "FAIL: node-gyp configure; see $LOG" >&2; tail -20 "$LOG" >&2; exit 1; }

# binding.gyp is Python-ish: either quote style.  Skip targets that look like
# postbuild/copy steps; if several real targets remain, the first wins unless TARGET=
# says otherwise.  With exactly one makefile, use that.
ALL_TARGETS=$(sed -nE "s/.*['\"]target_name['\"] *: *['\"]([^'\"]*)['\"].*/\1/p" binding.gyp)
TARGET=${TARGET:-$(grep -viE 'postbuild|copy|action' <<<"$ALL_TARGETS" | head -1)}
MK=build/$TARGET.target.mk
if [ ! -f "$MK" ] && [ "$(ls build/*.target.mk 2>/dev/null | wc -l)" = 1 ]; then
  MK=$(ls build/*.target.mk); TARGET=$(basename "$MK" .target.mk)
fi
[ -f "$MK" ] || { echo "FAIL: $MK not found; pass TARGET= one of:" >&2; ls build/*.target.mk >&2; exit 1; }
[ "$(wc -l <<<"$ALL_TARGETS")" -gt 1 ] && echo "  targets in binding.gyp: $(tr '\n' ' ' <<<"$ALL_TARGETS")-> building $TARGET"
grep -m1 -q "$HOME\|$(node -p 'process.versions.node')" "$MK" \
  || echo "WARN: $MK does not mention this node version or home; a prebuild may have shipped its own makefile" >&2

# Append the AFL runtime to the target's LIBS inside the makefile (see header).  gyp
# snapshots LIBS into a TARGET-SPECIFIC variable right after the block
# (`$(obj).target/x.node: LIBS := $(LIBS)`), so extend that line: a later `LIBS +=`
# never reaches the link, and a command-line LIBS= leaks into sub-makes.
if [ -n "$RT" ]; then
  sed -i "s#^\(.*\.node: LIBS := \$(LIBS)\)\$#\1 $RT#" "$MK"
  grep -q "LIBS := \$(LIBS) $RT" "$MK" || { echo "FAIL: could not add the AFL runtime to LIBS in $MK" >&2; exit 1; }
fi

echo "== build ($VARIANT, target $TARGET) =="
make -C build -j"$JOBS" "$TARGET" V=1 \
     CC.target="$CC_" CXX.target="$ADDON_CXX_" LINK.target=clang++ \
     CFLAGS.target="$SAN" CXXFLAGS.target="$SAN" LDFLAGS.target="${SAN//$UNDEF/}" >> "$LOG" 2>&1 \
  || { echo "FAIL: make; see $LOG" >&2; grep -m5 -E 'error:|Error ' "$LOG" >&2; exit 1; }

NODE_FILE=$(ls build/Release/*.node 2>/dev/null | head -1)
[ -n "$NODE_FILE" ] || { echo "FAIL: no .node produced in build/Release" >&2; exit 1; }

echo "== verify =="
fail=0
# counting form, not `| grep -q ... ||`: under pipefail grep -q closes the pipe and
# nm dies of SIGPIPE, which reads as "symbol missing" when it is right there.
if [ "$NEED_AFL" = 1 ]; then
  [ "$(nm "$NODE_FILE" | grep -c ' D __afl_area_ptr')" != 0 ] \
    && echo "  ok: AFL runtime present in $NODE_FILE" \
    || { echo "  FAIL: no AFL runtime in $NODE_FILE; node will refuse it" >&2; fail=1; }
  # the LIBRARY must carry coverage, not just the runtime: count sancov symbols in
  # every archive and in dependency objects outside the addon's own target
  cov=$( { find build -name '*.a' -exec nm {} + ; find build/Release/obj.target -name '*.o' -not -path "*/obj.target/$TARGET/*" -exec nm {} + ; } 2>/dev/null | grep -c sancov)
  if [ "$cov" != 0 ]; then echo "  ok: $cov coverage symbols in library archives/objects"
  else
    n_lib=$( { find build -name '*.a'; find build/Release/obj.target -name '*.o' -not -path "*/obj.target/$TARGET/*"; } 2>/dev/null | wc -l)
    if [ "$n_lib" = 0 ]; then
      own=$(find "build/Release/obj.target/$TARGET" -name '*.o' -exec nm {} + 2>/dev/null | grep -c sancov)
      if [ "$own" != 0 ]; then echo "  ok: $own coverage symbols in the addon target's own objects (the library is compiled in the addon's own gyp target; no separate dependency)"
      else echo "  note: no vendored library objects or archives; the library is a system .so (step 3b / uninstrumented scope)"; fi
    else echo "  FAIL: $n_lib library objects/archives but no coverage symbols: the dependency was built by its own build system without the variant compiler (see build-traps.md)" >&2; fail=1; fi
  fi
fi
if [ "$NEED_ASAN" = 1 ]; then
  [ "$(nm "$NODE_FILE" | grep -c '__asan_')" != 0 ] \
    && echo "  ok: ASAN symbols present" \
    || { echo "  FAIL: variant $VARIANT has no ASAN symbols" >&2; fail=1; }
  PRELOAD="LD_PRELOAD=$("$HERE/find_asan_rt.sh")"
else
  PRELOAD=""
fi
if env $PRELOAD ASAN_OPTIONS=detect_leaks=0 node -e "require('$PWD/$NODE_FILE')" 2>"$OUT/$VARIANT/load.err"; then
  echo "  ok: node loads $NODE_FILE"
else
  echo "  FAIL: node cannot load $NODE_FILE (see $OUT/$VARIANT/load.err)" >&2
  echo "        a dropped LIBS leaves DT_NEEDED short; a NAN addon may need an older node" >&2
  fail=1
fi

echo "== snapshot -> $OUT/$VARIANT =="
rm -rf "$OUT/$VARIANT/Release" "$OUT/$VARIANT/lib"
cp -a build/Release "$OUT/$VARIANT/Release"
cp "$MK" "$OUT/$VARIANT/"
cp build/Makefile "$OUT/$VARIANT/Makefile"
# vendored archives built outside build/Release (a gyp action running autotools)
mkdir -p "$OUT/$VARIANT/lib"
find build -name '*.a' -not -path '*/Release/*' -exec cp {} "$OUT/$VARIANT/lib/" \; 2>/dev/null
rmdir "$OUT/$VARIANT/lib" 2>/dev/null
echo "  addon:    $OUT/$VARIANT/Release/$(basename "$NODE_FILE")"
echo "  objects:  $(find "$OUT/$VARIANT/Release/obj.target" -name '*.o' | wc -l) under $OUT/$VARIANT/Release/obj.target"
[ -d "$OUT/$VARIANT/lib" ] && echo "  archives: $(ls "$OUT/$VARIANT/lib" | tr '\n' ' ') under $OUT/$VARIANT/lib  (use as LIB= for link_harness.sh)"
echo "  flags:    $HERE/lift_flags.sh $OUT/$VARIANT/$(basename "$MK") SRCDIR=$PWD"
exit $fail
