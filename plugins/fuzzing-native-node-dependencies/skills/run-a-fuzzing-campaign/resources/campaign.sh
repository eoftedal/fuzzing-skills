#!/bin/bash
# Run the AFL++ campaigns for a harnessed native Node addon, and record how each ran.
# Sits between the corpus skill and the triage skill.  It steers afl-fuzz (which binary,
# which harness mode, which memory ceiling, a separate output dir each, when to switch
# driver, when to stop) and writes a manifest.  Triage reads the manifest instead of
# inferring the variant, mode, ceiling and stability.
#
#   resources/campaign.sh [WORKSPACE=.] [MODES="MODE=2:mime"] [DURATION=600] ...
#
# Reads (upstream-skill conventions; override any):
#   out/<variant>/{harness,harness-fork}             build-a-nan-napi-fuzzing-harness
#   selftest*.txt with a "PASS:" line                that skill's detect_selftest.sh output
#   corpus-final/ else corpus/ else corpus-min/      derive-a-fuzzing-corpus-from-source
# Writes:
#   campaigns/<variant>[@<mode>][.fork]/   one afl-fuzz -o per campaign, never shared
#   campaigns/manifest.tsv                 one row per campaign (re-running replaces its row)
#   campaigns/<name>.log                   afl-fuzz output
#
# KEY=VALUE arguments or environment:
#   WORKSPACE  the fuzz workspace (default .)
#   CAMPAIGNS  where campaigns/ goes (default $WORKSPACE/campaigns)
#   CORPUS     seed directory (default: corpus-final, else corpus, else corpus-min).  The
#              corpus skill says to ship the UNION: the greedy cover (corpus-min) is "a stop
#              signal, not a reason to ship only the cover", so it is the last resort here.
#   VARIANTS   builds to fuzz (default: every out/<v>/ whose harness is AFL-instrumented;
#              a pristine build has none and is skipped)
#   MODES      harness settings to fuzz BESIDES the default, each VAR=value[:entry],
#              space-separated (MODE=2:mime); several settings in one mode are joined with
#              commas (MODE=2,ENC=utf16).  The variable is whatever your harness
#              getenv()s: the template reads MODE; one past harness read a differently named one.
#              `entry` is the confirm.mjs ENTRIES arm that reaches the same code through the
#              npm API; recorded so triage knows a mode-found crash confirms only through
#              that entry point.  DEFAULT: the mode's VALUE (MODE=file -> entry `file`),
#              which is the chain's convention: the harness skill's real_harness.mjs keys
#              its consumer calls by MODE value, and confirm.mjs's ENTRIES is that same
#              object.  Give `:entry` only when an arm is named differently.
#   DEFAULT_ENTRY  the confirm.mjs arm for the default mode (default "default")
#   DURATION   seconds of FUZZ time per campaign (afl-fuzz -V; default 600).  NOT wall-clock:
#              afl-fuzz leaves trimming and calibration out of it.  Measured on an image-
#              decoding binding: a plain campaign with `-V 40` ran 268 s once it had saved a hang.
#   WALL       wall-clock ceiling per campaign in seconds (default 0 = none).  At the ceiling
#              the campaign is stopped and recorded as `walled`: its crashes are real, but
#              it did not get its full fuzz time, so it is never a "found nothing" result.
#   STAB_CHECK seconds before the stability check (default 60); MIN_STABILITY % (default 90).
#              A persistent campaign below it is STOPPED and relaunched on the fork driver;
#              both rows stay in the manifest.  A variant with only harness-fork (no
#              persistent harness) runs on the fork driver from the start (driver=fork).
#   ALLOC_CAP_MB  memory ceiling (default 1024): ASAN max_allocation_size_mb for a sanitized
#              build, afl-fuzz -m for a plain one.  The number triage screens at first.
#   TIMEOUT_MS afl-fuzz -t (default: afl-fuzz auto-calibrates; the chosen value is recorded)
#   SELFTEST   the self-test output (default: selftest*.txt); SELFTEST=skip records that the
#              run cannot tell "found nothing" from "detects nothing"
#   POLL       seconds between status lines (default 15)
#   JOBS       campaigns at once (default: cores-1)
#   SCREEN=1   run each afl-fuzz inside a detached GNU screen session named afl-<campaign>,
#              with its UI on, so you can watch it live: `screen -ls`, `screen -r afl-<name>`
#              (detach again with C-a d; never C-c, that kills the campaign).  Everything
#              else is unchanged: this script still owns the pid, the stop/relaunch logic
#              and the manifest; the session closes when afl-fuzz exits and its terminal
#              output is in campaigns/<name>.log.  Needs `screen` 4.6+ (-Logfile).
#
# Manifest columns (triage reads the first 11 by position, the rest by name):
#   name variant driver harness mode_env entry out_dir mem_limit exec_timeout_ms map_size
#   alloc_cap_mb start stop stop_reason execs stability saved_crashes saved_hangs crash_files
#   hang_files selftest status asan_options seeds_total seeds_loaded
# `status` is what ACTUALLY happened: completed | switched | interrupted | walled | aborted | failed |
# early.  Only `completed` ran its full duration; a campaign that did not is never a result.
set -uo pipefail
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
WS=${WORKSPACE:-.}; WS=$(cd "$WS" && pwd); cd "$WS" || exit 1
CAMP=${CAMPAIGNS:-$WS/campaigns}
DURATION=${DURATION:-600}
STAB_CHECK=${STAB_CHECK:-60}; MIN_STABILITY=${MIN_STABILITY:-90}
ALLOC_CAP_MB=${ALLOC_CAP_MB:-1024}; POLL=${POLL:-15}
JOBS=${JOBS:-$(( $(nproc) - 1 ))}; [ "$JOBS" -ge 1 ] || JOBS=1
DEFAULT_ENTRY=${DEFAULT_ENTRY:-default}; WALL=${WALL:-0}
SCREEN=${SCREEN:-0}
if [ "$SCREEN" = 1 ]; then
  command -v screen >/dev/null || { echo "FAIL: SCREEN=1 but screen is not installed (apt-get install screen)" >&2; exit 1; }
  screen -h 2>&1 | grep -q -- '-Logfile' || { echo "FAIL: this screen has no -Logfile (need 4.6+)" >&2; exit 1; }
