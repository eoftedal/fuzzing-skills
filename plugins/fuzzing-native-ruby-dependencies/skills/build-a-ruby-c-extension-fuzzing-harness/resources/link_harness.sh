#!/bin/bash
# Compile the harness TU with the extension's own flags, generate and self-test the
# stubs, and link BOTH drivers (persistent and fork) for one variant.
#
#   link_harness.sh VARIANT=plain|asan|pristine MK=out/plain/Makefile \
#       SRCDIR=<ext source dir> [LIB="<objects or archives the boundary needs>"] \
#       [EXT_OBJS="<extension objects you link, if any>"] [HARNESS=harness.cc] [OUT=out] \
#       [HARNESS_CXX=g++] [STUB_SYMBOL=rb_raise] [DATA_STUB_SYMBOL=rb_cObject] \
#       [EXTRA_LIBS="-lz -pthread"] [LIBS_FROM_MK=1] [EXTRA_FLAGS="-I..."] \
#       [SHIM="shim.c [more.c]"]
#
#   MK          the mkmf Makefile build_ext.sh snapshotted into out/<variant>/
#   LIB         the library's objects or archive -- what the boundary function's code
#               is in: a vendored library's archive (out/<v>/lib/libfoo.a), or the
#               library sources the extension compiles itself (out/<v>/obj/<file>.o).
#               May be empty for an extension over SYSTEM libraries (then give EXT_OBJS
#               and LIBS_FROM_MK=1); at least one of LIB/EXT_OBJS is required.
#   LIBS_FROM_MK=1  append the extension's own $(LOCAL_LIBS) $(LIBS) and $(LIBPATH)
#               (the system libraries it links: -lfoo -lz ...) to EXTRA_LIBS,
#               minus libruby: the harness must not link the Ruby runtime, that is
#               what the stubs stand in for.
#   EXTRA_FLAGS extra compile flags for the harness TU.  lift_flags.sh already adds
#               the include paths and -D macros from the Makefile plus SRCDIR.
#   EXT_OBJS    extension objects holding the boundary function, when it lives in the
#               extension's own .c files rather than the library (common in Ruby: the
#               parser IS the extension).  Stubs are generated from these.  Leave empty
#               when nothing from the extension is linked; then there are no stubs and
#               gate check 5 is N/A -- say so.
#   SHIM        source files of a Ruby-runtime shim (resources/ruby_shim_template.c): real
#               definitions of the few rb_* calls an extension's own parser makes on the
#               input path.  Compiled here for THIS variant (its sanitizer and the lifted
#               flags, plus -I for each file's own directory), linked like LIB, and
#               excluded from stub generation.  rebuild_asan.sh passes it through, so the
#               self-test rebuilds the shim with everything else.
#               Always with plain clang/clang++, never afl-clang-fast: the shim stands in
#               for the runtime, so its coverage is noise, and one shim TU instrumented
#               under ASAN crashed in a select-instrumented branch (the guard slot held a
#               relocated pointer) until it was rewritten.
#   HARNESS_CXX compiler for the harness TU only, when a header refuses clang; the TU
#               is then compiled uninstrumented with afl_shim.h providing the persistent
#               macros, and the AFL runtime still arrives via the afl-clang-fast++ link.
#
# Products: OUT/<variant>/harness (persistent), OUT/<variant>/harness-fork, and
# OUT/<variant>/stubtest[-data] when stubs exist.  Prints the map size at the end.
set -uo pipefail
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
VARIANT=${VARIANT:?set VARIANT}
MK=${MK:?set MK=out/<variant>/Makefile}
SRCDIR=${SRCDIR:?set SRCDIR=<ext source dir>}
LIB=${LIB:-}
EXT_OBJS=${EXT_OBJS:-}
SHIM_SRC=${SHIM:-}
[ -n "$LIB$EXT_OBJS" ] || { echo "FAIL: give LIB= (library objects/archive) and/or EXT_OBJS=" >&2; exit 2; }
EXTRA_FLAGS=${EXTRA_FLAGS:-}
HARNESS=${HARNESS:-harness.cc}
OUT=${OUT:-out}
EXTRA_LIBS=${EXTRA_LIBS:-}
STUB_SYMBOL=${STUB_SYMBOL:-rb_raise}
DATA_STUB_SYMBOL=${DATA_STUB_SYMBOL:-rb_cObject}
HERE=$(cd "$(dirname "$0")" && pwd)
D=$OUT/$VARIANT; mkdir -p "$D"
export AFL_QUIET=1

