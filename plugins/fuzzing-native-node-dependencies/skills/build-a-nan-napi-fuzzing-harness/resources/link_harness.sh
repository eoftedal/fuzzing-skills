#!/bin/bash
# Compile the harness TU with the addon's own flags, generate and self-test the stubs,
# and link BOTH drivers (persistent and fork) for one variant.
#
#   link_harness.sh VARIANT=plain|asan|pristine MK=out/plain/<target>.target.mk \
#       SRCDIR=<package dir> [LIB="<objects or archives the boundary needs>"] \
#       [ADDON_OBJS="<addon objects you link, if any>"] [HARNESS=harness.cc] [OUT=out] \
#       [HARNESS_CXX=g++] [STUB_SYMBOL=napi_throw] [EXTRA_LIBS="-lz -pthread"] \
#       [LIBS_FROM_MK=1] [EXTRA_FLAGS="-I..."]
#
#   LIB         the library's objects ("$(find out/<v>/Release/obj.target/<dep> -name '*.o')") or
#               its archive (out/<v>/lib/lib<dep>.a) -- what the boundary function's
#               code is in.  May be empty for a binding over SYSTEM libraries (then
#               give ADDON_OBJS and LIBS_FROM_MK=1); at least one of LIB/ADDON_OBJS
#               is required.
#   LIBS_FROM_MK=1  append the target's own `LIBS :=` block from MK (the system
#               libraries the addon links: -lfoo -lbar ...) to EXTRA_LIBS.
#   EXTRA_FLAGS extra compile flags for the harness TU.  lift_flags.sh already adds
#               -I for the package root, src/ and lib/ (gyp compiles with includes
#               relative to the source file, so the lifted -I list lacks them).
#   ADDON_OBJS  addon objects holding the boundary function, when it lives in the
#               addon rather than the library.  Stubs are generated from these.
#               Leave empty when nothing from the addon is linked; then there are no
#               stubs and gate check 5 is N/A -- say so.
#   HARNESS_CXX compiler for the harness TU only.  Set to g++ when the addon's
#               headers refuse to compile under clang (node-addon-api 3.x); the TU is
#               then compiled uninstrumented with afl_shim.h providing the persistent
#               macros, and the AFL runtime still arrives via the afl-clang-fast++ link.
#
# Products: OUT/<variant>/harness (persistent), OUT/<variant>/harness-fork, and
# OUT/<variant>/stubtest when stubs exist.  Prints the map size at the end.
set -uo pipefail
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
VARIANT=${VARIANT:?set VARIANT}
MK=${MK:?set MK=<target.mk>}
SRCDIR=${SRCDIR:?set SRCDIR=<package dir>}
LIB=${LIB:-}
ADDON_OBJS=${ADDON_OBJS:-}
[ -n "$LIB$ADDON_OBJS" ] || { echo "FAIL: give LIB= (library objects/archive) and/or ADDON_OBJS=" >&2; exit 2; }
EXTRA_FLAGS=${EXTRA_FLAGS:-}
HARNESS=${HARNESS:-harness.cc}
OUT=${OUT:-out}
EXTRA_LIBS=${EXTRA_LIBS:-}
STUB_SYMBOL=${STUB_SYMBOL:-napi_throw}
HERE=$(cd "$(dirname "$0")" && pwd)
D=$OUT/$VARIANT; mkdir -p "$D"
export AFL_QUIET=1

UNDEF="-include $HERE/undef_fuzzmode.h"     # afl-clang-fast defines FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION
case $VARIANT in
  plain)    CXX=afl-clang-fast++; unset AFL_USE_ASAN; SAN="$UNDEF" ;;
  asan)     CXX=afl-clang-fast++; export AFL_USE_ASAN=1; SAN="$UNDEF -fsanitize=address -fno-omit-frame-pointer" ;;
  pristine) CXX=clang++; unset AFL_USE_ASAN; SAN="-fsanitize=address -fno-omit-frame-pointer" ;;
  *) echo "FAIL: VARIANT must be plain|asan|pristine" >&2; exit 2 ;;
esac
HCXX=${HARNESS_CXX:-$CXX}
SHIM=""
[ "$HCXX" != "$CXX" ] && SHIM="-include $HERE/afl_shim.h"

FLAGS=$("$HERE/lift_flags.sh" "$MK" SRCDIR="$SRCDIR")
# Flags that only make sense for the addon's own link step.
FLAGS=$(sed 's/ -MMD//g; s/ -MF [^ ]*//g' <<<"$FLAGS")
FLAGS="$FLAGS $EXTRA_FLAGS"
if [ "${LIBS_FROM_MK:-0}" = 1 ]; then
  EXTRA_LIBS="$EXTRA_LIBS $(sed -n '/^LIBS :=/,/^$/p' "$MK" | tr -d '\\' | tr '\n' ' ' | sed 's/^LIBS := //; s/-l[A-Za-z0-9_.+-]*afl-compiler-rt[^ ]*//; s#[^ ]*afl-compiler-rt\.o##')"
fi