fi
T0=$(date +%s)
ts() { printf '[%s +%ds] %s\n' "$(date +%H:%M:%S)" "$(( $(date +%s) - T0 ))" "$*"; }
die() { echo "FAIL: $*" >&2; exit 1; }

instrumented() { grep -qa '__afl_area_ptr\|__afl_coverage' "$1" 2>/dev/null; }
# Sanitized by looking IN the binary, as the triage skill does -- not by guessing from the
# variant's name.
is_asan() { grep -qa '__asan_report_load' "$1" 2>/dev/null; }
hbin()  { for p in "$WS/out/$1/harness" "$WS/out/$1/bin/harness"; do [ -x "$p" ] && { echo "$p"; return; }; done; }
hfork() { for p in "$WS/out/$1/harness-fork" "$WS/out/$1/bin/harness-fork"; do [ -x "$p" ] && { echo "$p"; return; }; done; }
mapsz() { AFL_DUMP_MAP_SIZE=1 "$1" 2>/dev/null | tail -1; }   # per binary: persistent and fork differ

# ---- inputs from the upstream skills -----------------------------------------------------
if [ -z "${CORPUS:-}" ]; then
  for c in corpus-final corpus corpus-min; do [ -d "$WS/$c" ] && { CORPUS=$WS/$c; break; }; done
