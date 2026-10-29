#!/bin/bash
# Run the AFL++ campaigns for a harnessed Ruby C extension, and record how each ran.
# Sits between the corpus skill and the triage skill.  It steers afl-fuzz (which binary,
# which harness mode, which memory ceiling, a separate output dir each, when to switch
# driver, when to stop) and writes a manifest.  Triage reads the manifest instead of
# inferring the variant, mode, ceiling and stability.
#
#   resources/campaign.sh [WORKSPACE=.] [MODES="MODE=2:mime"] [DURATION=600] ...
#
# Reads (upstream-skill conventions; override any):
#   out/<variant>/{harness,harness-fork}             build-a-ruby-c-extension-fuzzing-harness
#   selftest*.txt with a "PASS:" line                that skill's detect_selftest.sh output
#   corpus-final/ else corpus/ else corpus-min/      derive-a-fuzzing-corpus-from-source
#   dict.afl, else out/<variant>/dict.afl           dict.sh / the harness build (afl-fuzz -x)
# Writes:
#   campaigns/<variant>[@<mode>][.fork]/   one afl-fuzz -o per campaign, never shared with
#                                          another campaign.  Inside: default/ (one instance),
#                                          or main/ + s1/ .. s<n>/ with SECONDARIES=<n>
#   campaigns/manifest.tsv                 one row per campaign (re-running replaces its row)
#   campaigns/<name>.log                   afl-fuzz output (the main instance's)
#   campaigns/<name>.s<i>.log              a secondary instance's output (SECONDARIES=<n>)
#   campaigns/<name>.dropped               `<seed>\t<reason>` per seed afl-fuzz did not fuzz:
#                                          zero-length or README.txt (skipped silently, found
#                                          by diffing the corpus against the queue's orig:
#                                          names), or crashed / timed out in the dry run
#                                          (named in a WARNING line under AFL_IGNORE_SEED_PROBLEMS)
#
# KEY=VALUE arguments, then $WORKSPACE/fuzz.env (MODES, ALLOC_CAP_MB, ...), then environment:
#   WORKSPACE  the fuzz workspace (default .)
#   DETACH=1   start in the background (setsid + nohup), log to campaigns/campaign.log, print
#              the pid and return at once.  The Bash tool a model drives this from stops at
#              ten minutes and kills the process group, which would orphan every afl-fuzz and
#              leave the manifest without rows; DETACH avoids that.  `kill <pid>` stops it
#              cleanly (every campaign is stopped and recorded).  The run is finished when
#              campaign.log has a line starting `DONE:` (printed last, also after a kill):
#                until grep -q '^DONE:' campaigns/campaign.log; do sleep 10; done
#              One run's wait loop grepped for a word the log never prints and idled 6 min.
#   CAMPAIGNS  where campaigns/ goes (default $WORKSPACE/campaigns)
#   CORPUS     seed directory (default: corpus-final, else corpus, else corpus-min).  The
#              corpus skill says to ship the UNION: the greedy cover (corpus-min) is "a stop
#              signal, not a reason to ship only the cover", so it is the last resort here.
#   VARIANTS   builds to fuzz (default: every out/<v>/ whose harness is AFL-instrumented;
#              a pristine build has none and is skipped)
#   MODES      harness settings to fuzz BESIDES the default, each VAR=value[:entry],
#              space-separated (MODE=2:mime); several settings in one mode are joined with
#              commas (MODE=2,ENC=utf16).  The variable is whatever your harness
#              getenv()s: the template reads MODE; one past (Node) harness read a differently named one.
#              `entry` is the confirm.rb ENTRIES arm that reaches the same code through the
#              gem's Ruby API; recorded so triage knows a mode-found crash confirms only through
#              that entry point.  DEFAULT: the mode's VALUE (MODE=file -> entry `file`),
#              which is the chain's convention: the harness skill's real_harness.rb keys
#              its consumer calls by MODE value, and confirm.rb's ENTRIES is that same
#              hash.  Give `:entry` only when an arm is named differently.
#   DEFAULT_ENTRY  the confirm.rb arm for the default mode (default "default")
#   DURATION   seconds of FUZZ time per campaign (afl-fuzz -V; default 600).  NOT wall-clock:
#              afl-fuzz leaves trimming and calibration out of it.  Measured on an image-
#              decoding Node binding: a plain campaign with `-V 40` ran 268 s once it had saved a hang.
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
#   JOBS       campaigns at once (default: (cores-1) / instances per campaign, at least 1).
#              Each campaign runs 1 + SECONDARIES afl-fuzz instances, one core each, so the
#              default counts INSTANCES against cores-1.  When the plan leaves more than half
#              the cores idle (few variant x mode campaigns), the run prints
#              `SECONDARIES=<k> would use them`.
#   SECONDARIES  extra afl-fuzz instances per campaign (default 0).  0: one instance, output
#              in <out>/default/, exactly as before.  n > 0: `-M main` plus n `-S s<i>`
#              sharing the campaign's -o (AFL++ parallel mode: they sync queues).  For variety
#              (AFL++ docs, "fuzzing in depth", multi-core): s<i> alternates `-p explore` (odd i)
#              and `-p fast` (even i); with n >= 3 the last one runs MOpt (`-L 0`) instead.
#              Every instance gets the same -x, -m, -t, -V and environment.  No -d/-D: 4.33c
#              ignores both (deterministic stages are off by default).  Every instance is a
#              direct child: the stability fallback, WALL, the end of the main instance and
#              `kill -TERM` stop them all.  fuzzer_stats in the manifest (execs, stability,
#              saved_*, exec_timeout) are the MAIN instance's; crash_files/hang_files count
#              every instance's crashes/ and hangs/ (triage reads them all and dedups by content).
#   DICT       afl-fuzz -x: a dictionary file or a directory of them, relative to the
#              workspace.  Default: $WORKSPACE/dict.afl (dict.sh's merge) when it exists,
#              else the campaign variant's out/<v>/dict.afl (the build's compare constants)
#              when it exists, else none.  DICT=none disables.
#              smoke.sh drives this script, so a smoke run picks the same default: intended,
#              the smoke run then also proves afl-fuzz accepts the dictionary.
#   SCREEN=1   run each afl-fuzz inside a detached GNU screen session named afl-<campaign>
#              (afl-<campaign>-main / afl-<campaign>-s<i> with SECONDARIES),
#              with its UI on, so you can watch it live: `screen -ls`, `screen -r afl-<name>`
#              (detach again with C-a d; never C-c, that kills the campaign).  Everything
#              else is unchanged: this script still owns the pid, the stop/relaunch logic
#              and the manifest; the session closes when afl-fuzz exits and its terminal
#              output is in campaigns/<name>.log.  Needs `screen` 4.6+ (-Logfile).
#
# A core_pattern that pipes to a helper makes afl-fuzz abort at startup; then this sets
# AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 (detection is unaffected, only the core dump is
# lost).  A MODES variable already set in the environment (MODE=2 exported by hand) is unset
# for every campaign that does not set it, or the default campaign would run as that mode.
#
# Manifest columns (triage reads the first 11 by position, the rest by name):
#   name variant driver harness mode_env entry out_dir mem_limit exec_timeout_ms map_size
#   alloc_cap_mb start stop stop_reason execs stability saved_crashes saved_hangs crash_files
#   hang_files selftest status asan_options seeds_total seeds_loaded dict instances
# `dict` is the -x path RELATIVE TO THE WORKSPACE (`dict.afl` is $WORKSPACE/dict.afl,
# `out/asan/dict.afl` the build's), or `-` for none (empty on rows written before the column
# existed).  When $WORKSPACE/dict.afl is chosen while out/<variant>/dict.afl also exists, the
# launch line says so with both entry counts: dict.sh run without FROM= writes a workspace
# file that lacks the build's compare constants, and this default would then drop them.
# `instances` is how many afl-fuzz ran in the campaign (1 + SECONDARIES; empty on rows written
# before the column existed, which ran one).
# `status` is what ACTUALLY happened: completed | switched | interrupted | walled | aborted | failed |
# early.  Only `completed` ran its full duration; a campaign that did not is never a result.
set -uo pipefail
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")      # before the cd below: DETACH re-runs it
for kv in "$@"; do case $kv in WORKSPACE=*) export "$kv";; esac; done   # find fuzz.env first
WS=${WORKSPACE:-.}; [ -f "$WS/fuzz.env" ] && { set -a; . "$WS/fuzz.env"; set +a; }
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
WS=${WORKSPACE:-.}; WS=$(cd "$WS" && pwd); cd "$WS" || exit 1
CAMP=${CAMPAIGNS:-$WS/campaigns}
DURATION=${DURATION:-600}
STAB_CHECK=${STAB_CHECK:-60}; MIN_STABILITY=${MIN_STABILITY:-90}
ALLOC_CAP_MB=${ALLOC_CAP_MB:-1024}; POLL=${POLL:-15}
SECONDARIES=${SECONDARIES:-0}
case $SECONDARIES in ''|*[!0-9]*) echo "FAIL: SECONDARIES=$SECONDARIES is not a number" >&2; exit 1;; esac
INST=$(( SECONDARIES + 1 )); NCORES=$(nproc)
JOBS=${JOBS:-$(( (NCORES - 1) / INST ))}; [ "$JOBS" -ge 1 ] || JOBS=1
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
DICT=${DICT:-}
case $DICT in ""|none) ;; *) [ -e "$DICT" ] || die "DICT=$DICT: no such file or directory (DICT=none to fuzz without one)"
                            DICT=$(cd "$(dirname "$DICT")" && pwd)/$(basename "$DICT") ;; esac
