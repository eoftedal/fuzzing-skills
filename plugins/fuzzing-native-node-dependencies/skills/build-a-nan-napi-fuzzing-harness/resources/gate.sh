#!/bin/bash
# Generic fidelity gate.  Nothing here is target-specific; it relies on one contract:
#
#   BOTH the direct harness and the real-stack harness print ONE line of
#   key=value pairs, space separated, for each input.
#
# Configure with KEY=VALUE arguments or environment variables:
#   DIRECT      command for the direct harness; the input path is appended
#   REAL        command for the real stack;      the input path is appended
#   CORPUS      directory of seeds
#   FIELDS      keys that must match exactly          (default: status)
#   ARM_FIELD   key whose distinct values are the "arms" (default: status)
#   MIN_ARMS    distinct ARM_FIELD values required    (default: 2; 1 for a target
#               that cannot reject its input, e.g. a compressor or serialiser)
#   SOFT_FIELD  key the REAL side sets to 1 when it cannot report faithfully
#   SOFT_DROP   keys to ignore when SOFT_FIELD=1     (counted oracle-limited).  List EVERY
#               field the oracle's loss can change: a U+FFFD substitution changes out_len
#               as well as out_hash, so "out_len out_hash", not "out_hash" alone
#   MODES       harness settings to gate BESIDES the current environment, space-separated
#               KEY=VALUE tokens (MODES="MODE=file MODE=string"; several joined with commas:
#               "MODE=file,ENC=utf16").  The whole gate runs once per setting, exported to
#               BOTH sides.  Same spelling as campaign.sh's MODES.  Per-mode options follow a
#               colon: MODE=compress:min_arms=1 relaxes check 3 for a mode that cannot reject
#               (a compressor, a serialiser) without weakening it for the default mode; a
#               bare :entry (campaign.sh's) is ignored here, and campaign.sh ignores min_arms=
#   JOBS        seeds compared in parallel (default 8; node startup dominates, so this is
#               what makes a 1000-seed re-gate take a minute instead of five)
#   MAP_SIZE    AFL_MAP_SIZE (ask the binary: AFL_DUMP_MAP_SIZE=1 ./harness)
#   ALLOC_CAP_MB  allocation ceiling in the default ASAN_OPTIONS (default 1024, as in
#               campaign.sh): a seed declaring a huge allocation is then refused the same
#               way on both sides instead of printing nothing on one
#
# Sanitized real side: put the runtime preload INSIDE REAL=, never in front of gate.sh:
#   ./gate.sh DIRECT=./out/asan/harness-fork \
#             REAL="env LD_PRELOAD=$(resources/find_asan_rt.sh) ADDON=/abs/out/asan/Release/<name>.node node real_harness.mjs" ...
# In front of gate.sh it is preloaded into afl-showmap and the direct harness too, and every
# seed comes out NO-OUTPUT (rc=86, empty message) / "afl-showmap produced nothing".
#
# Example:
#   ./gate.sh DIRECT=./out/plain/harness-fork REAL="node real_harness.mjs" CORPUS=./corpus \
#             FIELDS="status err out_len out_hash" SOFT_FIELD=lossy SOFT_DROP="out_len out_hash" \
#             MODES="MODE=file"
#
# Exit status is 0 only when every check passes in every mode, so it can gate a build script.
set -uo pipefail
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
DIRECT=${DIRECT:?set DIRECT}
REAL=${REAL:?set REAL}
CORPUS=${CORPUS:?set CORPUS}
FIELDS=${FIELDS:-status}
ARM_FIELD=${ARM_FIELD:-status}
MIN_ARMS=${MIN_ARMS:-2}
SOFT_FIELD=${SOFT_FIELD:-}
SOFT_DROP=${SOFT_DROP:-}
MODES=${MODES:-}
JOBS=${JOBS:-8}
ALLOC_CAP_MB=${ALLOC_CAP_MB:-1024}
export AFL_MAP_SIZE=${MAP_SIZE:-131072}
# A harness that keeps one-time state (a shared context created in init) trips
# LeakSanitizer at exit and prints nothing; the leak is not what the gate tests.  The
# allocation ceiling matches the campaign's, so declared-size seeds fail identically on both
# sides (ASAN's default is to abort with "allocation-size-too-big" and print no result line).
export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0:exitcode=86:allocator_may_return_null=1:max_allocation_size_mb=$ALLOC_CAP_MB}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export DIRECT REAL FIELDS ARM_FIELD SOFT_FIELD SOFT_DROP TMP