fi
[ -d "${CORPUS:-}" ] || die "no corpus: pass CORPUS= (the corpus skill writes corpus-final/)"
if [ -z "${VARIANTS:-}" ]; then
  VARIANTS=$(for d in "$WS"/out/*/; do v=$(basename "$d"); f=$(hfork "$v")
             [ -n "$f" ] && instrumented "$f" && echo "$v"; done | sort -u | xargs)
fi
[ -n "$VARIANTS" ] || die "no instrumented out/<variant>/harness-fork (the harness skill builds them)"

if [ -z "${SELFTEST:-}" ]; then SELFTEST=$(ls "$WS"/selftest*.txt 2>/dev/null | head -1); fi
if [ "${SELFTEST:-}" = skip ]; then SELFTEST_STATE=skipped
elif [ -n "${SELFTEST:-}" ] && grep -q '^PASS:' "$SELFTEST" 2>/dev/null; then
  SELFTEST_STATE=passed
  # The self-test proves the harness AS IT WAS when it ran.  A harness rebuilt afterwards
  # is a different binary, so say so rather than letting a stale PASS stand.
  for v in $VARIANTS; do for b in "$(hbin "$v")" "$(hfork "$v")"; do
    [ -n "$b" ] && [ "$b" -nt "$SELFTEST" ] && { SELFTEST_STATE=stale
      echo "  WARN: $b is newer than $SELFTEST; the self-test no longer vouches for it. Re-run it." >&2; }
  done; done
else die "no passing detection self-test. Save the harness skill's detect_selftest.sh output
      as selftest.txt (keep its PASS: line), or pass SELFTEST=skip -- the manifest then
      records that 'no crashes' cannot be told apart from 'detects nothing'."
fi

mkdir -p "$CAMP"
MAN="$CAMP/manifest.tsv"
COLS="name variant driver harness mode_env entry out_dir mem_limit exec_timeout_ms map_size alloc_cap_mb start stop stop_reason execs stability saved_crashes saved_hangs crash_files hang_files selftest status asan_options seeds_total seeds_loaded"
[ -f "$MAN" ] || printf '%s\n' "$COLS" | tr ' ' '\t' > "$MAN"

ts "workspace $WS"
ts "corpus $CORPUS ($(ls "$CORPUS" | wc -l) seeds); variants: $VARIANTS; self-test: $SELFTEST_STATE"
ts "modes besides default: ${MODES:-none}; ${DURATION}s each, up to $JOBS at once, ceiling ${ALLOC_CAP_MB} MB"

# ---- the plan: (variant x mode) ----------------------------------------------------------
PLAN=()
for v in $VARIANTS; do
  PLAN+=("$v||$DEFAULT_ENTRY")
  for spec in ${MODES:-}; do
    me=${spec%%:*}; en=""
    # extras after ':' -- an entry name, or KEY=VALUE options for other scripts (gate.sh's
    # min_arms=1), which are not entry names and are ignored here
    for x in $(tr ':' ' ' <<<"${spec#"$me"}"); do case $x in *=*) ;; *) en=$x;; esac; done
    if [ -z "$en" ]; then en=${me%%,*}; en=${en#*=}; fi            # default: the first setting's value
    PLAN+=("$v|$me|$en")
  done
done

# ---- campaign state, in the main shell: afl-fuzz is a DIRECT child, so its pid is real ---
# (An earlier version ran it inside `( ... ) &` and kept the subshell's pid: `kill` then hit
# the wrapper and left afl-fuzz running -- the stability fallback never stopped the unstable
# campaign, and an interrupted run orphaned every afl-fuzz.)
declare -A PID VAR DRV ME EN BIN OUTD MEM MS START ASANO TLOG
LIVE=()
tag_of() { local t=$1; [ -n "$2" ] && t="$1@$(tr -c 'A-Za-z0-9=' _ <<<"$2" | sed 's/_*$//')"; [ "$3" = fork ] && t="$t.fork"; echo "$t"; }
stat_of() { sed -n "s/^$2 *: *//p" "$1/default/fuzzer_stats" 2>/dev/null | head -1 | tr -d ' %'; }
nfiles() { local n; n=$(ls "$1" 2>/dev/null | grep -c '^id:'); echo "${n:-0}"; }

launch() {  # <variant> <mode_env> <entry> <persistent|fork>
  local v=$1 me=$2 en=$3 driver=$4 bin tag o log ms asan="" mem=$ALLOC_CAP_MB
  if [ "$driver" = fork ]; then bin=$(hfork "$v"); else bin=$(hbin "$v"); fi
  # A build with only a fork harness (no persistent one) is still fuzzed: on the fork
  # driver, recorded as such.  It used to be skipped, so the variant was never fuzzed.
  if [ -z "$bin" ] && [ "$driver" = persistent ] && [ -n "$(hfork "$v")" ]; then
    ts "  $v: no persistent harness; falling back to harness-fork (driver=fork)"
    driver=fork; bin=$(hfork "$v")
  fi
  [ -n "$bin" ] || { ts "  skip $v/$driver: no such harness"; return 1; }
  tag=$(tag_of "$v" "$me" "$driver"); o="$CAMP/$tag"; log="$CAMP/$tag.log"
  # Map size of the binary THIS campaign runs (after any fallback), dumped the way the
  # harness skill's link step does: the persistent and fork binaries differ.
  ms=$(mapsz "$bin"); ms=${ms:-131072}
  rm -rf "$o"; mkdir -p "$o"
  # Sanitized: the ceiling is ASAN's max_allocation_size_mb and afl-fuzz -m must be none (the
  # shadow reservation needs the address space).  abort_on_error=1:symbolize=0 are mandatory:
  # AFL++ 4.x refuses to start without them.  Plain: -m is the ceiling.
  if is_asan "$bin"; then
    asan="abort_on_error=1:symbolize=0:detect_leaks=0:allocator_may_return_null=1:max_allocation_size_mb=$ALLOC_CAP_MB"
    mem=none
  fi
  local args=(-i "$CORPUS" -o "$o" -m "$mem" -V "$DURATION")
  [ -n "${TIMEOUT_MS:-}" ] && args+=(-t "$TIMEOUT_MS")
  local tgt=("$bin"); [ "$driver" = fork ] && tgt=("$bin" @@)   # the fork binary reads argv[1]
  # AFL_IGNORE_SEED_PROBLEMS skips seeds that crash or HANG in the dry run (the corpus skill
  # leaves ASAN-only crashers in on purpose; this also catches a hanging or plain-crashing
  # seed that slipped through); AFL_SKIP_CRASHES covers crashes only and a looping seed
  # aborts the whole campaign at startup.
  local cmd=(env)
  [ -n "$me" ] && cmd+=(${me//,/ })               # unquoted on purpose: several VAR=value words
  [ -n "$asan" ] && cmd+=(ASAN_OPTIONS="$asan")
  cmd+=(AFL_MAP_SIZE="$ms" AFL_IGNORE_SEED_PROBLEMS=1 AFL_SKIP_CPUFREQ=1)
  [ "$SCREEN" = 1 ] || cmd+=(AFL_NO_UI=1)         # the UI is the point of SCREEN=1
  cmd+=(afl-fuzz "${args[@]}" -- "${tgt[@]}")
  local pid
  if [ "$SCREEN" = 1 ]; then
    # Inside a detached screen (a pty, so afl-fuzz shows its UI).  The window runs a tiny
    # wrapper that starts afl-fuzz in the background, writes ITS pid (env exec()s afl-fuzz,
    # so $! is afl-fuzz) and, when it exits, its exit status -- this script cannot `wait` on
    # a process that is not its child, so .pid and .rc replace $! and wait.  screen -L logs
    # the terminal to the campaign log; the UI's escape codes are in there, the startup
    # messages finish() greps for too.
    local q sess; q=$(printf '%q ' "${cmd[@]}"); sess="afl-$tag"
    rm -f "$o/.pid" "$o/.rc"; : > "$log"
    screen -dmS "$sess" -L -Logfile "$log" bash -c \
      "$q & echo \$! > $(printf %q "$o/.pid"); wait \$!; echo \$? > $(printf %q "$o/.rc")"
    local i; for i in $(seq 50); do [ -s "$o/.pid" ] && break; sleep 0.1; done
    pid=$(cat "$o/.pid" 2>/dev/null)
    [ -n "$pid" ] || { ts "  FAIL $tag: screen session $sess did not start afl-fuzz (is screen working? try: screen -ls)"; return 1; }
  else
    "${cmd[@]}" >"$log" 2>&1 &                    # env exec()s afl-fuzz: $! IS afl-fuzz
    pid=$!
  fi
  PID[$tag]=$pid VAR[$tag]=$v DRV[$tag]=$driver ME[$tag]=$me EN[$tag]=$en BIN[$tag]=$bin
  OUTD[$tag]=$o MEM[$tag]=$mem MS[$tag]=$ms START[$tag]=$(date +%s) ASANO[$tag]=$asan TLOG[$tag]=$log
  LIVE+=("$tag")
  ts "  launched $tag ($driver, pid ${PID[$tag]}, -m $mem${asan:+, asan ceiling ${ALLOC_CAP_MB} MB})"
  [ "$SCREEN" = 1 ] && ts "    watch it: screen -r afl-$tag   (detach with C-a d, not C-c)"
}
# Exit status of a finished campaign: `wait` for our own child, the wrapper's .rc under SCREEN=1
# (give the wrapper a moment to write it after afl-fuzz is gone).
rc_of() {  # <tag> <pid>
  if [ "$SCREEN" = 1 ]; then
    local i; for i in $(seq 30); do [ -s "${OUTD[$1]}/.rc" ] && break; sleep 0.1; done
    cat "${OUTD[$1]}/.rc" 2>/dev/null || echo 1
  else wait "$2" 2>/dev/null; echo $?; fi
}

# Stop one campaign for real: TERM so afl-fuzz writes its final stats, KILL if it ignores us.
stop_one() {  # <pid>
  local pid=$1 i
  kill -TERM "$pid" 2>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}

# Write one manifest row, replacing any earlier row of the same name (re-running a campaign
# must not leave two rows for one directory: triage would process it twice under one tag).
# status/reason are what HAPPENED -- decided from afl-fuzz's exit status, its log, its stats
# and the elapsed time -- never assumed.  An earlier version wrote "completed" for every
# exit, including an afl-fuzz that aborted at startup with 0 crashes and no stats, which a
# passing self-test would then have turned into "found nothing".
finish() {  # <tag> <natural|switched|interrupted> <afl exit status>
  local tag=$1 kind=$2 rc=$3 o=${OUTD[$1]} log=${TLOG[$1]}
  local elapsed=$(( $(date +%s) - START[$tag] )) status reason cf hf sc sh stab
  cf=$(nfiles "$o/default/crashes"); hf=$(nfiles "$o/default/hangs")
  sc=$(stat_of "$o" saved_crashes); sh=$(stat_of "$o" saved_hangs); stab=$(stat_of "$o" stability)
  case $kind in
    switched)    status=switched;    reason="stability-${stab:-?}%-below-${MIN_STABILITY}%-relaunched-on-fork";;
    interrupted) status=interrupted; reason="script-interrupted-after-${elapsed}s";;
    walled)      status=walled;      reason="stopped-at-${WALL}s-wall-clock-fuzz-time-${DURATION}s-not-reached";;
    *) if grep -q 'PROGRAM ABORT' "$log" 2>/dev/null; then
         status=aborted
         reason="afl-fuzz-aborted: $(sed 's/\x1b\[[0-9;]*m//g' "$log" | sed -n 's/.*PROGRAM ABORT *: *//p' | head -1 | cut -c1-110)"
       elif [ "$rc" -ne 0 ]; then status=failed; reason="afl-fuzz-exit-$rc"
       elif [ ! -f "$o/default/fuzzer_stats" ]; then status=failed; reason="no-fuzzer_stats"
       elif [ $(( elapsed + 5 )) -lt "$DURATION" ]; then status=early; reason="exited-after-${elapsed}s-of-${DURATION}s"
       else status=completed; reason="completed-${DURATION}s"; fi;;
  esac
  # The files on disk are the truth; fuzzer_stats is only a diagnostic (it is written
  # periodically, so it lags a campaign that was stopped).  A mismatch after a NORMAL finish
  # means two fuzzers shared this -o.
  [ "$status" = completed ] && [ -n "$sc" ] && [ "$sc" != "$cf" ] \
    && ts "  WARN $tag: fuzzer_stats saved_crashes=$sc but $cf id:* files on disk (two fuzzers sharing one -o?)"
  [ "$status" != completed ] && [ "$status" != switched ] && ts "  $tag: $status -- $reason"
  local seeds_total seeds_loaded
  seeds_total=$(ls "$CORPUS" | wc -l)
  seeds_loaded=$(sed 's/\x1b\[[0-9;]*m//g' "$log" 2>/dev/null | sed -n 's/.*Loaded a total of \([0-9]*\) seeds.*/\1/p' | head -1)
  local row tmp; tmp=$(mktemp)
  row=$(printf '%s\t' "$tag" "${VAR[$tag]}" "${DRV[$tag]}" "${BIN[$tag]}" "${ME[$tag]:-default}" "${EN[$tag]}" \
        "${o#$WS/}" "${MEM[$tag]}" "$(stat_of "$o" exec_timeout)" "${MS[$tag]}" "$ALLOC_CAP_MB" "${START[$tag]}" \
        "$(date +%s)" "$reason" "$(stat_of "$o" execs_done)" "${stab:-}" "${sc:-0}" "${sh:-0}" "$cf" "$hf" \
        "$SELFTEST_STATE" "$status" "${ASANO[$tag]}" "$seeds_total" "${seeds_loaded:-}")
  awk -F'\t' -v n="$tag" 'NR==1||$1!=n' "$MAN" > "$tmp"; printf '%s\n' "${row%$'\t'}" >> "$tmp"; mv "$tmp" "$MAN"
  local i; for i in "${!LIVE[@]}"; do [ "${LIVE[$i]}" = "$tag" ] && unset 'LIVE[i]'; done; LIVE=("${LIVE[@]}")
}