# The dictionary one variant's campaigns get: DICT=, else the workspace's, else the build's.
dict_of() {  # <variant> -> absolute path, or nothing
  case $DICT in none) return ;; "") ;; *) echo "$DICT"; return ;; esac
  local p; for p in "$WS/dict.afl" "$WS/out/$1/dict.afl"; do [ -s "$p" ] && { echo "$p"; return; }; done
}

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

# DETACH=1: the inputs are checked above, in the foreground, so a setup error still shows here.
# setsid gives the run its own process group (a group kill of the caller misses it); the
# absolute WORKSPACE goes last so a relative one cannot resolve twice.
if [ "${DETACH:-0}" = 1 ]; then
  args=(); for a in "$@"; do case $a in DETACH=*) ;; *) args+=("$a");; esac; done
  mkdir -p "$CAMP"; dlog="$CAMP/campaign.log"
  sid=(); command -v setsid >/dev/null && sid=(setsid)
  env -u DETACH "${sid[@]}" nohup bash "$SELF" "${args[@]}" WORKSPACE="$WS" >"$dlog" 2>&1 </dev/null &
  dpid=$!
  echo "detached: pid $dpid${sid[*]:+ (own session)}, log $dlog"
  echo "  follow:  tail -f $dlog"
  echo "  results: cat $CAMP/manifest.tsv   (one row per campaign as it ends)"
  echo "  stop:    kill $dpid   (stops and records every campaign)"
  exit 0
