#!/bin/bash
# Find seeds whose harness output is not deterministic: run each one RUNS times on the
# same binary and compare the result lines.  A seed that does not agree with itself
# cannot pass the gate reliably, and its mutants make the campaign's stability drop.
#
#   resources/nondet.sh HARNESS=./out/plain/harness-fork CORPUS=./corpus-final \
#       [RUNS=6] [MODES="MODE=load"] [FIELDS="status err out_len out_hash"] [MOVE=./corpus-nondet]
#
# Prints one line per unstable seed (with how many distinct results it gave); with MOVE=
# it moves them there, out of the corpus.  Measured cause: a library that serialises
# several entries of one kind in hash-seed order, so one seed gave several orderings.  Quarantine, or canonicalise the order on both sides of the gate; do
# not loosen FIELDS to absorb it.
set -uo pipefail
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
HARNESS=${HARNESS:?set HARNESS=./out/plain/harness-fork}
CORPUS=${CORPUS:?set CORPUS=<dir>}
RUNS=${RUNS:-6}
FIELDS=${FIELDS:-status err out_len out_hash}
MOVE=${MOVE:-}
pick() { for f in $FIELDS; do grep -oE "(^| )$f=[^ ]*" <<<"$1" | head -1; done | tr -d ' ' | tr '\n' ' '; }
n=0; bad=0
for setting in "" ${MODES:-}; do
  for s in "$CORPUS"/*; do
    [ -f "$s" ] || continue
    n=$((n+1))
    distinct=$(for i in $(seq "$RUNS"); do
                 out=$(env ${setting//,/ } timeout 30 "$HARNESS" "$s" 2>/dev/null | grep -m1 'status=')
                 pick "$out"; echo
               done | sort -u | wc -l)
    if [ "$distinct" -gt 1 ]; then
      bad=$((bad+1))
      echo "NONDET ${setting:-default}: $(basename "$s") -- $distinct distinct results in $RUNS runs"
      if [ -n "$MOVE" ] && [ -f "$s" ]; then mkdir -p "$MOVE"; mv "$s" "$MOVE/"; fi
    fi
  done
done
echo "$bad of $n seed runs nondeterministic ($RUNS runs each, fields: $FIELDS)"
[ "$bad" = 0 ]