UNDEF="-include $HERE/undef_fuzzmode.h"     # afl-clang-fast defines FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION
# clang 21 warns on Ruby 3.3's own headers (ruby.h: -Wdefault-const-init-field-unsafe);
# a harness or shim that includes the extension's header pulls them in.  Noise only.
QUIET="-Wno-default-const-init-field-unsafe -Wno-unknown-warning-option"
case $VARIANT in
  plain)    CC=afl-clang-fast; CXX=afl-clang-fast++; unset AFL_USE_ASAN; SAN="$UNDEF" ;;
  asan)     CC=afl-clang-fast; CXX=afl-clang-fast++; export AFL_USE_ASAN=1; SAN="$UNDEF -fsanitize=address -fno-omit-frame-pointer" ;;
  pristine) CC=clang; CXX=clang++; unset AFL_USE_ASAN; SAN="-fsanitize=address -fno-omit-frame-pointer" ;;
  *) echo "FAIL: VARIANT must be plain|asan|pristine" >&2; exit 2 ;;
esac
HCXX=${HARNESS_CXX:-$CXX}
AFLSHIM=""
[ "$HCXX" != "$CXX" ] && AFLSHIM="-include $HERE/afl_shim.h"

FLAGS=$("$HERE/lift_flags.sh" "$MK" SRCDIR="$SRCDIR") || exit 1
FLAGS="$FLAGS $EXTRA_FLAGS"
if [ "${LIBS_FROM_MK:-0}" = 1 ]; then
  mkl=$("$HERE/mkvar.sh" "$MK" LIBPATH LOCAL_LIBS LIBS srcdir="$SRCDIR" | sed 's/^[A-Z_]*=//' | tr '\n' ' ')
  # drop libruby (-lruby, -lruby-3.3, -lruby-static) and the AFL runtime build_ext.sh added
  EXTRA_LIBS="$EXTRA_LIBS $(tr ' ' '\n' <<<"$mkl" | grep -vE '^-lruby|afl-compiler-rt' | tr '\n' ' ')"
fi

# The harness TU's compare constants join the build's dict.afl (build script: dict2file.raw).
# Its own raw file, so a relink neither wipes the library's entries nor accumulates; stubs
# and shims are not recorded.  An absolute path, or afl-cc aborts.  No _NO_MAIN here: at -O2
# the harness's static helpers are inlined into main and their constants would be lost.
HDICT=""
if [ "$VARIANT" != pristine ]; then HDICT=$(cd "$D" && pwd)/dict2file-harness.raw; rm -f "$HDICT"; fi
echo "== harness TU ($VARIANT) with lifted flags =="
for drv in harness harness-fork; do
  extra=""; [ "$drv" = harness-fork ] && extra="-DNO_PERSISTENT"
  ${HDICT:+env AFL_LLVM_DICT2FILE=$HDICT} $HCXX -c -o "$D/$drv.o" "$HARNESS" $FLAGS $AFLSHIM $extra $SAN $QUIET \
    || { echo "FAIL: compiling $HARNESS ($drv)" >&2; exit 1; }
done

if [ -n "$SHIM_SRC" ]; then
  echo "== Ruby-runtime shim ($VARIANT): $SHIM_SRC =="
  SHIM_OBJS=""
  for f in $SHIM_SRC; do
    o=$D/shim-$(basename "${f%.*}").o
    case $f in *.c) cc=clang ;; *) cc=clang++ ;; esac    # uninstrumented: see SHIM above
    $cc -c -o "$o" "$f" $FLAGS -I"$(cd "$(dirname "$f")" && pwd)" $SAN $QUIET \
      || { echo "FAIL: compiling shim $f" >&2; exit 1; }
    SHIM_OBJS="$SHIM_OBJS $o"
  done
  LIB="$SHIM_OBJS $LIB"           # linked like LIB, and excluded from stubs like LIB
fi

# One self-test per stub kind.  Not optional: a stub set that cannot be shown to
# abort makes gate check 5 unfalsifiable, so a stubtest that does not even compile
# is a FAIL.
stubtest() {   # stubtest <define> <symbol> <binary>
  $CXX -o "$3" "$HERE/stubtest.cc" "$STUBS" -D"$1"="\"$2\"" $SAN \
    || { echo "  FAIL: stubtest did not compile/link for $2; the stubs are unproven" >&2; exit 1; }
  { "$3" >/dev/null 2>"$3.err"; rc=$?; } 2>/dev/null   # silence bash's signal report
  if [ $rc -ne 0 ] && grep -q "AFL-HARNESS-STUB.*$2" "$3.err"; then
    echo "  ok: $(basename "$3")($2) aborts with the marker (rc=$rc)"
  else echo "  FAIL: $(basename "$3")($2) did not abort identifiably (rc=$rc): $(head -c 300 "$3.err")" >&2; exit 1; fi
}