fi

mkdir -p "$CAMP"
MAN="$CAMP/manifest.tsv"
COLS="name variant driver harness mode_env entry out_dir mem_limit exec_timeout_ms map_size alloc_cap_mb start stop stop_reason execs stability saved_crashes saved_hangs crash_files hang_files selftest status asan_options seeds_total seeds_loaded dict instances"
[ -f "$MAN" ] || printf '%s\n' "$COLS" | tr ' ' '\t' > "$MAN"
# A manifest from before a trailing column was added: extend its header and pad its rows
# (empty = not recorded), or new rows would sit under the wrong names.  Any other mismatch
# is not ours to rewrite.
MHDR=$(head -1 "$MAN" | tr '\t' ' ')
if [ "$MHDR" != "$COLS" ]; then
  case $COLS in
    "$MHDR "*) pad=$(( $(wc -w <<<"$COLS") - $(wc -w <<<"$MHDR") )); tmp=$(mktemp)
               awk -v cols="$COLS" -v pad="$pad" 'NR==1 { gsub(/ /, "\t", cols); print cols; next }
                    { s = $0; for (i = 0; i < pad; i++) s = s "\t"; print s }' "$MAN" > "$tmp" && mv "$tmp" "$MAN"
               ts "NOTE: $MAN predates column(s) $(cut -d' ' -f$(( $(wc -w <<<"$MHDR") + 1 ))- <<<"$COLS"); header extended, old rows left empty there" ;;
    *) die "$MAN has a different header than this script writes; move it aside (columns: $COLS)" ;;
  esac
fi

ts "workspace $WS"
ts "corpus $CORPUS ($(ls "$CORPUS" | wc -l) seeds); variants: $VARIANTS; self-test: $SELFTEST_STATE"
ts "modes besides default: ${MODES:-none}; ${DURATION}s each, up to $JOBS at once, $INST afl-fuzz instance(s) each, ceiling ${ALLOC_CAP_MB} MB"
ts "dictionary: ${DICT:-default (dict.afl, else out/<variant>/dict.afl)}"
# A piped core_pattern (a crash-report helper): afl-fuzz refuses to start without this.
if [ -z "${AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES:-}" ] && [ "$(head -c1 /proc/sys/kernel/core_pattern 2>/dev/null)" = '|' ]; then
  export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
  ts "NOTE: core_pattern pipes to a helper; setting AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 (afl-fuzz aborts otherwise; crash detection is unaffected, only the core dump is lost)"
