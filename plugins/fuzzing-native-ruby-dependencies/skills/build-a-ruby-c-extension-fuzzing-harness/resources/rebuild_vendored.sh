#!/bin/bash
# Rebuild ONE vendored library (a mini_portile recipe) out of tree, exactly as the
# extension's build did, so detect_selftest.sh can patch a fault into its source and
# rebuild it.  The extension's own build cannot be used for that: extconf.rb re-extracts
# the tarball over your patch, and may even delete the build tree afterwards.
#
#   rebuild_vendored.sh RECIPE=out/asan/vendor/<lib>-<ver> VARIANT=asan OUT=/abs/fuzz/out \
#                       DEST=/abs/fuzz/selftest/<lib> [JOBS=N]
#
# Reads what build_ext.sh recorded for the recipe: configure.opts (mini_portile's own
# "Configuration options:" line, which carries the variant's CFLAGS), the source tarball
# (from OUT/vendor-archives) or source dir, and the gem's patches in the order they were
# applied.  Produces DEST/src (the patched source tree: patch your fault in HERE) and
# DEST/install (prefix; the archive is DEST/install/lib/lib<name>.a).  Then:
#
#   REBUILD="make -C DEST/src -j6 install >/dev/null && resources/link_harness.sh VARIANT=asan \
#            MK=out/asan/Makefile SRCDIR=... HARNESS=... LIB='DEST/install/lib/lib<name>.a <other archives>' ..."
#   resources/detect_selftest.sh REBUILD="$REBUILD" FILE=DEST/src/<file>.c ...
#
# Re-run the asan gate against the relinked harness afterwards: it now links this
# library build, not build_ext.sh's.  Only recipes with a ./configure are supported; for
# a recipe that compiles a source dir with its own rules, copy
# DEST/src and run the extension's compile step by hand.
set -uo pipefail
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
RECIPE=${RECIPE:?set RECIPE=out/<variant>/vendor/<lib>-<ver> (written by build_ext.sh)}
VARIANT=${VARIANT:?set VARIANT=asan|plain|pristine}
OUT=${OUT:?set OUT=/abs/fuzz/out}
DEST=${DEST:?set DEST=/abs/dir for the out-of-tree build}
JOBS=${JOBS:-$(nproc)}
HERE=$(cd "$(dirname "$0")" && pwd)
[ -f "$RECIPE/configure.opts" ] || { echo "FAIL: no $RECIPE/configure.opts; run build_ext.sh first" >&2; exit 2; }

case $VARIANT in
  plain)    export CC=afl-clang-fast CXX=afl-clang-fast++; unset AFL_USE_ASAN ;;
  asan)     export CC=afl-clang-fast CXX=afl-clang-fast++ AFL_USE_ASAN=1 ;;
  pristine) export CC=clang CXX=clang++; unset AFL_USE_ASAN ;;
  *) echo "FAIL: VARIANT must be plain|asan|pristine" >&2; exit 2 ;;
esac
export AFL_QUIET=1

rm -rf "$DEST"; mkdir -p "$DEST/src" "$DEST/install"
if [ -f "$RECIPE/tarball" ]; then
  t=$OUT/vendor-archives/$(cat "$RECIPE/tarball")
  [ -f "$t" ] || { echo "FAIL: $t not found (build_ext.sh keeps recipe tarballs in OUT/vendor-archives)" >&2; exit 1; }
  tar -xf "$t" -C "$DEST/src" --strip-components=1 || { echo "FAIL: extracting $t" >&2; exit 1; }
  echo "  source: $(basename "$t")"
elif [ -f "$RECIPE/sourcedir" ]; then
  cp -a "$(cat "$RECIPE/sourcedir")"/. "$DEST/src/" || exit 1
  echo "  source: $(cat "$RECIPE/sourcedir")"
else echo "FAIL: $RECIPE records neither a tarball nor a source dir" >&2; exit 1; fi

for p in "$RECIPE"/patches/*; do
  [ -f "$p" ] || continue
  ( cd "$DEST/src" && { git apply "$p" 2>/dev/null || patch -p1 -s < "$p"; } ) \
    || { echo "FAIL: patch $(basename "$p") does not apply" >&2; exit 1; }
  echo "  applied $(basename "$p")"
done

[ -x "$DEST/src/configure" ] || { echo "FAIL: $DEST/src has no ./configure; this recipe compiles its own way (see header)" >&2; exit 1; }
# the recorded options are shell-escaped by mini_portile (--libdir\=/x, CFLAGS\=-a\ -b)
eval "set -- $(cat "$RECIPE/configure.opts")"
args=(); for a in "$@"; do case $a in --libdir=*|--prefix=*) ;; *) args+=("$a") ;; esac; done
echo "  configure ${args[*]} --prefix=$DEST/install"
( cd "$DEST/src" && ./configure "${args[@]}" --prefix="$DEST/install" --libdir="$DEST/install/lib" ) > "$DEST/configure.log" 2>&1 \
  || { echo "FAIL: configure; see $DEST/configure.log" >&2; tail -5 "$DEST/configure.log" >&2; exit 1; }
make -C "$DEST/src" -j"$JOBS" install > "$DEST/make.log" 2>&1 \
  || { echo "FAIL: make; see $DEST/make.log" >&2; grep -m5 'error:' "$DEST/make.log" >&2; exit 1; }

n=0
for a in "$DEST"/install/lib/*.a; do
  [ -f "$a" ] || continue; n=$((n+1))
  c=$(nm "$a" 2>/dev/null | grep -c sancov)
  [ "$VARIANT" != pristine ] && [ "$c" = 0 ] && { echo "  FAIL: $(basename "$a") has no coverage symbols" >&2; exit 1; }
  echo "  built $a ($c coverage symbols)"
done
[ "$n" -gt 0 ] || { echo "FAIL: no archive under $DEST/install/lib" >&2; exit 1; }
echo "  patch faults into $DEST/src; rebuild with: make -C $DEST/src -j$JOBS install"
