#!/bin/bash
# Per-seed coverage for one corpus.  Writes maps to maps_<BASE>/ and prints the four
# numbers that matter.  Run this BEFORE generating anything, on whatever corpus exists.
#
#   ./measure.sh BASE=baseline HARNESS=./out/plain/harness-fork CORPUS=./corpus [MAP_SIZE=] [TIMEOUT=5] [JOBS=8]
#
# TIMEOUT is whole seconds per run (default 5), for afl-showmap (-t) and for the result pass
# (timeout -k1).  A seed that exceeds it is recorded with rc=hang instead of blocking.
# JOBS seeds run at once (default 8).  Cost is about two process starts per seed; on a
# thousand-seed fixture dump that is still minutes, so measure an UNMINIMISED borrowed set
# only once (or send it straight to minimise.sh, one fork per candidate) and use
# NO_RESULTS=1 for sweeps.
#
# HARNESS must take the input as argv[1] (the fork-mode binary, not the persistent one).
# For a harness with several MODE= entry points, run this once per mode (sweep.sh does
# exactly that and also writes the per-seed union).
#
# Two runs per seed: afl-showmap for the map, and the harness itself for the exit code
# and result line.  The second run's output is SAVED to maps_<BASE>/.results as
#   <rc>\t<result line>\t<seed name>
# so validate.sh (RESULTS=) and error_inventory.sh (RESULTS=) can read it instead of
# running the harness again.  It is ALWAYS written; NO_RESULTS=1 skips that pass on a
# slow target (then validate.sh needs HARNESS= and runs the seeds itself).
# maps_<BASE>/.edges holds the edge total and is written as soon as it is known, so a
# `| head` on this script's output cannot lose it.
set -uo pipefail
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
: "${HARNESS:?set HARNESS}" "${CORPUS:?set CORPUS}" "${BASE:=corpus}" "${TIMEOUT:=5}" "${JOBS:=8}"
MAP_SIZE=${MAP_SIZE:-$(AFL_DUMP_MAP_SIZE=1 "$HARNESS" 2>/dev/null | tail -1)}
MAP_SIZE=${MAP_SIZE:-131072}
D="maps_$BASE"; rm -rf "$D"; mkdir -p "$D"
export HARNESS MAP_SIZE TIMEOUT D
seeds() { find "$CORPUS" -maxdepth 1 -type f -print0 | sort -z; }
n=$(seeds | tr -cd '\0' | wc -c)
seeds | xargs -0 -P "$JOBS" -I{} bash -c \
  'AFL_MAP_SIZE=$MAP_SIZE AFL_QUIET=1 afl-showmap -t $((TIMEOUT*1000)) -o "$D/$(basename "$1")" -- "$HARNESS" "$1" >/dev/null 2>&1' _ {}
EDGES=$(cat "$D"/* 2>/dev/null | cut -d: -f1 | sort -u | wc -l)
echo "$EDGES" > "$D/.edges"
# one edge-set hash per map, computed once and reused for the unique count and the duplicate list
for m in "$D"/*; do
  [ -f "$m" ] || continue
  printf '%s\t%s\n' "$(cut -d: -f1 "$m" | sort -u | md5sum | cut -d' ' -f1)" "$(basename "$m")"
done > "$D/.hashes"
UNIQ=$(cut -f1 "$D/.hashes" | sort -u | wc -l)
echo "corpus      $CORPUS  ($n files, map size $MAP_SIZE)"
echo "edges       $EDGES distinct"
echo "unique maps $UNIQ of $n   <- want these close"
if [ "${NO_RESULTS:-0}" != 1 ]; then
  seeds | xargs -0 -P "$JOBS" -I{} bash -c '
    out=$(timeout -k1 "$TIMEOUT" "$HARNESS" "$1" 2>/dev/null); rc=$?
    line=$(printf "%s\n" "$out" | head -1)
    case $rc in 124|137) rc=hang ;; esac       # timed out (or killed): never a success
    printf "%s\t%s\t%s\n" "$rc" "$line" "$(basename "$1")"' _ {} | sort -t$'\t' -k3 > "$D/.results"
  echo "exit codes:"
  cut -f1 "$D/.results" | sort | uniq -c | sed 's/^ *\([0-9]*\) /  \1 rc=/'
  echo "hangs       $(grep -c '^hang' "$D/.results") (over TIMEOUT=${TIMEOUT}s; see SKILL.md seed policy)"
  echo "(result lines saved to $D/.results; pass RESULTS=$D/.results to validate.sh)"
else
  echo "exit codes: (skipped, NO_RESULTS=1: no .results written; validate.sh needs HARNESS= and CORPUS=)"
fi
# Capped: a 700-seed corpus has hundreds of these and they are a diagnostic, not a result.
# The full list is in maps_<BASE>/.duplicates.  For a harness with MODE= settings this
# covers the CURRENT mode only: a seed written for another mode shares the default mode's
# early-exit map with every other such seed and shows up here as a duplicate it is not.
awk -F'\t' '{ if ($1 in first) printf "  %-34s == %s\n", $2, first[$1]; else first[$1]=$2 }' "$D/.hashes" > "$D/.duplicates"
ndup=$(wc -l < "$D/.duplicates")
echo "duplicate-coverage seeds (same edge set as an earlier file): $ndup${MODE:+ in this mode (MODE=$MODE); seeds written for other modes collide here by design}"
head -20 "$D/.duplicates"
[ "$ndup" -gt 20 ] && echo "  ... $((ndup - 20)) more in $D/.duplicates"