# ---- summary and hand-off ----------------------------------------------------------------
summarize() {
  ts "== $(($(grep -c . "$MAN") - 1)) campaign row(s) in $MAN =="
  awk -F'\t' 'NR>1{printf "  %-26s %-10s %-11s stab %-6s crashes %-4s hangs %-4s seeds %s/%s\n",$1,$3,$22,$16,$19,$20,$25,$24}' "$MAN"
  local fc fh bad
  fc=$(awk -F'\t' 'NR>1{c+=$19} END{print c+0}' "$MAN"); fh=$(awk -F'\t' 'NR>1{h+=$20} END{print h+0}' "$MAN")
  bad=$(awk -F'\t' 'NR>1 && $22!="completed" && $22!="switched"{n++} END{print n+0}' "$MAN")
  echo
  if [ "$fc" = 0 ] && [ "$fh" = 0 ]; then
    if [ "$bad" != 0 ]; then
      ts "no crashes or hangs, BUT $bad campaign(s) did not run to completion: this is NOT a result."
      echo "  Read the status column; an aborted or failed campaign finds nothing for a reason that has"
      echo "  nothing to do with the target."
    elif [ "$SELFTEST_STATE" = passed ]; then
      ts "no crashes or hangs."
      echo "  The detection self-test passed and every campaign ran its full ${DURATION}s, so this is a"
      echo "  result: a harness proven able to detect an injected fault found nothing."
    else
      ts "no crashes or hangs; self-test is '$SELFTEST_STATE', so this cannot be told from 'detects nothing'."
    fi
  else
    ts "$fc crash file(s), $fh hang file(s); triage next: run the triage skill from $WS."
    echo "  triage_all.sh reads $MAN for the variant, harness, mode->entry map, ceiling and"
    echo "  status of each campaign, so pass nothing it can read there."
    [ "$bad" != 0 ] && echo "  NOTE: $bad campaign(s) did not run to completion; their crashes are real, the absence of more is not."
  fi
}

