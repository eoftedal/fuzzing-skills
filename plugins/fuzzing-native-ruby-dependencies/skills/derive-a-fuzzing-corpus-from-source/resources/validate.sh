#!/bin/bash
# Step 6: prove the seeds reach deep code rather than merely running.
#   ./validate.sh HARNESS=./out/plain/harness-fork CORPUS=./corpus [FIELD=err] [PREFIX=fam-] [TIMEOUT=5]
#   ./validate.sh RESULTS=maps_baseline/.results [FIELD=err] [PREFIX=fam-] [IGNORE="out_hash out_len"]
#
# RESULTS= and PREFIX= combine: one measure.sh run, then one validate.sh per family
# with no harness runs at all.
# IGNORE= names fields stripped from the result line before the "share a result line"
# grouping (in_len is always stripped).  IGNORE="out_hash out_len" groups by error
# and status only, which shows "same early error" even when outputs differ.
#
# FIELD names a key in the harness's result line to group by -- use the target's own
# error/status field (`err` in the companion harness skill's template).  "Every seed
# reports the same early error" is the failure this catches, and it is invisible in an
# exit-code histogram alone.
#
# PREFIX restricts the run to seeds whose basename starts with it.  Insist on a
# per-family histogram: one broken family of 15 disappears into 200 healthy seeds.
#
# TIMEOUT (seconds, default 5) bounds each harness run; a seed over it is rc=hang, and
# the hang count is printed (a looping seed is never counted as a success).
#
# The harness runs ONCE per seed (or not at all with RESULTS= from measure.sh); all
# three summaries come from that one pass.
set -uo pipefail
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
: "${FIELD:=status}"
PREFIX=${PREFIX:-}
IGNORE="in_len ${IGNORE:-}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

if [ -n "${RESULTS:-}" ]; then
  [ -f "$RESULTS" ] || { echo "no such RESULTS file: $RESULTS" >&2; exit 1; }
  awk -F'\t' -v p="$PREFIX" 'index($3, p) == 1' "$RESULTS" > "$T/r"
else
  : "${HARNESS:?set HARNESS or RESULTS}" "${CORPUS:?set CORPUS or RESULTS}"
  for f in "$CORPUS"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in ${PREFIX}*) ;; *) continue ;; esac
    out=$(timeout -k1 "${TIMEOUT:-5}" "$HARNESS" "$f" 2>/dev/null); rc=$?
    line=${out%%$'\n'*}
    case $rc in 124|137) rc=hang ;; esac
    printf '%s\t%s\t%s\n' "$rc" "$line" "$(basename "$f")"
  done > "$T/r"
fi
n=$(wc -l < "$T/r")
echo "== $n seeds${PREFIX:+ with prefix $PREFIX} =="
echo "== exit codes =="
cut -f1 "$T/r" | sort | uniq -c | sed 's/^ *\([0-9]*\) /  \1 rc=/'
echo "  hangs: $(grep -c '^hang' "$T/r")"
echo "== distribution of $FIELD across seeds =="
cut -f2 "$T/r" | sed -n "s/.*\b$FIELD=\([^ ]*\).*/\1/p" | sort | uniq -c | sort -rn | head -20
echo "== seeds grouped by full result line (identical line = same path) =="
awk -F'\t' -v ign="$IGNORE" 'BEGIN { n=split(ign, I, " ") }
            { l=$2; for (i=1;i<=n;i++) if (I[i]!="") gsub(I[i] "=[^ ]* ?", "", l); c[l]++; ex[l]=ex[l]" "$3 }
            END { for (k in c) if (c[k] > 1) printf "  %3d seeds share a result line:%s\n", c[k], substr(ex[k], 1, 110) }' "$T/r" \
  | sort -rn | head -12
