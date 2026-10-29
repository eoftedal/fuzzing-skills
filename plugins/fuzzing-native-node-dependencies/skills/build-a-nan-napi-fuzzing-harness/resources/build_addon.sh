#!/bin/bash
# Build ONE variant of a node-gyp addon with the compiler swapped, verify it, and
# snapshot the build products (addon, objects, vendored archives, makefile) into
# OUT/<variant>/.  Run it from the package directory (where binding.gyp is).
#
#   build_addon.sh VARIANT=plain|asan|pristine [OUT=/abs/path/to/fuzz/out] [TARGET=<gyp target_name>]
#                  [NODE_GYP=<node-gyp command>] [AFL_RT=<afl-compiler-rt.o>] [JOBS=N]
#                  [ADDON_CXX=g++] [EXTRA_CFLAGS="..."] [EXTRA_LDFLAGS="..."]
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
#   EXTRA_LDFLAGS  appended to the addon's link flags, on configure (LDFLAGS) and on make
#              (LDFLAGS.target).  An exported LDFLAGS is NOT honoured: this script sets both
#              itself, so pass it here.  The case it exists for: check_symbols.sh reports
#              INTERPOSED (node exports the same library functions the addon vendors), and
#              EXTRA_LDFLAGS=-Wl,-Bsymbolic makes the swapped-in addon call its own copy.  It
#              is recorded in OUT/<variant>/extra_flags.env, and rebuild_asan.sh (the
#              self-test's rebuild) reuses it when not given again, so the flag survives
#              the self-test.  The real stack then needs an oracle linked the same way, in
#              a second oracle directory, keeping the as-installed one for the final
#              reproducer check:
#                mkdir -p $W/oracle-sym && cd $W/oracle-sym && npm init -y >/dev/null
#                LDFLAGS=-Wl,-Bsymbolic npm_config_build_from_source=true npm install <pkg>@<ver>
#                $R/init_workspace.sh W=$W PKG=$W/oracle-sym/node_modules/<pkg> REAL="..." REAL_ASAN="..."
#              (npm's own node-gyp run does read LDFLAGS; check with check_symbols.sh ADDON=<its .node>)
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
#     (`ar: ...<member>.o: No such file or directory`).  A build/ this script did not
#     make (an npm tarball can ship the publisher's build/Release and makefiles) is named
#     before it goes.
#   * More than one addon target in binding.gyp: a NOTE names the ADDON_MATCH the real-stack
#     swap needs, and that a second addon the JS layer uses is not built by this run.  A
#     second target the package's JS never names (a post-build helper) is said to be one.
#   * OUT/<variant>/lib/ survives a re-run: only the archives this script copied there last
#     time (listed in lib/.from-build_addon) are replaced; a static archive a library build
#     put there (build_lib.sh, route 3b, or a hand-written recipe) is kept, with its include/,
#     and so is OUT/<variant>/dict2file-lib.raw, whose constants join dict.afl.
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
EXTRA_LDFLAGS=${EXTRA_LDFLAGS:-}
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
# link flags: the sanitizer flags without the -include, plus EXTRA_LDFLAGS
LDF="${SAN//$UNDEF/} $EXTRA_LDFLAGS"
ADDON_CXX_=${ADDON_CXX:-$CXX_}
RT=""
if [ "$NEED_AFL" = 1 ]; then
  RT=${AFL_RT:-$("$HERE/find_afl_rt.sh")} || exit 1
fi
export AFL_QUIET=1
mkdir -p "$OUT/$VARIANT"
LOG=$OUT/$VARIANT/build.log

# Build-time dictionary: afl-clang-fast writes every constant its compares use (strcmp,
# memcmp, switch, integer ==) to AFL_LLVM_DICT2FILE, one AFL `"..."` line each, appended per
# TU, so the raw file is removed first.  The path must be absolute (afl-cc aborts otherwise).
# NO_MAIN skips main(): configure and mkmf conftests put all their constants there.
# A library built separately (build_lib.sh) records into dict2file-lib.raw, kept here.
DICT_RAW=""; LIB_RAW=""
if [ "$NEED_AFL" = 1 ]; then
  DICT_RAW=$(cd "$OUT/$VARIANT" && pwd)/dict2file.raw; rm -f "$DICT_RAW" "$OUT/$VARIANT/dict.afl"
  [ -s "$OUT/$VARIANT/dict2file-lib.raw" ] && LIB_RAW=$OUT/$VARIANT/dict2file-lib.raw
  export AFL_LLVM_DICT2FILE=$DICT_RAW AFL_LLVM_DICT2FILE_NO_MAIN=1