STUBS=""
if [ -n "$EXT_OBJS" ]; then
  echo "== stubs from: $EXT_OBJS =="
  # The harness TU counts as "defined elsewhere" too: a recording shim for a few rb_*
  # callbacks (find_boundary.sh) is defined there, and stubbing it as well would be a
  # duplicate definition.
  DEFINED_ELSEWHERE="$LIB $D/harness.o" "$HERE/gen_stubs.sh" $EXT_OBJS > "$D/stubs.cc" || exit 1
  # one call per function stub; the helper's own definition takes `const char*`, so it does not match
  nfn=$(grep -c 'afl_stub_hit("' "$D/stubs.cc")
  ndata=$(grep -c '^AFL_DATA_STUB(' "$D/stubs.cc")
  if [ $((nfn + ndata)) -gt 0 ]; then
    $CXX -c -o "$D/stubs.o" "$D/stubs.cc" $SAN || exit 1
    STUBS=$D/stubs.o
    echo "  $nfn function + $ndata data stubs"
    if [ "$nfn" -gt 0 ]; then
      grep -q "afl_stub_hit(\"$STUB_SYMBOL\")" "$D/stubs.cc" \
        || STUB_SYMBOL=$(grep -m1 -oE 'afl_stub_hit\("[^"]+"' "$D/stubs.cc" | sed 's/.*("//; s/"$//')
      stubtest SYMBOL "$STUB_SYMBOL" "$D/stubtest"
    fi
    if [ "$ndata" -gt 0 ]; then
      grep -q "^AFL_DATA_STUB($DATA_STUB_SYMBOL)" "$D/stubs.cc" \
        || DATA_STUB_SYMBOL=$(grep -m1 -oE '^AFL_DATA_STUB\([^)]+' "$D/stubs.cc" | sed 's/.*(//')
      stubtest DATA_SYMBOL "$DATA_STUB_SYMBOL" "$D/stubtest-data"
    fi
  else
    echo "  none: the extension objects reference no Ruby runtime symbol (nothing to trap; gate check 5 is then vacuous: record it as N/A)"
  fi
else
  echo "== no extension objects linked: no stubs, gate check 5 is N/A =="
fi

echo "== link =="
for drv in harness harness-fork; do
  if ! $CXX -o "$D/$drv" "$D/$drv.o" $EXT_OBJS $STUBS $LIB $EXTRA_LIBS -pthread $SAN 2>"$D/link.err"; then
    echo "FAIL: linking $drv. Undefined references:" >&2
    grep -oE "undefined reference to [^[:space:]]+" "$D/link.err" | sort -u | head -8 | sed 's/^/      /' >&2
    echo "      * a Ruby runtime symbol (rb_*, ruby_*, st_*, onig*): an extension object you did not list" >&2
    echo "        references it -- add it to EXT_OBJS so it gets stubbed, or do not link what references it." >&2
    echo "        If gen_stubs.sh warned that it fell back to C_SYMBOLS, set RUBY_RUNTIME= to libruby.so" >&2
    echo "      * a library symbol: LIB is incomplete, or EXTRA_LIBS needs the system libraries from the" >&2
    echo "        extension's LIBS (LIBS_FROM_MK=1).  Full log: $D/link.err" >&2
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
if [ -n "$HDICT" ]; then   # same filter as the build script: dedup, drop empty or >128-byte tokens
  ndict=$(cat "$D/dict2file.raw" "$HDICT" 2>/dev/null | LC_ALL=C sort -u | awk -v out="$D/dict.afl.tmp" '
    !/^".*"$/ { next }
    { d = substr($0, 2, length($0) - 2); gsub(/\\x[0-9A-Fa-f][0-9A-Fa-f]|\\./, "x", d)
      if (d == "" || length(d) > 128) next
      print > out; n++ }
    END { print n + 0 }')
  if [ "$ndict" -gt 0 ]; then mv "$D/dict.afl.tmp" "$D/dict.afl"; echo "  dict: $ndict entries in $D/dict.afl (library + harness compare constants)"
  else rm -f "$D/dict.afl.tmp"; fi
fi
echo "built $D/harness and $D/harness-fork"