first_err() { grep -m1 -E 'ERROR:|Error|error|Cannot|SUMMARY' "$1" | cut -c1-110; }
get() { sed -n "s/.*\b$2=\([^ ]*\).*/\1/p" <<<"$1" | head -1; }
key() { local line=$1 drop=${2:-} out=""; for f in $FIELDS; do
          case " $drop " in *" $f "*) continue ;; esac
          out="$out|$f=$(get "$line" "$f")"; done; echo "$out"; }
# One seed -> one tab-separated line: CLASS  name  arm  detail.  Runs under xargs -P.
judge() {
  local f=$1 n; n=$(basename "$1")
  local err=$TMP/$BASHPID.err rerr=$TMP/$BASHPID.rerr d r drc nrc marker
  d=$(timeout 30 $DIRECT "$f" 2>"$err"); drc=$?
  # The stubs and the V8PATH trap write a marker to stderr before aborting.  Catch it
  # here, per seed -- an earlier version of this gate sent stderr to /dev/null and
  # check 5 below could never fail.
  if marker=$(grep -m1 -oE 'AFL-HARNESS-(STUB|V8PATH):.*' "$err"); then
    printf 'BINDING\t%s\t\t%s\n' "$n" "$marker"; return; fi
  r=$(timeout 30 $REAL "$f" 2>"$rerr"); nrc=$?
  # (rc=124 means the 30 s timeout fired: a hang, named like any other no-output seed.)
  # A seed with no output is the interesting case: a sanitizer abort on one side (a real
  # finding) or a broken real-side command (a wrong ADDON= path).  Say which.
  if [ -z "$d" ]; then printf 'NO-OUTPUT\t%s\t\tdirect printed nothing, rc=%s: %s\n' "$n" "$drc" "$(first_err "$err")"; return; fi
  if [ -z "$r" ]; then printf 'NO-OUTPUT\t%s\t\treal printed nothing, rc=%s: %s\n' "$n" "$nrc" "$(first_err "$rerr")"; return; fi
  local arm; arm=$(get "$d" "$ARM_FIELD")
  if [ "$(key "$d")" = "$(key "$r")" ]; then printf 'AGREED\t%s\t%s\t\n' "$n" "$arm"
  elif [ -n "$SOFT_FIELD" ] && [ "$(get "$r" "$SOFT_FIELD")" = 1 ] \
       && [ "$(key "$d" "$SOFT_DROP")" = "$(key "$r" "$SOFT_DROP")" ]; then
    printf 'LIMITED\t%s\t%s\t\n' "$n" "$arm"
  else
    printf 'MISMATCH\t%s\t%s\tdirect=%s real=%s\n' "$n" "$arm" "$(key "$d")" "$(key "$r")"
  fi
}
export -f first_err get key judge

seeds() { find "$CORPUS" -maxdepth 1 -type f -print0 | sort -z; }
NSEEDS=$(seeds | tr -cd '\0' | wc -c)