else unset AFL_LLVM_DICT2FILE AFL_LLVM_DICT2FILE_NO_MAIN; fi
# raw -> dict.afl: dedup, and drop what afl-fuzz -x aborts on (an empty token, or one over
# MAX_DICT_FILE = 128 decoded bytes; \xNN, \\ and \" decode to one byte).  Prints "<kept> <dropped>".
mkdict() {  # <dict.afl> <raw>...
  local out=$1; shift; rm -f "$out"
  cat "$@" 2>/dev/null | LC_ALL=C sort -u | awk -v out="$out" '
    !/^".*"$/ { next }
    { d = substr($0, 2, length($0) - 2); gsub(/\\x[0-9A-Fa-f][0-9A-Fa-f]|\\./, "x", d)
      if (d == "" || length(d) > 128) { drop++; next }
      print > out; n++ }
    END { printf "%d %d\n", n, drop }'
}

echo "== configure ($VARIANT) =="
# A build/ this script did not make is usually one the npm tarball shipped (a publisher's
# build/Release and makefiles from another machine): say so, since `ldd build/Release/*.node`
# before this point read that binary, not one built here.
if [ -d build ] && [ ! -e build/.made-by-build_addon ]; then
  echo "  note: removing a build/ this script did not create ($(find build -type f | wc -l) files; shipped in the npm tarball?):"
  echo "        anything read from it before this build (ldd, readelf, a .target.mk) was the publisher's, not this machine's"
