#!/bin/bash
# Keep only the candidate seeds that add edges on top of a corpus you already have.
# Use after a discovery sweep: sweeping finds which field matters, this stops you
# shipping 200 near-duplicates for a handful of edges.
#
#   HAVE="maps_full [maps_other ...]" CAND=./corpus-sweep HARNESS=./out/plain/harness-fork \
#   KEEP=./corpus-extra [MAP_SIZE=] [TIMEOUT=5] [MODES="MODE=file MODE=string"] ./minimise.sh
#
# HAVE may name several map directories (space-separated): every A-side you have, and the
# per-mode directories of a swept corpus.  With MODES=, each candidate is run once per
# setting (plus the current environment) and kept if it adds an edge in ANY of them; HAVE
# should then hold the per-mode maps too, or everything looks new.
#
# Greedy and order-dependent by design: each kept seed must add something the ones
# already kept do not.  For a whole corpus use cover.sh over its maps (afl-cmin does
# the same job but can hang on some hosts); this is for triaging an additive batch.
set -uo pipefail
for kv in "$@"; do export "$kv"; done
: "${HAVE:?set HAVE}" "${CAND:?set CAND}" "${HARNESS:?set HARNESS}" "${KEEP:=./corpus-extra}" "${TIMEOUT:=5}"
MODES=${MODES:-}
# A HAVE directory that does not exist (a mistyped sweep.sh name: it writes
# maps_<base>_MODE_compress, not maps_<base>_MODE=compress) would make every candidate
# look new and the gains meaningless, silently.
for h in $HAVE; do [ -d "$h" ] || { echo "FAIL: HAVE directory $h does not exist (sweep.sh names its directories maps_<base>_<tag>, '=' -> '_')" >&2; exit 2; }; done
MAP_SIZE=${MAP_SIZE:-$(AFL_DUMP_MAP_SIZE=1 "$HARNESS" 2>/dev/null | tail -1)}
MAP_SIZE=${MAP_SIZE:-131072}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$KEEP"
for h in $HAVE; do cat "$h"/* 2>/dev/null; done | cut -d: -f1 | sort -u > "$T/have"
showmap() {   # <setting or ""> <seed> -> edges on stdout
  local s=$1 f=$2
  if [ -n "$s" ]; then s=${s%%:*}
    env ${s//,/ } AFL_MAP_SIZE=$MAP_SIZE AFL_QUIET=1 afl-showmap -t $((TIMEOUT*1000)) -o "$T/m" -- "$HARNESS" "$f" >/dev/null 2>&1
  else AFL_MAP_SIZE=$MAP_SIZE AFL_QUIET=1 afl-showmap -t $((TIMEOUT*1000)) -o "$T/m" -- "$HARNESS" "$f" >/dev/null 2>&1; fi
  cut -d: -f1 "$T/m" 2>/dev/null; rm -f "$T/m"
}
kept=0; seen=0
for f in "$CAND"/*; do
  [ -f "$f" ] || continue
  seen=$((seen+1))
  { showmap "" "$f"; for s in $MODES; do showmap "$s" "$f"; done; } | sort -u > "$T/e"
  new=$(comm -13 "$T/have" "$T/e" | wc -l)
  if [ "$new" != 0 ]; then
    cp "$f" "$KEEP/"; kept=$((kept+1))
    printf '  +%-4s %s\n' "$new" "$(basename "$f")"
    sort -u "$T/have" "$T/e" > "$T/have2" && mv "$T/have2" "$T/have"
  fi
done
echo "kept $kept of $seen candidates -> $KEEP"