fi
# The variables the modes set, and which of them leak in from this environment: the default
# campaign would run as that mode while the manifest records it as default.
LEAKED=""
for n in $(for spec in ${MODES:-}; do tr ',' '\n' <<<"${spec%%:*}" | sed -n 's/=.*//p'; done | sort -u); do
  [ -n "${!n+x}" ] && { LEAKED="$LEAKED $n"; ts "WARN: $n=${!n} is set in the environment; unset for the default campaign (and any mode that does not set $n)"; }
done

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

# Cores: every instance takes one.  Too many is slower than enough (they compete); too few
# leaves cores idle that SECONDARIES would use (measured: 2 campaigns on 14 cores, 12 idle).
NRUN=$(( ${#PLAN[@]} < JOBS ? ${#PLAN[@]} : JOBS )); USED=$(( NRUN * INST ))
ts "plan: ${#PLAN[@]} campaign(s), $NRUN at once x $INST instance(s) = $USED of $NCORES cores"
[ "$USED" -ge "$NCORES" ] && ts "  WARN: $USED afl-fuzz instances on $NCORES cores: they compete for CPU; lower JOBS or SECONDARIES"
if [ $(( USED * 2 )) -lt "$NCORES" ] && [ "$NRUN" -ge 1 ]; then
  k=$(( (NCORES - 1) / NRUN - 1 ))
  [ "$k" -gt "$SECONDARIES" ] && ts "  NOTE: the plan uses $USED of $NCORES cores; SECONDARIES=$k would use them ($NRUN campaign(s) x $((k + 1)) instances)"
fi

# ---- campaign state, in the main shell: afl-fuzz is a DIRECT child, so its pid is real ---
# (An earlier version ran it inside `( ... ) &` and kept the subshell's pid: `kill` then hit
# the wrapper and left afl-fuzz running -- the stability fallback never stopped the unstable
# campaign, and an interrupted run orphaned every afl-fuzz.)
declare -A PID SPIDS IDIR VAR DRV ME EN BIN OUTD MEM MS START ASANO TLOG DICTP
LIVE=()
tag_of() { local t=$1; [ -n "$2" ] && t="$1@$(tr -c 'A-Za-z0-9=' _ <<<"$2" | sed 's/_*$//')"; [ "$3" = fork ] && t="$t.fork"; echo "$t"; }
# <out dir> <key>: from the MAIN instance's fuzzer_stats (default/ alone, main/ with secondaries)
stat_of() { local d; for d in default main; do [ -f "$1/$d/fuzzer_stats" ] && break; done
            sed -n "s/^$2 *: *//p" "$1/$d/fuzzer_stats" 2>/dev/null | head -1 | tr -d ' %'; }
nfiles() { local n; n=$(ls "$1" 2>/dev/null | grep -c '^id:'); echo "${n:-0}"; }
# <out dir> <crashes|hangs>: id:* files over EVERY instance (default/, main/, s<i>/)
nall() { local d t=0; for d in "$1"/*/"$2"; do [ -d "$d" ] && t=$(( t + $(nfiles "$d") )); done; echo "$t"; }

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
  local dict; dict=$(dict_of "$v"); [ -n "$dict" ] && args+=(-x "$dict")
  if [ -z "$DICT" ] && [ "$dict" = "$WS/dict.afl" ] && [ -s "$WS/out/$v/dict.afl" ]; then
    ts "  $tag: dictionary dict.afl ($(grep -c '^[^#]' "$WS/dict.afl") entries) chosen over out/$v/dict.afl ($(grep -c '^[^#]' "$WS/out/$v/dict.afl") entries); DICT=out/$v/dict.afl to use the build's"
  fi
  local tgt=("$bin"); [ "$driver" = fork ] && tgt=("$bin" @@)   # the fork binary reads argv[1]
  # AFL_IGNORE_SEED_PROBLEMS skips seeds that crash or HANG in the dry run (the corpus skill
  # leaves ASAN-only crashers in on purpose; this also catches a hanging or plain-crashing
  # seed that slipped through); AFL_SKIP_CRASHES covers crashes only and a looping seed
  # aborts the whole campaign at startup.
  local cmd=(env) n
  for n in $LEAKED; do cmd+=(-u "$n"); done       # before the mode's own assignments, which win
  [ -n "$me" ] && cmd+=(${me//,/ })               # unquoted on purpose: several VAR=value words
  [ -n "$asan" ] && cmd+=(ASAN_OPTIONS="$asan")
  cmd+=(AFL_MAP_SIZE="$ms" AFL_IGNORE_SEED_PROBLEMS=1 AFL_SKIP_CPUFREQ=1)
  [ "$SCREEN" = 1 ] || cmd+=(AFL_NO_UI=1)         # the UI is the point of SCREEN=1
  # The instances: `default` alone (no -M/-S, output in <o>/default/), or main + s1..sN.
  local insts=(default) i; [ "$SECONDARIES" -gt 0 ] && { insts=(main); for i in $(seq "$SECONDARIES"); do insts+=("s$i"); done; }
  local pid="" spids="" in ilog ia
  for in in "${insts[@]}"; do
    ia=()
    case $in in
      default) ;;
      main) ia=(-M main) ;;
      *) i=${in#s}; ia=(-S "$in")
         if [ "$SECONDARIES" -ge 3 ] && [ "$i" = "$SECONDARIES" ]; then ia+=(-L 0)
         elif [ $(( i % 2 )) = 1 ]; then ia+=(-p explore); else ia+=(-p fast); fi ;;
    esac
    ilog=$log; [ "$in" = default ] || [ "$in" = main ] || ilog="$CAMP/$tag.$in.log"
    local full=("${cmd[@]}" afl-fuzz "${ia[@]}" "${args[@]}" -- "${tgt[@]}") ipid
    if [ "$SCREEN" = 1 ]; then
      # Inside a detached screen (a pty, so afl-fuzz shows its UI).  The window runs a tiny
      # wrapper that starts afl-fuzz in the background, writes ITS pid (env exec()s afl-fuzz,
      # so $! is afl-fuzz) and, when it exits, its exit status -- this script cannot `wait` on
      # a process that is not its child, so .pid and .rc replace $! and wait.  screen -L logs
      # the terminal to the campaign log; the UI's escape codes are in there, the startup
      # messages finish() greps for too.
      local q sess sfx=""; q=$(printf '%q ' "${full[@]}"); [ "$in" = default ] || sfx="-$in"; sess="afl-$tag$sfx"
      rm -f "$o/.pid$sfx" "$o/.rc$sfx"; : > "$ilog"
      screen -dmS "$sess" -L -Logfile "$ilog" bash -c \
        "$q & echo \$! > $(printf %q "$o/.pid$sfx"); wait \$!; echo \$? > $(printf %q "$o/.rc$sfx")"
      local k; for k in $(seq 50); do [ -s "$o/.pid$sfx" ] && break; sleep 0.1; done
      ipid=$(cat "$o/.pid$sfx" 2>/dev/null)
      [ -n "$ipid" ] || { ts "  FAIL $tag: screen session $sess did not start afl-fuzz (is screen working? try: screen -ls)"
                          [ -n "$pid" ] && stop_pids $pid $spids; return 1; }
    else
      "${full[@]}" >"$ilog" 2>&1 &                 # env exec()s afl-fuzz: $! IS afl-fuzz
      ipid=$!
    fi
    if [ -z "$pid" ]; then pid=$ipid; else spids="$spids $ipid"; fi
    # the main instance first: secondaries that start before main exists sync nothing yet
    [ "$in" = main ] && sleep 1
  done
  PID[$tag]=$pid SPIDS[$tag]=${spids# } IDIR[$tag]=${insts[0]} VAR[$tag]=$v DRV[$tag]=$driver ME[$tag]=$me EN[$tag]=$en BIN[$tag]=$bin
  OUTD[$tag]=$o MEM[$tag]=$mem MS[$tag]=$ms START[$tag]=$(date +%s) ASANO[$tag]=$asan TLOG[$tag]=$log DICTP[$tag]=${dict:+${dict#$WS/}}
  LIVE+=("$tag")
  ts "  launched $tag ($driver, pid ${PID[$tag]}${SPIDS[$tag]:+, secondaries ${SPIDS[$tag]}}, -m $mem${asan:+, asan ceiling ${ALLOC_CAP_MB} MB}, dict ${DICTP[$tag]:-none})"
  [ "$SCREEN" = 1 ] && ts "    watch it: screen -r afl-$tag$([ "$SECONDARIES" -gt 0 ] && echo '-main')   (detach with C-a d, not C-c)"
}
# Exit status of a finished campaign: `wait` for our own child, the wrapper's .rc under SCREEN=1
# (give the wrapper a moment to write it after afl-fuzz is gone).
rc_of() {  # <tag> <pid>
  if [ "$SCREEN" = 1 ]; then
    local f="${OUTD[$1]}/.rc"; [ "${IDIR[$1]}" = main ] && f="$f-main"
    local i; for i in $(seq 30); do [ -s "$f" ] && break; sleep 0.1; done
    cat "$f" 2>/dev/null || echo 1
  else wait "$2" 2>/dev/null; echo $?; fi
}

# Stop afl-fuzz instances for real: TERM all at once so each writes its final stats, then
# KILL whichever ignores us.  (Not one after the other: ten seconds each would add up.)
stop_pids() {  # <pid>...
  local p i alive
  for p in "$@"; do kill -TERM "$p" 2>/dev/null; done
  for i in 1 2 3 4 5 6 7 8 9 10; do
    alive=0; for p in "$@"; do kill -0 "$p" 2>/dev/null && alive=1; done
    [ "$alive" = 1 ] || break; sleep 1
  done
  for p in "$@"; do kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null; done
  for p in "$@"; do wait "$p" 2>/dev/null; done
}
# Stop one campaign: its main (or only) instance and every secondary.
stop_one() {  # <tag>
  stop_pids "${PID[$1]}" ${SPIDS[$1]:-}
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
  local idir=${IDIR[$tag]:-default} ins cfm
  # files on disk over EVERY instance; the stats mismatch check below uses the main one's own
  cf=$(nall "$o" crashes); hf=$(nall "$o" hangs); cfm=$(nfiles "$o/$idir/crashes")
  ins=$(( 1 + $(wc -w <<<"${SPIDS[$tag]:-}") ))
  sc=$(stat_of "$o" saved_crashes); sh=$(stat_of "$o" saved_hangs); stab=$(stat_of "$o" stability)
  case $kind in
    switched)    status=switched;    reason="stability-${stab:-?}%-below-${MIN_STABILITY}%-relaunched-on-fork";;
    interrupted) status=interrupted; reason="script-interrupted-after-${elapsed}s";;
    walled)      status=walled;      reason="stopped-at-${WALL}s-wall-clock-fuzz-time-${DURATION}s-not-reached";;
    *) if grep -q 'PROGRAM ABORT' "$log" 2>/dev/null; then
         status=aborted
         reason="afl-fuzz-aborted: $(sed 's/\x1b\[[0-9;]*m//g' "$log" | sed -n 's/.*PROGRAM ABORT *: *//p' | head -1 | cut -c1-110)"
       elif [ "$rc" -ne 0 ]; then status=failed; reason="afl-fuzz-exit-$rc"
       elif [ ! -f "$o/$idir/fuzzer_stats" ]; then status=failed; reason="no-fuzzer_stats"
       elif [ $(( elapsed + 5 )) -lt "$DURATION" ]; then status=early; reason="exited-after-${elapsed}s-of-${DURATION}s"
       else status=completed; reason="completed-${DURATION}s"; fi;;
  esac
  # The files on disk are the truth; fuzzer_stats is only a diagnostic (it is written
  # periodically, so it lags a campaign that was stopped).  A mismatch after a NORMAL finish
  # means two fuzzers shared this -o.
  [ "$status" = completed ] && [ -n "$sc" ] && [ "$sc" != "$cfm" ] \
    && ts "  WARN $tag: $idir/fuzzer_stats saved_crashes=$sc but $cfm id:* files in $idir/crashes (two fuzzers sharing one -o?)"
  [ "$status" != completed ] && [ "$status" != switched ] && ts "  $tag: $status -- $reason"
  local seeds_total seeds_loaded
  seeds_total=$(ls "$CORPUS" | wc -l)
  seeds_loaded=$(sed 's/\x1b\[[0-9;]*m//g' "$log" 2>/dev/null | sed -n 's/.*Loaded a total of \([0-9]*\) seeds.*/\1/p' | head -1)
  dropped_seeds "$tag" "$log" "$o/$idir"
  local row tmp; tmp=$(mktemp)
  row=$(printf '%s\t' "$tag" "${VAR[$tag]}" "${DRV[$tag]}" "${BIN[$tag]}" "${ME[$tag]:-default}" "${EN[$tag]}" \
        "${o#$WS/}" "${MEM[$tag]}" "$(stat_of "$o" exec_timeout)" "${MS[$tag]}" "$ALLOC_CAP_MB" "${START[$tag]}" \
        "$(date +%s)" "$reason" "$(stat_of "$o" execs_done)" "${stab:-}" "${sc:-0}" "${sh:-0}" "$cf" "$hf" \
        "$SELFTEST_STATE" "$status" "${ASANO[$tag]}" "$seeds_total" "${seeds_loaded:-}" "${DICTP[$tag]:--}" "$ins")
  awk -F'\t' -v n="$tag" 'NR==1||$1!=n' "$MAN" > "$tmp"; printf '%s\n' "${row%$'\t'}" >> "$tmp"; mv "$tmp" "$MAN"
  local i; for i in "${!LIVE[@]}"; do [ "${LIVE[$i]}" = "$tag" ] && unset 'LIVE[i]'; done; LIVE=("${LIVE[@]}")
}

# Which seeds this campaign did not fuzz, and why.  afl-fuzz 4.33c skips an empty file and a
# README.txt without a word (they are missing from the queue), and under
# AFL_IGNORE_SEED_PROBLEMS loads a crashing or hanging seed but ignores it, printing
# "WARNING: Test case '<queue name>' results in a crash, skipping" (or "a timeout").
dropped_seeds() {  # <tag> <log> <the main instance's dir> -> writes $CAMP/<tag>.dropped
  local df="$CAMP/$1.dropped" q="$3/queue"
  : > "$df"
  [ -d "$q" ] || return 0
  { ls "$q"; echo /; find "$CORPUS" -type f -printf '%f\t%s\n'; } 2>/dev/null | awk -F'\t' '
    $0 == "/" { c = 1; next }                      # a file name cannot be "/"
    !c { n = $0; seen[n] = 1; i = index(n, ",orig:"); if (i) seen[substr(n, i + 6)] = 1; next }
    ($1 in seen) { next }
    $2 == 0 { print $1 "\tzero-length (afl-fuzz skips empty files without a message)"; next }
    $1 == "README.txt" { print $1 "\tnamed README.txt (afl-fuzz skips it by name)"; next }
    { print $1 "\tnot in the queue (afl-fuzz did not say why)" }' >> "$df"
  sed 's/\x1b\[[0-9;]*m//g' "$2" 2>/dev/null \
    | sed -n "s/.*WARNING: Test case '\(.*\)' results in a \(crash\|timeout\).*/\1\t\2/p" \
    | awk -F'\t' '{ n = $1; i = index(n, ",orig:"); if (i) n = substr(n, i + 6)
                    print n "\t" ($2 == "crash" ? "crashed" : "timed out") " in the dry run (AFL_IGNORE_SEED_PROBLEMS: loaded, not fuzzed)" }' >> "$df"
  return 0
}

# ---- summary and hand-off ----------------------------------------------------------------
summarize() {
  ts "== $(($(grep -c . "$MAN") - 1)) campaign row(s) in $MAN =="
  awk -F'\t' 'NR>1{printf "  %-26s %-10s %-11s stab %-6s crashes %-4s hangs %-4s seeds %s/%s x%s\n",$1,$3,$22,$16,$19,$20,$25,$24,($27==""?1:$27)}' "$MAN"
  # the seeds each campaign did not fuzz, from campaigns/<name>.dropped
  local nm tot ld df
  while IFS=$'\t' read -r nm tot ld; do
    df="$CAMP/$nm.dropped"
    if [ -s "$df" ]; then
      echo "  $nm: $(grep -c . "$df") seed(s) not fuzzed ($df):"
      sed 's/^/      /' "$df"
    elif [ -n "$ld" ] && [ -n "$tot" ] && [ "$ld" != "$tot" ]; then
      echo "  $nm: $((tot - ld)) seed(s) dropped, afl-fuzz did not name them"
    fi
  done < <(awk -F'\t' 'NR>1{print $1 "\t" $24 "\t" $25}' "$MAN")
  local fc fh bad nseed
  # Seeds waiting in crashers/ and hangs/ (the gate's and smoke run's real-stack crashers, the
  # corpus skill's set-asides, hand-filed ones): triage screens them even when no campaign
  # saved anything, so "found nothing" would be false while they wait.
  nseed=$(find "$WS/crashers" "$WS/hangs" -maxdepth 1 -type f ! -name 'README*' 2>/dev/null | wc -l)
  fc=$(awk -F'\t' 'NR>1{c+=$19} END{print c+0}' "$MAN"); fh=$(awk -F'\t' 'NR>1{h+=$20} END{print h+0}' "$MAN")
  bad=$(awk -F'\t' 'NR>1 && $22!="completed" && $22!="switched"{n++} END{print n+0}' "$MAN")
  echo
  if [ "$fc" = 0 ] && [ "$fh" = 0 ]; then
    if [ "$bad" != 0 ]; then
      ts "no crashes or hangs, BUT $bad campaign(s) did not run to completion: this is NOT a result."
      echo "  Read the status column; an aborted or failed campaign finds nothing for a reason that has"
      echo "  nothing to do with the target."
    elif [ "$nseed" -gt 0 ]; then
      ts "no crashes or hangs in the campaigns; $nseed seed(s) in crashers/ and hangs/ await triage."
      echo "  Run the triage skill from $WS: it screens crashers/ and hangs/ on every build and"
      echo "  confirms on the real stack what no build reproduces. Nothing is a result before that."
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
    [ "$nseed" -gt 0 ] && echo "  Also $nseed seed(s) in crashers/ and hangs/ await triage (it screens them too)."
  fi
}

# The one line a waiter greps for, printed last on every exit path after the plan ran.
# A planned campaign counts when this run wrote its row (start >= T0), not an older run.
done_line() {
  local miss="" e v me en t
  for e in "${PLAN[@]}"; do
    IFS='|' read -r v me en <<<"$e"; t=$(tag_of "$v" "$me" persistent)
    awk -F'\t' -v a="$t" -v b="$t.fork" -v t0="$T0" 'NR>1 && ($1==a || $1==b) && $12 >= t0 {f=1} END{exit !f}' "$MAN" || miss="$miss $t"
  done
  if [ -z "$miss" ]; then echo "DONE: ${#PLAN[@]} campaign(s) finished; manifest $MAN"
  else echo "DONE: $(( ${#PLAN[@]} - $(wc -w <<<"$miss") )) of ${#PLAN[@]} planned campaign(s) have a manifest row (no row:$miss); manifest $MAN"; fi
}

# Ctrl-C or SIGTERM: stop every campaign and record it, so no afl-fuzz is orphaned and no
# crash directory is left without a manifest row.
on_interrupt() {
  trap '' INT TERM
  ts "interrupted: stopping ${#LIVE[@]} campaign(s) and recording them"
  # every campaign's instances at once, then one row each (sequentially, ten seconds of
  # grace per campaign would add up)
  local t all=""; for t in "${LIVE[@]:-}"; do [ -n "$t" ] && all="$all ${PID[$t]} ${SPIDS[$t]:-}"; done
  [ -n "${all// /}" ] && stop_pids $all
  for t in "${LIVE[@]:-}"; do [ -n "$t" ] || continue; finish "$t" interrupted 143; done
  summarize; done_line; exit 130
}
trap on_interrupt INT TERM
trap 'for t in "${LIVE[@]:-}"; do [ -n "$t" ] && kill -KILL "${PID[$t]}" ${SPIDS[$t]:-} 2>/dev/null; done' EXIT

# ---- run the plan, JOBS at a time, persistent-first with a stability fallback ------------
ts "== running ${#PLAN[@]} campaign(s) =="
ri=0; HB_NOTE=0
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
        stop_one "$t"; finish "$t" walled 0; continue
      fi
      ts "  $t: $(stat_of "$o" execs_done) execs${SPIDS[$t]:+ (main)}, stability ${stab:-?}%, crashes $(nall "$o" crashes), hangs $(nall "$o" hangs)"
      [ "$HB_NOTE" = 1 ] || { HB_NOTE=1; echo "    (execs and stability come from fuzzer_stats, which afl-fuzz rewrites about every 60 s: repeated numbers are not a stall; crashes/hangs are counted on disk)"; }
      if [ "${DRV[$t]}" = persistent ] && [ -n "$stab" ] \
         && [ $(( $(date +%s) - START[$t] )) -ge "$STAB_CHECK" ] \
         && awk -v s="${stab%%.*}" -v m="$MIN_STABILITY" 'BEGIN{exit !(s+0 < m)}'; then
        ts "  $t: stability ${stab}% < ${MIN_STABILITY}%: stopping it and relaunching on the fork driver"
        stop_one "$t"; v=${VAR[$t]}; me=${ME[$t]}; en=${EN[$t]}
        finish "$t" switched 0
        launch "$v" "$me" "$en" fork
      fi
    else
      # the main instance ended (its -V, or an abort): the secondaries end with it
      rc=$(rc_of "$t" "$pid")
      [ -n "${SPIDS[$t]:-}" ] && stop_pids ${SPIDS[$t]}
      finish "$t" natural "$rc"
    fi
  done
done
trap - INT TERM EXIT
summarize
done_line