# Ctrl-C or SIGTERM: stop every campaign and record it, so no afl-fuzz is orphaned and no
# crash directory is left without a manifest row.
on_interrupt() {
  trap '' INT TERM
  ts "interrupted: stopping ${#LIVE[@]} campaign(s) and recording them"
  local t; for t in "${LIVE[@]:-}"; do [ -n "$t" ] || continue; stop_one "${PID[$t]}"; finish "$t" interrupted 143; done
  summarize; exit 130
}
trap on_interrupt INT TERM
trap 'for t in "${LIVE[@]:-}"; do [ -n "$t" ] && kill -KILL "${PID[$t]}" 2>/dev/null; done' EXIT

# ---- run the plan, JOBS at a time, persistent-first with a stability fallback ------------
ts "== running ${#PLAN[@]} campaign(s) =="
ri=0
while [ "$ri" -lt "${#PLAN[@]}" ] || [ "${#LIVE[@]}" -gt 0 ]; do
  while [ "$ri" -lt "${#PLAN[@]}" ] && [ "${#LIVE[@]}" -lt "$JOBS" ]; do
    IFS='|' read -r v me en <<<"${PLAN[$ri]}"; ri=$((ri+1))
    launch "$v" "$me" "$en" persistent
  done
  for ((i=0; i<POLL; i++)); do                       # wake as soon as any campaign ends
    sleep 1; dead=0
    for t in "${LIVE[@]:-}"; do [ -n "$t" ] && ! kill -0 "${PID[$t]}" 2>/dev/null && dead=1; done
    [ "$dead" = 1 ] && break
  done
  for t in "${LIVE[@]:-}"; do
    [ -n "$t" ] || continue
    pid=${PID[$t]}; o=${OUTD[$t]}; stab=$(stat_of "$o" stability)
    if kill -0 "$pid" 2>/dev/null; then
      if [ "$WALL" -gt 0 ] && [ $(( $(date +%s) - START[$t] )) -ge "$WALL" ]; then
        ts "  $t: ${WALL}s wall-clock ceiling reached (stability ${stab:-?}%, $(stat_of "$o" execs_done) execs): stopping it"
        stop_one "$pid"; finish "$t" walled 0; continue
      fi
      ts "  $t: $(stat_of "$o" execs_done) execs, stability ${stab:-?}%, crashes $(nfiles "$o/default/crashes"), hangs $(nfiles "$o/default/hangs")"
      if [ "${DRV[$t]}" = persistent ] && [ -n "$stab" ] \
         && [ $(( $(date +%s) - START[$t] )) -ge "$STAB_CHECK" ] \
         && awk -v s="${stab%%.*}" -v m="$MIN_STABILITY" 'BEGIN{exit !(s+0 < m)}'; then
        ts "  $t: stability ${stab}% < ${MIN_STABILITY}%: stopping it and relaunching on the fork driver"
        stop_one "$pid"; v=${VAR[$t]}; me=${ME[$t]}; en=${EN[$t]}
        finish "$t" switched 0
        launch "$v" "$me" "$en" fork
      fi
    else
      rc=$(rc_of "$t" "$pid")
      finish "$t" natural "$rc"
    fi
  done
done
trap - INT TERM EXIT
summarize
