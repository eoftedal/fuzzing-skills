#!/bin/bash
# Generic fidelity gate.  Nothing here is target-specific; it relies on one contract:
#
#   BOTH the direct harness and the real-stack harness print ONE line of
#   key=value pairs, space separated, for each input.
#   That result line is the first one holding a status= key: other stdout (a package's own
#   logging) is ignored, and a side that prints no such line is judged NO-OUTPUT.
#
# Configure with KEY=VALUE arguments or environment variables:
#   WORKSPACE   the fuzz workspace (default .): its fuzz.env, when present, is sourced
#               first (init_workspace.sh writes it), so arguments still override it
#   DIRECT      command for the direct harness; the input path is appended
#   REAL        command for the real stack;      the input path is appended.  When it is
#               not an argument, DIRECT is sanitized and fuzz.env has REAL_ASAN, that is used
#   REAL_ASAN   the sanitized real-side command (fuzz.env); see the rule above
#   CORPUS      directory of seeds
#   FIELDS      keys that must match exactly          (default: status).  Without out_hash
#               the gate WARNs: matching status alone says nothing about the artifact
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
#   JOBS        seeds compared in parallel (default 8; ruby startup dominates, so this is
#               what makes a 1000-seed re-gate take a minute instead of five)
#   MAP_SIZE    AFL_MAP_SIZE (ask the binary: AFL_DUMP_MAP_SIZE=1 ./harness)
#   ALLOC_CAP_MB  allocation ceiling in the default ASAN_OPTIONS (default 1024, as in
#               campaign.sh): a seed declaring a huge allocation is then refused the same
#               way on both sides instead of printing nothing on one
#
# Sanitized real side: put the runtime preload INSIDE REAL=, never in front of gate.sh:
#   ./gate.sh DIRECT=./out/asan/harness-fork \
#             REAL="env LD_PRELOAD=$(resources/find_asan_rt.sh) PKG=/abs/oracle/gems/<gem>-<ver> EXT=/abs/out/asan/<name>.so ruby real_harness.rb" ...
# In front of gate.sh it is preloaded into afl-showmap and the direct harness too, and every
# seed comes out NO-OUTPUT (rc=86, empty message) / "afl-showmap produced nothing".
#
# Example:
#   ./gate.sh DIRECT=./out/plain/harness-fork REAL="env PKG=$PWD/oracle/gems/<gem>-<ver> ruby real_harness.rb" CORPUS=./corpus \
#             FIELDS="status err out_len out_hash" SOFT_FIELD=lossy SOFT_DROP="out_len out_hash" \
#             MODES="MODE=file"
#
# Seeds the gate sets aside (reported, never a FAIL):
#   known-crasher  a seed whose basename is also in $WORKSPACE/crashers/ (an ASAN-only
#                  crasher the corpus skill kept in corpus-final, a smoke finding): skipped
#                  unjudged, so a re-gate over corpus-min needs no hand-filtered copy
#   CRASHES-BOTH   the direct side exited 86 or on a signal AND so did the real side (or its
#                  stderr holds "Sanitizer:"): a finding met during the gate, not a fidelity
#                  failure.  Printed prominently; move it to crashers/ (with a row in
#                  crashers.summary.tsv) and out of the gate corpus
#
# Exit status is 0 only when every check passes in every mode, so it can gate a build script.
set -uo pipefail
for kv in "$@"; do case $kv in WORKSPACE=*) WORKSPACE=${kv#*=};; esac; done
WS=${WORKSPACE:-.}; [ -f "$WS/fuzz.env" ] && { set -a; . "$WS/fuzz.env"; set +a; }
REAL_ARG=0
for kv in "$@"; do case $kv in REAL=*) REAL_ARG=1;; esac; case $kv in *=*) export "$kv";; esac; done
DIRECT=${DIRECT:?set DIRECT}
# a sanitized DIRECT against a plain real side calls every library abort DIRECT-only
if [ "$REAL_ARG" = 0 ] && [ -n "${REAL_ASAN:-}" ] && grep -qa __asan_report_load "${DIRECT%% *}" 2>/dev/null; then
  REAL=$REAL_ASAN; echo "real side: REAL_ASAN from fuzz.env (DIRECT is sanitized): $REAL"
