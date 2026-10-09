#!/bin/bash
# Find seeds whose harness output is not deterministic: run each one RUNS times on the
# same binary and compare the result lines.  A seed that does not agree with itself
# cannot pass the gate reliably, and its mutants make the campaign's stability drop.
#
#   resources/nondet.sh HARNESS=./out/plain/harness-fork CORPUS=./corpus-final \
#       [RUNS=6] [MODES="MODE=file"] [FIELDS="status err out_len out_hash"] [MOVE=./corpus-nondet]
#
# Prints one line per unstable seed (with how many distinct results it gave); with MOVE=
# it moves them there, out of the corpus, and reminds you to re-run measure.sh and cover.sh.
# A seed also in $WS/crashers/ (same name or bytes) is reported, never moved.  Cause seen in the sibling Ruby plugin's
# validation: a library that serialises several entries of one kind in hash-seed order,
# so one seed gave several orderings.  Quarantine, or canonicalise the order on both
# sides of the gate; do not loosen FIELDS to absorb it.
#
# MODES and FIELDS default from $WORKSPACE/fuzz.env (WORKSPACE default .); arguments win.
set -uo pipefail
for kv in "$@"; do case $kv in WORKSPACE=*) export "$kv";; esac; done   # find fuzz.env first
WS=${WORKSPACE:-.}; [ -f "$WS/fuzz.env" ] && { set -a; . "$WS/fuzz.env"; set +a; }
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
HARNESS=${HARNESS:?set HARNESS=./out/plain/harness-fork}
CORPUS=${CORPUS:?set CORPUS=<dir>}
RUNS=${RUNS:-6}
FIELDS=${FIELDS:-status err out_len out_hash}
MOVE=${MOVE:-}
pick() { for f in $FIELDS; do grep -oE "(^| )$f=[^ ]*" <<<"$1" | head -1; done | tr -d ' ' | tr '\n' ' '; }
n=0; bad=0; crash=0; moved=0
# A seed in crashers/ (same name or bytes) that gives a different result each run is a
# plain-harness over-read returning garbage: the bug's own reproducer.  One run quarantined
# 20 such seeds.  Report it, never move it.
CRASH_MD5=$(find "$WS/crashers" -maxdepth 1 -type f -exec md5sum {} + 2>/dev/null | cut -d' ' -f1 | sort -u)
is_crasher() {  # <seed>
  [ -d "$WS/crashers" ] || return 1
  [ -f "$WS/crashers/$(basename "$1")" ] && return 0
  [ -n "$CRASH_MD5" ] && grep -qxF "$(md5sum < "$1" | cut -d' ' -f1)" <<<"$CRASH_MD5"
}
for setting in "" ${MODES:-}; do
  setting=${setting%%:*}   # drop the gate's per-mode options (MODE=x:min_arms=1), as sweep.sh does
  for s in "$CORPUS"/*; do
    [ -f "$s" ] || continue
    n=$((n+1))
    distinct=$(for i in $(seq "$RUNS"); do
                 out=$(env ${setting//,/ } timeout 30 "$HARNESS" "$s" 2>/dev/null | grep -m1 'status=')
                 pick "$out"; echo
               done | sort -u | wc -l)
    if [ "$distinct" -gt 1 ]; then
      bad=$((bad+1))
      if is_crasher "$s"; then
        crash=$((crash+1))
        echo "NONDET (also a crasher: the over-read is the bug, keep it in crashers/) ${setting:-default}: $(basename "$s") -- $distinct distinct results in $RUNS runs"
        continue
      fi
      echo "NONDET ${setting:-default}: $(basename "$s") -- $distinct distinct results in $RUNS runs"
      if [ -n "$MOVE" ] && [ -f "$s" ]; then mkdir -p "$MOVE"; mv "$s" "$MOVE/"; moved=$((moved+1)); fi
    fi
  done
done
echo "$bad of $n seed runs nondeterministic ($RUNS runs each, fields: $FIELDS)"
[ "$crash" -gt 0 ] && echo "  $crash of them also in $WS/crashers/ (same name or bytes): not moved"
if [ "$moved" -gt 0 ]; then
  echo "  moved $moved seed(s) to $MOVE: re-run measure.sh and cover.sh on $CORPUS (its edges and cover changed)"
fi
[ "$((bad - crash))" = 0 ]   # a crasher's nondeterminism is the bug, not a harness fault