one_mode() {   # runs the whole gate in the current environment; prints and returns its status
  echo "== 1+2. every seed reaches the library, and agrees with the real stack =="
  seeds | xargs -0 -P "$JOBS" -I{} bash -c 'judge "$1"' _ {} | sort -t$'\t' -k2 > "$TMP/judged"
  awk -F'\t' '$1=="BINDING"  {printf "  BINDING     %-34s %s\n", $2, $4}
              $1=="NO-OUTPUT"{printf "  NO-OUTPUT   %-34s %s\n", $2, $4}
              $1=="MISMATCH" {split($4, kv, " real="); printf "  MISMATCH    %-34s\n     direct=%s\n     real  =%s\n", $2, substr(kv[1], 8), kv[2]}' "$TMP/judged"
  local ok mism limited empty stub
  ok=$(grep -c '^AGREED' "$TMP/judged"); limited=$(grep -c '^LIMITED' "$TMP/judged")
  mism=$(grep -c '^MISMATCH' "$TMP/judged"); empty=$(grep -c '^NO-OUTPUT' "$TMP/judged")
  stub=$(grep -c '^BINDING' "$TMP/judged")
  echo "  agreed=$ok  oracle-limited=$limited  mismatched=$mism  no-output=$empty  entered-binding=$stub"
  if [ "$empty" = "$NSEEDS" ] && [ "$empty" -gt 0 ]; then
    echo "  (EVERY seed had no output on one side: the command is broken, not the seeds -- read the message above."
    if grep -q 'direct printed nothing, rc=86' "$TMP/judged"; then
      echo "   The DIRECT side died with the sanitizer exit code and no report: is a sanitizer runtime"
      echo "   LD_PRELOADed into this whole command?  It belongs inside REAL= only.)"
    else echo "   A wrong ADDON= / PKG= path, or a missing LD_PRELOAD inside REAL=, are the usual causes.)"; fi
  fi

  echo "== 3. both arms are populated ($ARM_FIELD) =="
  awk -F'\t' '$1=="AGREED"||$1=="LIMITED"||$1=="MISMATCH"{print $3}' "$TMP/judged" | sort | uniq -c | sed 's/^/    /'
  local arms; arms=$(awk -F'\t' '$1=="AGREED"||$1=="LIMITED"||$1=="MISMATCH"{print $3}' "$TMP/judged" | sort -u | grep -c .)
  if [ "$arms" -ge "$MIN_ARMS" ]; then
    echo "  OK: $arms distinct outcome(s), at or above MIN_ARMS=$MIN_ARMS"
  else
    echo "  FAIL: only $arms outcome. Add inputs the library REJECTS: the error path is"
    echo "        half the code and is where the binding's error handling lives."
    echo "        (If this entry point CANNOT reject -- a compressor or serialiser takes any"
    echo "         bytes and always succeeds -- pass MIN_ARMS=1 and note it.)"
  fi

  echo "== 4. coverage discriminates between inputs =="
  rm -f "$TMP"/*.map
  seeds | xargs -0 -P "$JOBS" -I{} bash -c 'AFL_QUIET=1 afl-showmap -q -o "$TMP/$(basename "$1").map" -- $DIRECT "$1" >/dev/null 2>&1' _ {}
  local maps; maps=$(ls "$TMP"/*.map 2>/dev/null | wc -l)
  if [ "$maps" -gt 0 ]; then
    local uniq; uniq=$(md5sum "$TMP"/*.map | awk '{print $1}' | sort -u | wc -l)
    echo "  maps=$maps unique=$uniq  tuples/input: min=$(wc -l < "$(ls -S "$TMP"/*.map | tail -1)") max=$(wc -l < "$(ls -S "$TMP"/*.map | head -1)")"
    echo "  distinct tuples overall: $(cat "$TMP"/*.map | cut -d: -f1 | sort -u | wc -l)"
    echo "  (unique close to maps is good. If a trivial input scores nearly as many"
    echo "   tuples as a real one, you are measuring init, not the library -- unless the"
    echo "   decoders live in an uninstrumented system .so; see SKILL.md step 5.)"
  else
    echo "  FAIL: afl-showmap produced nothing. Wrong AFL_MAP_SIZE, the harness is not"
    echo "        instrumented, or a sanitizer runtime is LD_PRELOADed into this command (it"
    echo "        belongs inside REAL=). Ask the binary: AFL_DUMP_MAP_SIZE=1 $DIRECT"
  fi

  echo "== 5. the binding stubs stayed unreachable =="
  if [ "$stub" = 0 ]; then
    echo "  OK: no AFL-HARNESS-STUB / AFL-HARNESS-V8PATH marker on any seed"
  else
    echo "  FAIL: $stub seed(s) entered the binding runtime (BINDING lines above)"
  fi
  echo "  (only meaningful when a linked addon object references binding symbols; with none, record this check as N/A)"

  # every check counts, including 4: an empty corpus or a broken DIRECT gives no maps
  [ "$mism" = 0 ] && [ "$empty" = 0 ] && [ "$stub" = 0 ] && [ "${arms:-0}" -ge "$MIN_ARMS" ] && [ "$maps" -gt 0 ]
}

status=0
if [ -z "$MODES" ]; then
  one_mode || status=1
else
  for setting in default $MODES; do
    echo "######## mode: $setting"
    if [ "$setting" = default ]; then one_mode || status=1
    else
      s=${setting%%:*}; extras=${setting#"$s"}; ma=$MIN_ARMS
      for x in ${extras//:/ }; do case $x in min_arms=*) ma=${x#min_arms=};; esac; done
      ( export ${s//,/ }; MIN_ARMS=$ma one_mode ) || status=1
    fi
    echo
  done
  [ "$status" = 0 ] && echo "ALL MODES PASS: default $MODES" || echo "FAIL: at least one mode above failed"
fi
exit $status