fi
rm -rf build
CC=$CC_ CXX=$CXX_ CFLAGS="$SAN" CXXFLAGS="$SAN" LDFLAGS="$LDF" $NODE_GYP configure > "$LOG" 2>&1 \
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
touch build/.made-by-build_addon
[ "$(wc -l <<<"$ALL_TARGETS")" -gt 1 ] && echo "  targets in binding.gyp: $(tr '\n' ' ' <<<"$ALL_TARGETS")-> building $TARGET"
# The other targets: one the package's JS names (require/bindings('<name>'), '<name>.node')
# is a second addon it loads; one it never names is a post-build helper.  With no JS file
# to read, the name heuristic decides (postbuild/copy/action targets are helpers).
JSF=$(find . -path ./node_modules -prune -o -path ./build -prune -o \( -name '*.js' -o -name '*.cjs' -o -name '*.mjs' \) -type f -print 2>/dev/null | head -500)
OTHER_ADDONS=""; HELPERS=""
for t in $(grep -vxF "$TARGET" <<<"$ALL_TARGETS"); do
  if [ -n "$JSF" ]; then
    if [ "$(xargs -d '\n' grep -lE "['\"/]${t//./\\.}(\\.node)?['\"]" <<<"$JSF" 2>/dev/null | wc -l)" -gt 0 ]; then OTHER_ADDONS="$OTHER_ADDONS $t"; else HELPERS="$HELPERS $t"; fi
  elif grep -qiE 'postbuild|copy|action' <<<"$t"; then HELPERS="$HELPERS $t"; else OTHER_ADDONS="$OTHER_ADDONS $t"; fi
done
[ -n "$HELPERS" ] && [ -n "$JSF" ] && echo "  note: target(s)$HELPERS: the package's JS never names them ($(wc -l <<<"$JSF") .js files read): a post-build"
[ -n "$HELPERS" ] && [ -n "$JSF" ] && echo "        helper, not an addon the JS loads; no ADDON_MATCH needed for it (the swap only sees what is dlopened)"
# more than one target the JS loads: more than one addon
if [ -n "$OTHER_ADDONS" ]; then
  echo "  NOTE: the package builds more than one addon; this run builds $TARGET (TARGET=<name> picks the one"
  echo "        holding the library you fuzz).  The real-stack swap must name it:"
  echo "        ADDON_MATCH='${TARGET}\\.node\$' (init_workspace.sh writes it to fuzz.env; real_harness.mjs, gate.sh,"
  echo "        smoke.sh and triage read it), else the swap is AMBIGUOUS-SWAP.  A second addon the JS layer"
  echo "        depends on (a checksum helper, say) is not built here: compile its sources into the"
  echo "        harness TU, or link its objects (ADDON_OBJS= / LIB=), so the mirrored dispatch can call it."
fi
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
     CFLAGS.target="$SAN" CXXFLAGS.target="$SAN" LDFLAGS.target="$LDF" >> "$LOG" 2>&1 \
  || { echo "FAIL: make; see $LOG" >&2; grep -m5 -E 'error:|Error ' "$LOG" >&2; exit 1; }

NODE_FILE=$(ls build/Release/*.node 2>/dev/null | head -1)
[ -n "$NODE_FILE" ] || { echo "FAIL: no .node produced in build/Release" >&2; exit 1; }
DICT_N=""
[ -n "$DICT_RAW" ] && read -r DICT_N DICT_DROP < <(mkdict "$OUT/$VARIANT/dict.afl" "$DICT_RAW" $LIB_RAW)

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
      # system libraries the addon links directly (DT_NEEDED, minus the C/C++ and sanitizer runtimes)
      syslibs=$(readelf -d "$NODE_FILE" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' \
                | grep -vE '^(libc|libm|libpthread|libdl|librt|libstdc\+\+|libgcc_s|libasan|libubsan)\.so|^ld-linux|^libclang_rt' | sed 's/\.so.*//' | paste -sd' ' -)
      if [ "$own" != 0 ] && [ -n "$syslibs" ]; then
        echo "  ok: $own coverage symbols in the addon's own objects: the addon is instrumented; its libraries are system"
        echo "      shared objects ($syslibs): route 3b for the one you fuzz (build_lib.sh)"
        ls "$OUT/$VARIANT"/lib/*.a >/dev/null 2>&1 && echo "      (a static archive is already in $OUT/$VARIANT/lib/: $(cd "$OUT/$VARIANT/lib" && ls *.a | paste -sd' ' -))"
      elif [ "$own" != 0 ]; then echo "  ok: $own coverage symbols in the addon target's own objects (the library is compiled in the addon's own gyp target; no separate dependency)"
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

if [ -n "$EXTRA_LDFLAGS" ]; then
  case $EXTRA_LDFLAGS in *Bsymbolic*)
    readelf -d "$NODE_FILE" 2>/dev/null | grep -qE '\(SYMBOLIC\)|FLAGS.*SYMBOLIC' \
      && echo "  ok: $NODE_FILE is linked -Bsymbolic (DT_FLAGS SYMBOLIC)" \
      || { echo "  FAIL: EXTRA_LDFLAGS asks for -Bsymbolic but $NODE_FILE carries no SYMBOLIC flag (see $LOG)" >&2; fail=1; } ;;
  esac
fi

echo "== snapshot -> $OUT/$VARIANT =="
# what rebuild_asan.sh reuses when the self-test rebuilds this variant without them
printf 'EXTRA_CFLAGS=%q\nEXTRA_LDFLAGS=%q\n' "$EXTRA_CFLAGS" "$EXTRA_LDFLAGS" > "$OUT/$VARIANT/extra_flags.env"
rm -rf "$OUT/$VARIANT/Release"
cp -a build/Release "$OUT/$VARIANT/Release"
cp "$MK" "$OUT/$VARIANT/"
cp build/Makefile "$OUT/$VARIANT/Makefile"
# vendored archives built outside build/Release (a gyp action running autotools) go to lib/.
# Only what this script copied there last time (lib/.from-build_addon) is replaced: a static
# archive built after an earlier run (build_lib.sh, route 3b) used to be wiped here.
L=$OUT/$VARIANT/lib
NEWA=$(find build -name '*.a' -not -path '*/Release/*' 2>/dev/null)
if [ -f "$L/.from-build_addon" ]; then
  while IFS= read -r f; do [ -n "$f" ] && rm -f "$L/$f"; done < "$L/.from-build_addon"; rm -f "$L/.from-build_addon"
fi
kept=$(ls -Ap "$L" 2>/dev/null | grep -v '^\.' | grep -vxF -f <(for a in $NEWA; do basename "$a"; done; echo /) | paste -sd' ' -)
[ -n "$kept" ] && echo "  kept $L (static archive from a previous library build: $kept)"
[ -n "$LIB_RAW" ] && echo "  kept $LIB_RAW (its compare constants are in dict.afl)"
if [ -n "$NEWA" ]; then
  mkdir -p "$L"
  for a in $NEWA; do cp "$a" "$L/" && basename "$a" >> "$L/.from-build_addon"; done
fi
echo "  addon:    $OUT/$VARIANT/Release/$(basename "$NODE_FILE")"
echo "  objects:  $(find "$OUT/$VARIANT/Release/obj.target" -name '*.o' | wc -l) under $OUT/$VARIANT/Release/obj.target"
ls "$L"/*.a >/dev/null 2>&1 && echo "  archives: $(cd "$L" && ls *.a | tr '\n' ' ')under $L  (use as LIB= for link_harness.sh)"
if [ -n "$DICT_RAW" ]; then
  if [ "$DICT_N" -gt 0 ]; then echo "  dict:     $DICT_N entries in $OUT/$VARIANT/dict.afl (compare constants; campaign.sh -x)$([ "$DICT_DROP" -gt 0 ] && echo ", $DICT_DROP over 128 bytes dropped")"
  else echo "  dict:     no compare constants recorded; no dict.afl"; fi
fi
echo "  flags:    $HERE/lift_flags.sh $OUT/$VARIANT/$(basename "$MK") SRCDIR=$PWD"
exit $fail
