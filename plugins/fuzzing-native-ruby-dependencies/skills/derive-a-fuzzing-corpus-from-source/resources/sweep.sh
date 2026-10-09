#!/bin/bash
# Measure one corpus under several harness settings (env vars: the gem's modes,
# the harness's MODE=, option flags) and report per-setting edges plus the union.
#
#   ./sweep.sh BASE=baseline HARNESS=./out/plain/harness-fork CORPUS=./corpus \
#              SWEEP='MODE=buffer MODE=file XML_OPTS=validate' [MAP_SIZE=...]
#
# Each setting is one KEY=VALUE token (or several joined with commas: 'A=1,B=2').
# Per-mode options after a colon (MODE=compress:min_arms=1, as gate.sh and campaign.sh
# take them) are dropped, so SWEEP="$MODES" works with the string the gate took.  The
# CURRENT environment is always measured first as `default`, so do not list it in SWEEP
# (SWEEP='MODE=default ...' measures it twice).  Directory names: maps_<BASE>_default and
# maps_<BASE>_<setting with '=' and ',' as '_'>, e.g. maps_baseline_MODE_compress -- pass
# those exact names to minimise.sh HAVE= and cover.sh MAPS=.  A long value (a 5 KB
# SUBJECT=) is fine: the tag is truncated plus a hash of the setting.  MAP_SIZE is passed
# through to measure.sh.
# SWEEP defaults to MODES (argument, environment, or $WORKSPACE/fuzz.env, WORKSPACE default .).
# When fuzz.env lists no modes it measures the default only and exits 0, so it is safe to
# call unconditionally.  A measure.sh failure (no maps at all) fails the sweep.
# Writes maps_<BASE>_<setting>/ per setting via measure.sh (each with its .results, so
# validate.sh RESULTS= works per setting; NO_RESULTS=1 skips that), and maps_<BASE>_union/
# as the per-seed union, so compare.sh can take the union as an A or B side.
#
# Sweep the BASELINE over the same settings as the derived corpus, or the two numbers
# you compare are not comparable.
set -uo pipefail
for kv in "$@"; do case $kv in WORKSPACE=*) export "$kv";; esac; done   # find fuzz.env first
WS=${WORKSPACE:-.}; [ -f "$WS/fuzz.env" ] && { set -a; . "$WS/fuzz.env"; set +a; }
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
: "${HARNESS:?set HARNESS}" "${CORPUS:?set CORPUS}" "${BASE:=corpus}"
if [ -z "${SWEEP:-}" ]; then
  if [ -n "${MODES:-}" ]; then SWEEP=$MODES
  elif [ -f "$WS/fuzz.env" ]; then echo "no modes: measuring the default only"; SWEEP=""
  else : "${SWEEP:?set SWEEP='K=V K=V ...' (or MODES=, or a fuzz.env)}"; fi
fi
HERE=$(cd "$(dirname "$0")" && pwd)
U="maps_${BASE}_union"; rm -rf "$U"; mkdir -p "$U"
printf '%-32s %s\n' setting edges
for setting in default $SWEEP; do
  setting=${setting%%:*}             # the chain's per-mode options are not env vars
  tag=$(tr ',=' '__' <<<"$setting" | tr -c 'A-Za-z0-9_\n' '_')
  [ ${#tag} -gt 60 ] && tag="${tag:0:40}_$(printf '%s' "$setting" | md5sum | cut -c1-8)"
  envs=""; [ "$setting" != default ] && envs=$(tr ',' ' ' <<<"$setting")
  # .results is written per setting too (validate.sh RESULTS=maps_<base>_<tag>/.results), unless
  # NO_RESULTS=1 is passed to this script; measure.sh runs in parallel, so it costs little
  env $envs "$HERE/measure.sh" BASE="${BASE}_$tag" HARNESS="$HARNESS" CORPUS="$CORPUS" NO_RESULTS="${NO_RESULTS:-0}" >/dev/null \
    || { echo "FAIL: measure.sh failed for setting '$setting' (its cause is above)" >&2; exit 1; }
  printf '%-32s %s\n' "$setting" "$(cat "maps_${BASE}_$tag/.edges")"
  for m in "maps_${BASE}_$tag"/*; do
    [ -f "$m" ] || continue
    cat "$m" >> "$U/$(basename "$m")"
  done
done
for m in "$U"/*; do sort -u -o "$m" "$m"; done
cat "$U"/* | cut -d: -f1 | sort -u | wc -l > "$U/.edges"
printf '%-32s %s\n' "UNION ($U)" "$(cat "$U/.edges")"
echo "compare a swept corpus against another swept corpus with the unions:"
echo "  compare.sh A=maps_<other>_union B=$U"
