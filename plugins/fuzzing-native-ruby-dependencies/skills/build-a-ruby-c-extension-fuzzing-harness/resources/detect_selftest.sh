#!/bin/bash
# Prove the harness can detect a memory error BEFORE you report that it found none.
# "The campaign found no crashes" and "the harness detects nothing" produce identical
# output; this is the only thing that separates them.
#
# Injects a fault into a copy of the library, rebuilds, checks the harness reports it,
# and restores the source.  Configure with KEY=VALUE arguments or environment:
#
#   FAULT_SRC   library source file to patch
#   FAULT_SED   sed expression that injects the fault; must introduce the word INJECTED
#   REBUILD     command that rebuilds the library/extension after patching.  It must
#               re-export the sanitizer environment (AFL_USE_ASAN=1) and must not wipe
#               the tree holding FAULT_SRC.  It is run with `eval`: expand any list
#               BEFORE building the string and single-quote the result --
#                 L=$(find out/asan/.../vendor -name '*.o' | tr '\n' ' ')
#                 REBUILD="rebuild_asan.sh EXT=/abs/ext/dir ... LIB='$L'"
#               A $(find ...) left inside single quotes reaches eval as a literal string.
#               It is run twice: once with the fault applied, once to restore.  The
#               patched copy FAULT_SRC.injected is removed BEFORE the restore rebuild, so
#               a REBUILD that greps for INJECTED to tell the two apart sees only the source.
#   HARNESS     the sanitized fork-mode harness
#   CORPUS      directory of seeds (the largest non-empty one the clean harness reports as
#               status=0 with out_len>0 is picked)
#   SEED        or name one explicitly -- do so whenever the fault is in a path the
#               first seed does not take (a raw-block fault with a compressed-block
#               seed fires nothing); the script cannot know which seed reaches it
#   ALLOC_CAP_MB   memory ceiling (default 1024), as everywhere else
#
# The harness runs in the CURRENT environment: for a fault on a path only one mode reaches,
# export that mode (MODE=...) before running this, and pick SEED= from a seed that takes it.
#
# REBUILD for an mkmf (extconf.rb) extension: resources/rebuild_asan.sh with the same
# arguments you gave build_ext.sh and link_harness.sh.  For a library extconf.rb extracts
# or regenerates during configure (a vendored tarball, mini_portile2), that would
# overwrite the patched file; configure the library once out-of-tree
# (CC=afl-clang-fast AFL_USE_ASAN=1 ./configure ...) and make REBUILD `make -C <that tree> && <relink the harness against its archive>`.
#
# Two rules, both learned by getting them wrong:
#
#  1. THE FAULT MUST LAND PAST AN ALLOCATION BOUNDARY.  A 1-byte over-READ of a
#     pointer that aims into the middle of a bigger buffer is in bounds and fires
#     nothing.  Prefer a 1-byte over-WRITE just past an exactly-sized destination
#     block, e.g. for `p = malloc(n + 1); ... p[n] = 0;`  inject `p[n + 1] = 0;`.
#
#  2. THE SEED MUST REACH THE FAULTED CODE.  A deliberately-corrupt input never gets
#     past the header.  The automatic pick only accepts a non-empty seed the CLEAN harness
#     reports as status=0 with out_len>0 (largest wins).  Reaching the function is not
#     enough: the seed must take the DISPATCH branch the fault sits on (a frame without
#     a declared size goes down a streaming path whose oversized buffer hides a 1-byte
#     over-write; a UTF-8 document never touches a transcoding buffer).  Read the
#     branch the faulted line is in and pick a SEED= that enters it.
#
# PASS requires ALL of:
#   - the clean run exited 0 with no sanitizer report (else the seed already crashes:
#     choose another with SEED=);
#   - the faulted run printed a sanitizer report (a bare non-zero exit code is not enough);
#   - the faulted outcome (rc, kind) differs from the clean one;
#   - neither run's stderr contains AFL-HARNESS-STUB (else a stubbed symbol was hit).
set -uo pipefail
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
FAULT_SRC=${FAULT_SRC:?set FAULT_SRC}
FAULT_SED=${FAULT_SED:?set FAULT_SED}
REBUILD=${REBUILD:?set REBUILD}
HARNESS=${HARNESS:?set HARNESS}
ALLOC_CAP_MB=${ALLOC_CAP_MB:-1024}
# the chain's allocation ceiling, so a seed refused here is refused the same way everywhere
export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0:symbolize=1:exitcode=86:allocator_may_return_null=1:max_allocation_size_mb=$ALLOC_CAP_MB}"

[ -f "$FAULT_SRC" ] || { echo "FAIL: FAULT_SRC not found: $FAULT_SRC" >&2; exit 1; }
BK=$(mktemp)
# back up BEFORE installing the trap: if the copy failed and the trap ran, it would
# overwrite the source with an empty file.
cp "$FAULT_SRC" "$BK" || { rm -f "$BK"; exit 1; }
MODIFIED=0; VERDICT=; VERDICT_FD=1
# The verdict is printed LAST, after the restore rebuild: the output is saved with
# `| tee selftest.txt`, and campaign.sh calls a self-test stale when that file is older than
# the harness binary, which the restore rebuild would otherwise touch afterwards.
restore() { local rc=$?
            cp "$BK" "$FAULT_SRC"
            # the patched copy goes BEFORE the restore rebuild: a REBUILD that greps the
            # tree for INJECTED must see a clean tree now.  It is kept only when the
            # faulted rebuild FAILED and you need to diagnose it; never leave a
            # deliberately broken library source lying around otherwise.
            [ "${KEEP_INJECTED:-0}" = 1 ] || rm -f "$FAULT_SRC.injected"
            # rebuild only if the source was actually modified
            if [ "$MODIFIED" = 1 ] && ! eval "$REBUILD" >/dev/null 2>&1; then
              echo "FAIL: restore rebuild failed; the harness may still contain the injected fault." >&2
              VERDICT=; rc=1
            fi
            rm -f "$BK" "$BK.build"
            [ -n "$VERDICT" ] && printf '%s\n' "$VERDICT" >&"$VERDICT_FD"
            exit "$rc"; }