else src="fuzz.env or environment"; [ "$REAL_ARG" = 1 ] && src=argument
  echo "real side: REAL from $src: ${REAL:-}"; fi
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
KNOWN=""; [ -d "$WS/crashers" ] && KNOWN=$(cd "$WS/crashers" && pwd)
# A harness that keeps one-time state (a shared context created in init) trips
# LeakSanitizer at exit and prints nothing; the leak is not what the gate tests.  The
# allocation ceiling matches the campaign's, so declared-size seeds fail identically on both
# sides (ASAN's default is to abort with "allocation-size-too-big" and print no result line).
# Appended after any inherited value, never replaced by it: an inherited ASAN_OPTIONS used to
# drop these silently (later options win in ASAN's parser).
export ASAN_OPTIONS="${ASAN_OPTIONS:+$ASAN_OPTIONS:}detect_leaks=0:exitcode=86:allocator_may_return_null=1:max_allocation_size_mb=$ALLOC_CAP_MB"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export DIRECT REAL FIELDS ARM_FIELD SOFT_FIELD SOFT_DROP TMP KNOWN

first_err() { grep -m1 -E 'ERROR:|Error|error|Cannot|SUMMARY' "$1" | cut -c1-110; }
# keys come from the result line only, so stray stdout logging cannot supply one
get() { grep -m1 -E '(^| )status=' <<<"$1" | sed -n "s/.*\b$2=\([^ ]*\).*/\1/p" | head -1; }
key() { local line=$1 drop=${2:-} out=""; for f in $FIELDS; do
          case " $drop " in *" $f "*) continue ;; esac
          out="$out|$f=$(get "$line" "$f")"; done; echo "$out"; }
# One seed -> one tab-separated line: CLASS  name  arm  detail.  Runs under xargs -P.
judge() {
  local f=$1 n; n=$(basename "$1")
  local err=$TMP/$BASHPID.err rerr=$TMP/$BASHPID.rerr d r drc nrc marker
  d=$(timeout 30 $DIRECT "$f" 2>"$err"); drc=$?
  # The stubs and the RUBYPATH trap write a marker to stderr before aborting.  Catch it
  # here, per seed -- an earlier version of this gate sent stderr to /dev/null and
  # check 5 below could never fail.
  if marker=$(grep -m1 -oE 'AFL-HARNESS-(STUB|RUBYPATH):.*' "$err"); then
    printf 'BINDING\t%s\t\t%s\n' "$n" "$marker"; return; fi
  r=$(timeout 30 $REAL "$f" 2>"$rerr"); nrc=$?
  # 86 = ASAN's exitcode here; >128 a signal (124 is the timeout, 137 its KILL: not crashes)
  if { [ "$drc" = 86 ] || { [ "$drc" -gt 128 ] && [ "$drc" != 137 ]; }; } \
     && { [ "$nrc" = 86 ] || { [ "$nrc" -gt 128 ] && [ "$nrc" != 137 ]; } || grep -q 'Sanitizer:' "$rerr"; }; then
    printf 'CRASHES-BOTH\t%s\t\tdirect rc=%s, real rc=%s: %s\n' "$n" "$drc" "$nrc" "$(grep -h -m1 -oE 'Sanitizer: [^ ]+' "$err" "$rerr" | head -1)"; return; fi
  # (rc=124 means the 30 s timeout fired: a hang, named like any other no-output seed.)
  # A seed with no output is the interesting case: a sanitizer abort on one side (a real
  # finding) or a broken real-side command (a wrong EXT= path).  Say which.
  # Stdout without a status= line counts as none: judged on keys it would read as a
  # MISMATCH with every key empty.
  if ! grep -qE '(^| )status=' <<<"$d"; then printf 'NO-OUTPUT\t%s\t\tdirect printed no result line (status=...), rc=%s: %s\n' "$n" "$drc" "$(first_err "$err")"; return; fi
  if ! grep -qE '(^| )status=' <<<"$r"; then printf 'NO-OUTPUT\t%s\t\treal printed no result line (status=...), rc=%s: %s\n' "$n" "$nrc" "$(first_err "$rerr")"; return; fi
  local arm; arm=$(get "$d" "$ARM_FIELD")
  # AGREED carries its out_hash in the detail column: one hash for every seed is a vacuous gate
  if [ "$(key "$d")" = "$(key "$r")" ]; then printf 'AGREED\t%s\t%s\t%s\n' "$n" "$arm" "$(get "$d" out_hash)"
  elif [ -n "$SOFT_FIELD" ] && [ "$(get "$r" "$SOFT_FIELD")" = 1 ] \
       && [ "$(key "$d" "$SOFT_DROP")" = "$(key "$r" "$SOFT_DROP")" ]; then
    printf 'LIMITED\t%s\t%s\t\n' "$n" "$arm"
  else
    printf 'MISMATCH\t%s\t%s\tdirect=%s real=%s\n' "$n" "$arm" "$(key "$d")" "$(key "$r")"
  fi
}
export -f first_err get key judge

