#!/bin/bash
# Step 7 seed policy: move hangs and plain-harness crashers out of corpus-final/, copy out
# ASAN-only crashers, and rebuild crashers.summary.tsv.  Run after measure.sh BASE=final.
#
#   $RC/union_crashers.sh [FINAL=./corpus-final] [RESULTS=./maps_final/.results]
#                         [ASAN=./out/asan/harness-fork] [TIMEOUT=30] [JOBS=8] [ALLOC_CAP_MB=1024]
#
# * rc=hang in RESULTS             -> moved to hangs/ (no summary row)
# * rc >= 128 (a signal) in RESULTS -> moved to crashers/, row "<name>\tplain rc=<rc>"
# * any remaining seed whose ASAN run prints a SUMMARY: line -> COPIED to crashers/ (it
#   stays a seed: the plain harness survives it), row "<name>\t<SUMMARY: line>".
#   Default mode only.  The allocation ceiling and the 30 s timeout: references/
#   measured-examples.md, step 7.
#
# crashers.summary.tsv: every existing row whose file is still in crashers/ or hangs/ is
# KEPT, whatever its name (smoke-*, gate-real-*, gate-both-*, hand-filed, an earlier pass);
# rows for files that are gone are dropped; a row this run writes replaces an existing row
# for the same name, so re-running adds no duplicates.  Counts go to stderr.
# KEY=VALUE defaults come from $WORKSPACE/fuzz.env (WORKSPACE default .); arguments win.
set -uo pipefail
for kv in "$@"; do case $kv in WORKSPACE=*) export "$kv";; esac; done   # find fuzz.env first
WS=${WORKSPACE:-.}; [ -f "$WS/fuzz.env" ] && { set -a; . "$WS/fuzz.env"; set +a; }
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
: "${FINAL:=./corpus-final}" "${RESULTS:=./maps_final/.results}" "${ASAN:=./out/asan/harness-fork}"
: "${TIMEOUT:=30}" "${JOBS:=8}" "${ALLOC_CAP_MB:=1024}"
[ -s "$RESULTS" ] || { echo "union_crashers: no $RESULTS (run measure.sh BASE=final without NO_RESULTS)" >&2; exit 2; }
[ -x "$ASAN" ] || { echo "union_crashers: no ASAN harness $ASAN" >&2; exit 2; }
mkdir -p crashers hangs; touch crashers.summary.tsv
NEW=$(mktemp); trap 'rm -f "$NEW" "$NEW.old" "$NEW.names"' EXIT

awk -F'\t' '$1=="hang"{print $3}' "$RESULTS" | while read -r n; do
  [ -e "$FINAL/$n" ] && mv "$FINAL/$n" hangs/; done
awk -F'\t' '$1~/^[0-9]+$/ && $1>=128 {print $1"\t"$3}' "$RESULTS" | while IFS=$'\t' read -r rc n; do
  [ -e "$FINAL/$n" ] && mv "$FINAL/$n" crashers/ && printf '%s\tplain rc=%s\n' "$n" "$rc" >> "$NEW"; done

export ASAN_OPTIONS="detect_leaks=0:exitcode=86:allocator_may_return_null=1:max_allocation_size_mb=$ALLOC_CAP_MB"
find "$FINAL" -maxdepth 1 -type f -print0 | xargs -0 -r -P "$JOBS" -I{} bash -c '
  o=$(timeout -k1 "$2" "$3" "$1" 2>&1 >/dev/null); rc=$?
  s=$(printf "%s\n" "$o" | grep -m1 "^SUMMARY:")
  if [ -n "$s" ]; then cp "$1" crashers/ && printf "%s\t%s\n" "$(basename "$1")" "$s"
  elif [ $rc -eq 86 ] || [ $rc -ge 124 ] || printf "%s" "$o" | grep -q "ERROR: AddressSanitizer"; then
    echo "WARN: $(basename "$1") rc=$rc but no SUMMARY: line: raise TIMEOUT" >&2; fi' _ {} "$TIMEOUT" "$ASAN" >> "$NEW"

# merge: existing rows whose file exists and that this run did not rewrite, then this run's
cut -f1 "$NEW" > "$NEW.names"; kept=0; dropped=0
while IFS= read -r row || [ -n "$row" ]; do
  n=${row%%$'\t'*}; [ -n "$n" ] || continue
  grep -qxF -- "$n" "$NEW.names" && continue
  if [ -e "crashers/$n" ] || [ -e "hangs/$n" ]; then printf '%s\n' "$row"; kept=$((kept+1)); else dropped=$((dropped+1)); fi
done < crashers.summary.tsv > "$NEW.old"
echo "union_crashers: kept $kept existing rows, dropped $dropped for missing files" >&2
cat "$NEW.old" > crashers.summary.tsv
cat "$NEW" >> crashers.summary.tsv
echo "union_crashers: $(wc -l < "$NEW") rows from this pass; $(wc -l < crashers.summary.tsv) rows in crashers.summary.tsv" >&2
