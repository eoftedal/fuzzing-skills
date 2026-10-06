#!/bin/bash
# Per-seed execution cost, to find the few seeds that dominate a campaign.
#   HARNESS=./out/plain/harness-fork CORPUS=./corpus [REPS=20] [TIMEOUT=5] ./cost.sh
#
# TIMEOUT (seconds, default 5) bounds each run; a seed that exceeds it is listed as
# `hang` (not timed further) and counted at the end.
#
# Each run is one fork+exec, which costs far more than the parse itself, so the raw
# number is useless on its own.  An empty input is measured first as the startup
# baseline and subtracted; what remains is the per-seed work.  Treat it as a ranking,
# not an absolute -- for absolute numbers, time the parse in-process.
set -uo pipefail
for kv in "$@"; do export "$kv"; done
: "${HARNESS:?set HARNESS}" "${CORPUS:?set CORPUS}" "${REPS:=20}" "${TIMEOUT:=5}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
: > "$T/empty"
run() { local f=$1 s e i rc; s=$(date +%s%N)
        for ((i=0;i<REPS;i++)); do
          timeout -k1 "$TIMEOUT" "$HARNESS" "$f" >/dev/null 2>&1; rc=$?
          case $rc in 124|137) echo hang; return ;; esac
        done
        e=$(date +%s%N); echo $(( (e-s)/1000/REPS )); }
BASE=$(run "$T/empty"); B2=$(run "$T/empty")
[ "$B2" -lt "$BASE" ] && BASE=$B2        # take the faster of two, less noise
echo "startup baseline (empty input): ${BASE} us/exec -- subtracted below"
echo "  (if the EMPTY input is itself valid for this format -- an empty pattern, an empty"
echo "   document -- the baseline contains real work and every figure below is under-reported"
echo "   by that much. Treat the column as a RANKING, not an absolute.)"
for f in "$CORPUS"/*; do
  [ -f "$f" ] || continue
  t=$(run "$f")
  if [ "$t" = hang ]; then printf '%10s %10s  %s\n' hang "$(stat -c%s "$f")" "$(basename "$f")" >> "$T/hangs"; continue; fi
  printf '%10d %10s  %s\n' $(( t > BASE ? t - BASE : 0 )) "$(stat -c%s "$f")" "$(basename "$f")"
done | sort -rn > "$T/rows"
echo "hangs: $(cat "$T/hangs" 2>/dev/null | wc -l) (over TIMEOUT=${TIMEOUT}s; listed first)"
printf '%10s %10s  %s\n' "us-work" "bytes" "seed"
cat "$T/hangs" "$T/rows" 2>/dev/null