# a seed whose name is in crashers/ is a known crasher: listed, never judged or mapped
allseeds() { find "$CORPUS" -maxdepth 1 -type f -print0 | sort -z; }
isknown() { [ -n "$KNOWN" ] && [ -e "$KNOWN/$(basename "$1")" ]; }
seeds() { allseeds | while IFS= read -r -d '' f; do isknown "$f" || printf '%s\0' "$f"; done; }
NSEEDS=$(seeds | tr -cd '\0' | wc -c)
NKNOWN=$(allseeds | while IFS= read -r -d '' f; do isknown "$f" && echo; done | wc -l)

one_mode() {   # runs the whole gate in the current environment; prints and returns its status
  echo "== 1+2. every seed reaches the library, and agrees with the real stack =="
  seeds | xargs -0 -P "$JOBS" -I{} bash -c 'judge "$1"' _ {} | sort -t$'\t' -k2 > "$TMP/judged"
  awk -F'\t' '$1=="BINDING"  {printf "  BINDING     %-34s %s\n", $2, $4}
              $1=="NO-OUTPUT"{printf "  NO-OUTPUT   %-34s %s\n", $2, $4}
              $1=="MISMATCH" {split($4, kv, " real="); printf "  MISMATCH    %-34s\n     direct=%s\n     real  =%s\n", $2, substr(kv[1], 8), kv[2]}' "$TMP/judged"
  local ok mism limited empty stub both
  ok=$(grep -c '^AGREED' "$TMP/judged"); limited=$(grep -c '^LIMITED' "$TMP/judged")
  mism=$(grep -c '^MISMATCH' "$TMP/judged"); empty=$(grep -c '^NO-OUTPUT' "$TMP/judged")
  stub=$(grep -c '^BINDING' "$TMP/judged"); both=$(grep -c '^CRASHES-BOTH' "$TMP/judged")
  echo "  agreed=$ok  oracle-limited=$limited  mismatched=$mism  no-output=$empty  entered-binding=$stub  crashes-both=$both  known-crasher=$NKNOWN"
  [ "$NKNOWN" -gt 0 ] && echo "  ($NKNOWN seed(s) skipped as known-crasher: the same name is in $KNOWN/)"
  if [ "$both" -gt 0 ]; then
    echo "  !!!!!!!! $both seed(s) CRASH BOTH SIDES: a finding, not a fidelity failure: move it to crashers/ and out of the gate corpus"
    awk -F'\t' '$1=="CRASHES-BOTH"{printf "  !! CRASHES-BOTH %-31s %s\n", $2, $4}' "$TMP/judged"
    echo "  !! (cp <seed> crashers/ with a row in crashers.summary.tsv; a re-run then skips it as known-crasher)"
  fi
  # a harness that hashes a constant (or nothing) agrees with any real side
  local hashes; hashes=$(awk -F'\t' '$1=="AGREED"{print $4}' "$TMP/judged" | sort -u | wc -l)
  if [ "$ok" -gt 1 ] && [ "$hashes" = 1 ] && [[ " $FIELDS " == *" out_hash "* ]]; then
    echo "  WARN: all $ok agreed seeds share ONE out_hash ($(awk -F'\t' '$1=="AGREED"{print $4; exit}' "$TMP/judged")): the harness"
    echo "        hashes a constant, or nothing, so agreement on it proves nothing about the artifact"
  fi
  if [ "$empty" = $((NSEEDS - both)) ] && [ "$empty" -gt 0 ]; then
    echo "  (EVERY seed had no output on one side: the command is broken, not the seeds -- read the message above."
    if grep -qF 'direct printed no result line (status=...), rc=86' "$TMP/judged"; then
      echo "   The DIRECT side died with the sanitizer exit code and no report: is a sanitizer runtime"
      echo "   LD_PRELOADed into this whole command?  It belongs inside REAL= only.)"
    else echo "   A wrong EXT= / PKG= path, or a missing LD_PRELOAD inside REAL=, are the usual causes.)"; fi
  fi
  # A lone timeout-shaped NO-OUTPUT on a busy host is usually contention, not the seed
  # (measured: one asan gate run reported no-output=1 while other campaigns shared the
  # host; two re-runs were clean).  Say so before anyone debugs it.
  if [ "$empty" -gt 0 ] && [ "$empty" -lt 3 ] && [ "$empty" -lt $((NSEEDS - both)) ] && grep -q '^NO-OUTPUT.*rc=124' "$TMP/judged"; then
    echo "  (rc=124 is the 30 s timeout: on a loaded host re-run the gate before debugging; a NO-OUTPUT that repeats is real.)"
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
    local tmin tmax; tmin=$(wc -l < "$(ls -S "$TMP"/*.map | tail -1)"); tmax=$(wc -l < "$(ls -S "$TMP"/*.map | head -1)")
    if [ $((uniq * 2)) -lt "$maps" ] || [ $((tmin * 10)) -gt $((tmax * 8)) ]; then
      echo "  WARN: coverage barely discriminates (unique $uniq of $maps maps; min tuples $tmin vs max $tmax):"
      echo "        likely measuring init, not the library -- unless the decoders live in an"
      echo "        uninstrumented system .so; see SKILL.md step 5"
    fi
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
    echo "  OK: no AFL-HARNESS-STUB / AFL-HARNESS-RUBYPATH marker on any seed"
  else
    echo "  FAIL: $stub seed(s) entered the binding runtime (BINDING lines above)"
  fi
  echo "  (only meaningful when a linked extension object references Ruby C API symbols; with none, record this check as N/A)"

  # every check counts, including 4: an empty corpus or a broken DIRECT gives no maps
  [ "$mism" = 0 ] && [ "$empty" = 0 ] && [ "$stub" = 0 ] && [ "${arms:-0}" -ge "$MIN_ARMS" ] && [ "$maps" -gt 0 ]
}

[[ " $FIELDS " == *" out_hash "* ]] || echo "WARN: FIELDS=\"$FIELDS\" lacks out_hash: comparing status only proves nothing about the artifact"
# A mode variable left in the environment (MODE=file exported in an earlier block) would
# turn the "default" run into that mode, silently gating it twice.
for setting in $MODES; do s=${setting%%:*}; for kv in ${s//,/ }; do v=${kv%%=*}
  if [ -n "${!v+x}" ]; then echo "WARN: $v=${!v} is set in the environment: unset for the default mode, which otherwise runs under it"; unset "$v"; fi
done; done
status=0
if [ -z "$MODES" ]; then
  one_mode || status=1
  # Always end with a verdict line: piped through `| tee` (as the docs do) the exit code
  # is lost, and the per-check lines alone do not say whether the gate passed.
  [ "$status" = 0 ] && echo "PASS: the gate passed (default mode only)" || echo "FAIL: the gate failed (see the checks above)"
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