trap restore EXIT

SEED=${SEED:-}
if [ -z "$SEED" ]; then
  best=-1
  for c in "${CORPUS:?set CORPUS or SEED}"/*; do
    [ -f "$c" ] && [ -s "$c" ] || continue          # skip non-files and zero-byte seeds
    out=$(timeout 60 $HARNESS "$c" 2>/dev/null) || continue   # a hanging seed is not a candidate
    [[ "$out" == *"status=0"* ]] || continue
    [[ "$out" == *"out_len=0"[!0-9]* || "$out" == *"out_len=0" ]] && continue
    sz=$(wc -c <"$c")
    if [ "$sz" -gt "$best" ]; then best=$sz; SEED=$c; fi   # prefer the largest
  done
fi
[ -n "$SEED" ] || { echo "FAIL: no seed reaches the library cleanly (non-empty, status=0, out_len>0)" >&2; exit 1; }
echo "seed: $(basename "$SEED")"

# prints "<rc>|<sanitizer error kind or empty>|<1 if stderr mentions AFL-HARNESS-STUB>"
# rc 124 is the timeout: a fault that sends the library into a loop must not hang the script
run() { local o rc stub=0; o=$(timeout 60 $HARNESS "$SEED" 2>&1); rc=$?
        [[ "$o" == *AFL-HARNESS-STUB* ]] && stub=1
        echo "$rc|$(sed -n 's/.*ERROR: [A-Za-z]*Sanitizer: \([a-z-]*\).*/\1/p' <<<"$o" | head -1)|$stub"; }
show() { printf '%-28s %s %s\n' "$1" "$2" "$3"; }
fail() { VERDICT_FD=2; VERDICT="FAIL: $1"; exit 1; }

IFS='|' read -r crc ckind cstub <<<"$(run)"
show clean "$crc" "$ckind"
# The clean run is the baseline: it must be a plain success, else the comparison means nothing.
[ "$cstub" = 1 ] && fail "a stubbed symbol was hit (AFL-HARNESS-STUB on stderr in the clean run, rc=$crc): the harness reached code it stubs out."
[ "$crc" = 124 ] && fail "the seed hangs the clean harness (timed out after 60 s); choose a different seed (SEED=...)."
if [ "$crc" != 0 ] || [ -n "$ckind" ]; then
  fail "the seed already crashes or fails without the fault (rc=$crc, kind=${ckind:-none}); choose a different seed (SEED=...)."
fi
sed -i "$FAULT_SED" "$FAULT_SRC"
grep -q INJECTED "$FAULT_SRC" || { echo "FAIL: FAULT_SED did not apply (source changed upstream?)" >&2; exit 1; }
MODIFIED=1
# Show where it landed: a pattern that matches earlier than you meant (the same line in
# another function) is the usual cause of a false "not detecting".
echo "fault at: $(grep -n INJECTED "$FAULT_SRC" | head -3 | cut -c1-120 | paste -sd';')"
cp "$FAULT_SRC" "$FAULT_SRC.injected"      # kept only if the rebuild fails; see restore()
if ! eval "$REBUILD" > "$BK.build" 2>&1; then
  echo "FAIL: REBUILD failed with the fault applied." >&2
  # diagnostics go to the CURRENT directory (the fuzz workspace), never into the package
  # or its submodules, so the target's tree stays clean for the real-stack comparison
  cp "$BK.build" "./selftest-failed.build.log"
  mv "$FAULT_SRC.injected" "./selftest-failed.$(basename "$FAULT_SRC").injected"
  echo "      compiler output: ./selftest-failed.build.log  (0 bytes means REBUILD itself discards its output)" >&2
  echo "      patched source kept at: ./selftest-failed.$(basename "$FAULT_SRC").injected" >&2
  echo "      Common cause besides a mangled FAULT_SED: the injected statement does not" >&2
  echo "      compile -- a const-qualified field needs a cast, a C++ TU needs a decl in scope." >&2
  grep -m3 -E 'error:' "$BK.build" >&2 || true
  exit 1
fi
IFS='|' read -r rc kind fstub <<<"$(run)"
show 'with injected fault' "$rc" "$kind"

[ "$fstub" = 1 ] && fail "a stubbed symbol was hit (AFL-HARNESS-STUB on stderr in the faulted run, rc=$rc): the harness reached code it stubs out."
# This is the sanitized build: a sanitizer report is required; a bare exit code is not enough.
if [ -n "$kind" ] && { [ "$rc" != "$crc" ] || [ "$kind" != "$ckind" ]; }; then
  VERDICT="PASS: the harness detects memory errors injected into the library ($kind, rc=$rc)."
else
  VERDICT_FD=2
  if [ "$rc" = 124 ]; then
    VERDICT="FAIL: the faulted run timed out; a hang is not a detected memory error (rc=$rc, kind=${kind:-none})."
  elif [ -n "$kind" ]; then
    VERDICT="FAIL: the faulted run is indistinguishable from the clean run (rc=$rc, kind=$kind)."
  else
    VERDICT="FAIL: injected fault went unnoticed (rc=$rc, no sanitizer report).
      Check rule 1 (allocation boundary), rule 2 (seed reaches the code), and that
      REBUILD re-exported AFL_USE_ASAN=1 so the patched file was compiled with ASAN."
  fi
  exit 1
fi