echo "== harness TU ($VARIANT) with lifted flags =="
for drv in harness harness-fork; do
  extra=""; [ "$drv" = harness-fork ] && extra="-DNO_PERSISTENT"
  $HCXX -c -o "$D/$drv.o" "$HARNESS" $FLAGS $SHIM $extra $SAN \
    || { echo "FAIL: compiling $HARNESS ($drv)" >&2; exit 1; }
done

STUBS=""
if [ -n "$ADDON_OBJS" ]; then
  echo "== stubs from: $ADDON_OBJS =="
  "$HERE/gen_stubs.sh" $ADDON_OBJS > "$D/stubs.cc" || exit 1
  # one call per stub; the helper's own definition takes `const char*`, so it does not match
  nstubs=$(grep -c 'afl_stub_hit("' "$D/stubs.cc")
  if [ "$nstubs" -gt 0 ]; then
    $CXX -c -o "$D/stubs.o" "$D/stubs.cc" $SAN || exit 1
    STUBS=$D/stubs.o
    echo "  $nstubs stubbed symbols"
    if ! grep -q "\"$STUB_SYMBOL\"" "$D/stubs.cc"; then      # default not present: take the first
      STUB_SYMBOL=$(grep -m1 -oE 'afl_stub_hit\("[^"]+"' "$D/stubs.cc" | sed 's/.*("//; s/"$//')
    fi
    # The self-test is not optional: a stub set that cannot be shown to abort makes gate
    # check 5 unfalsifiable, so a stubtest that does not even compile is a FAIL.
    $CXX -o "$D/stubtest" "$HERE/stubtest.cc" "$STUBS" -DSYMBOL="\"$STUB_SYMBOL\"" $SAN \
      || { echo "  FAIL: stubtest did not compile/link for $STUB_SYMBOL; the stubs are unproven" >&2; exit 1; }
    { "$D/stubtest" >/dev/null 2>"$D/stubtest.err"; rc=$?; } 2>/dev/null   # silence bash's signal report
    if [ $rc -ne 0 ] && grep -q AFL-HARNESS-STUB "$D/stubtest.err"; then
      echo "  ok: stubtest($STUB_SYMBOL) aborts with the marker (rc=$rc)"
    else echo "  FAIL: stubtest did not abort identifiably (rc=$rc)" >&2; exit 1; fi
  else
    echo "  none: the addon objects reference no binding symbol (nothing to trap; gate check 5 is then vacuous: record it as N/A)"
  fi
else
  echo "== no addon objects linked: no stubs, gate check 5 is N/A =="
fi

echo "== link =="
for drv in harness harness-fork; do
  if ! $CXX -o "$D/$drv" "$D/$drv.o" $ADDON_OBJS $STUBS $LIB $EXTRA_LIBS -pthread $SAN 2>"$D/link.err"; then
    echo "FAIL: linking $drv. Undefined references:" >&2
    grep -oE "undefined reference to [^\n]*" "$D/link.err" | sort -u | head -8 | sed 's/^/      /' >&2
    echo "      * a binding symbol (napi_*, Napi::, v8::, node::): an addon object you did not list references" >&2
    echo "        binding code -- add it to ADDON_OBJS so it gets stubbed, or do not link what references it" >&2
    echo "      * the PACKAGE's own method (<pkg ns>::Class::method, pulled in by an inline helper in a shared" >&2
    echo "        header): either link the object that defines it, or give it a trapping stub with" >&2
    echo "        NAMESPACES=\"Napi v8 node <pkg ns>\" (gen_stubs.sh) -- a stub is right when the harness never" >&2
    echo "        reaches it; the gate's check 5 then proves that" >&2
    echo "      * a library symbol: LIB is incomplete, or EXTRA_LIBS needs the system libraries from the" >&2
    echo "        addon's LIBS (LIBS_FROM_MK=1).  Full log: $D/link.err" >&2
    exit 1
  fi
done
# afl-fuzz picks the driver from the persistent-mode magic string in the binary.  A shim
# lacking the testcase macros once turned the persistent binary into a usage-printing fork
# binary without any error, and a sentence in SKILL.md was the only guard: check it here.
if [ "$VARIANT" != pristine ]; then
  MAGIC='##SIG_AFL_PERSISTENT##'
  if ! grep -qa "$MAGIC" "$D/harness"; then
    echo "FAIL: $D/harness lacks $MAGIC: a harness TU compiled by something other than" >&2
    echo "      afl-clang-fast needs -include afl_shim.h with all five macros" >&2; exit 1
  fi
  if grep -qa "$MAGIC" "$D/harness-fork"; then
    echo "FAIL: $D/harness-fork carries $MAGIC: the fork binary was built without -DNO_PERSISTENT" >&2; exit 1
  fi
fi
if [ "$VARIANT" != pristine ]; then
  ms=$(AFL_DUMP_MAP_SIZE=1 "$D/harness" 2>/dev/null | tail -1)
  echo "  map size: ${ms:-?}   (pass MAP_SIZE=$ms to gate.sh / measure.sh; it differs per variant)"
  echo "$ms" > "$D/map_size"
fi
echo "built $D/harness and $D/harness-fork"
