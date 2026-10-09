#!/bin/bash
# Flag drift between the generic AFL++ scripts the Node and Ruby plugins each carry a
# copy of.  Comment lines and blank lines are ignored, so only code differences show.
# Some differences are intended (marker names, file-name hints); they are listed in
# scripts/shared-allow.txt as "<relative path>\t<sha1 of the code diff>" and pass while
# the diff is unchanged.
#
#   scripts/check_shared.sh            # summary; exit 1 on unexpected drift
#   scripts/check_shared.sh -v         # also print each unexpected diff
#   scripts/check_shared.sh --accept   # record the current diffs as intended
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
N=$ROOT/plugins/fuzzing-native-node-dependencies/skills
R=$ROOT/plugins/fuzzing-native-ruby-dependencies/skills
ALLOW=$ROOT/scripts/shared-allow.txt
MODE=${1:-}

# <node path> <ruby path>, relative to each plugin's skills/
PAIRS="
build-a-nan-napi-fuzzing-harness/resources/gate.sh build-a-ruby-c-extension-fuzzing-harness/resources/gate.sh
build-a-nan-napi-fuzzing-harness/resources/smoke.sh build-a-ruby-c-extension-fuzzing-harness/resources/smoke.sh
build-a-nan-napi-fuzzing-harness/resources/detect_selftest.sh build-a-ruby-c-extension-fuzzing-harness/resources/detect_selftest.sh
build-a-nan-napi-fuzzing-harness/resources/find_afl_rt.sh build-a-ruby-c-extension-fuzzing-harness/resources/find_afl_rt.sh
build-a-nan-napi-fuzzing-harness/resources/find_asan_rt.sh build-a-ruby-c-extension-fuzzing-harness/resources/find_asan_rt.sh
build-a-nan-napi-fuzzing-harness/resources/afl_shim.h build-a-ruby-c-extension-fuzzing-harness/resources/afl_shim.h
build-a-nan-napi-fuzzing-harness/resources/covstub.c build-a-ruby-c-extension-fuzzing-harness/resources/covstub.c
build-a-nan-napi-fuzzing-harness/resources/undef_fuzzmode.h build-a-ruby-c-extension-fuzzing-harness/resources/undef_fuzzmode.h
build-a-nan-napi-fuzzing-harness/resources/preflight.sh build-a-ruby-c-extension-fuzzing-harness/resources/preflight.sh
build-a-nan-napi-fuzzing-harness/resources/init_workspace.sh build-a-ruby-c-extension-fuzzing-harness/resources/init_workspace.sh
build-a-nan-napi-fuzzing-harness/resources/mkgate.sh build-a-ruby-c-extension-fuzzing-harness/resources/mkgate.sh
"
for f in compare.sh cost.sh cover.sh dict.sh enumerate_constants.sh errenum_template.c error_inventory.sh measure.sh minimise.sh nondet.sh sweep.sh validate.sh; do
  PAIRS="$PAIRS
derive-a-fuzzing-corpus-from-source/resources/$f derive-a-fuzzing-corpus-from-source/resources/$f"
done
for f in screen.sh bucket.sh minimize.sh; do
  PAIRS="$PAIRS
triage-fuzzing-findings/resources/$f triage-fuzzing-findings/resources/$f"
done
PAIRS="$PAIRS
run-a-fuzzing-campaign/resources/campaign.sh run-a-fuzzing-campaign/resources/campaign.sh"

code() {   # strip comment-only and blank lines (#, //, /* * */ continuation lines)
  grep -vE '^[[:space:]]*(#|//|/\*|\*|$)' "$1" | grep -v '^#!'
}

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
[ "$MODE" = --accept ] && : > "$ALLOW"
same=0; allowed=0; drift=0; missing=0
while read -r a b; do
  [ -n "$a" ] || continue
  if [ ! -f "$N/$a" ] || [ ! -f "$R/$b" ]; then
    echo "MISSING  $b"; missing=$((missing + 1)); continue
  fi
  diff <(code "$N/$a") <(code "$R/$b") > "$T/d"
  if [ ! -s "$T/d" ]; then same=$((same + 1)); continue; fi
  # hash only the differing lines, not diff's hunk headers: an edit made to BOTH copies
  # shifts the line numbers and must not turn a reviewed difference into "drift"
  h=$(grep '^[<>]' "$T/d" | shasum | cut -c1-40)
  if [ "$MODE" = --accept ]; then
    printf '%s\t%s\n' "$b" "$h" >> "$ALLOW"; allowed=$((allowed + 1))
  elif grep -qF "$(printf '%s\t%s' "$b" "$h")" "$ALLOW" 2>/dev/null; then
    allowed=$((allowed + 1))
  else
    echo "DRIFT    $b ($(grep -c '^[<>]' "$T/d") code lines differ)"
    [ "$MODE" = -v ] && sed 's/^/    /' "$T/d"
    drift=$((drift + 1))
  fi
done <<<"$PAIRS"
echo "$same identical, $allowed intended differences, $drift drift, $missing missing"
[ $((drift + missing)) -eq 0 ]
