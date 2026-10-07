#!/bin/bash
# Run each bucket representative through the gem as `gem install` delivers it, and
# tabulate what a real user would see.  One column per BUILD, one table per ENTRY
# POINT, because they answer different questions:
#
#   gem-install(plain)    the ACTUAL extension a user runs (the oracle/ install, built from
#                         source).  NATIVE-CRASH here = the release build segfaults/aborts
#                         on this input: uncatchable, ship-stopping.
#   gem+asan-ext          the gem's published Ruby with the ASAN extension swapped in.
#                         NATIVE-CRASH here while the install was CLEAN/CAUGHT = a real
#                         memory bug (over-read, small overflow) the release build does not
#                         visibly crash on but still commits -- a vulnerability, lower
#                         urgency than a release crash.
#   gem+pristine-ext      OPTIONAL third column: the sanitizer with NO fuzzer
#                         instrumentation.  It answers the question a maintainer will ask
#                         first -- "did your coverage instrumentation invent this?"  A
#                         finding that reproduces here is not an instrumentation artifact,
#                         and that sentence belongs in the report.  A finding that
#                         reproduces ONLY on the instrumented ASAN build is suspect.
#
# A `| head -1` or `grep -q` below is inside a command substitution with `set -e` OFF, so
# pipefail cannot turn a SIGPIPE into a silent empty verdict.  Do not "harden" these into
# `set -e`: that converts the most alarming possible false negative (a crash reported as
# CLEAN) from impossible into likely.
#
# Verdicts per cell, most severe first:
#   NATIVE-CRASH(...)  ruby died on a signal, printed a `[BUG]` report (its own SIGSEGV/
#                      SIGBUS handler, which aborts) or a sanitizer report: NO Ruby rescue
#                      can catch this.
#   UNCAUGHT           an Exception that is not a StandardError (NoMemoryError,
#                      SystemStackError), a dead gem thread, or fatal: a plain
#                      `rescue => e` does NOT stop it.
#   HANG               no answer within TIMEOUT_MS: an algorithmic DoS, not a clean run.
#   CAUGHT             raised a StandardError: `rescue => e` at the call site stops it.
#   CLEAN              no error at all, with `evidence=` of what the call produced.
#   SKIPPED            NoMemoryError under the sanitizer allocation cap; proves nothing.
#   ERROR              `ERROR` = confirm.rb rejected the ENTRY or could not load PKG
#                      (exit 40); `ERROR(rc=N)` = ruby died without printing a verdict.
#                      Neither is a finding; fix it and re-run.
#   EXT-NOT-SWAPPED / EXT-AMBIGUOUS   the sanitized column did not run the sanitized
#                      extension (or one EXT replaced two extensions).  Not a verdict.
#
# Configure with KEY=VALUE arguments or environment:
#   PKG       REQUIRED.  oracle/gems/<gem>-<ver> of a FRESH
#             `gem install --install-dir oracle --platform ruby <gem> -v <version>`, pinned
#             to the version you harnessed -- a newer release may have fixed the bug, which
#             is itself a result worth reporting.  Not your build tree.
#   REQUIRE   the feature to require (default: the gem's name).
#   TIMEOUT_MS  confirm.rb's own HANG watchdog (default 10000); keep it below CELL_TIMEOUT.
#   EXT       the ASAN extension for the second column (out/asan/<name>.so); omit to skip
#             it (hard crashes still show in column 1).
#   EXT_MATCH regex limiting which loaded extension EXT replaces.
#   EXT_MAP   `regex=path;regex=path` when the gem loads SEVERAL extensions.  Without it,
#             one EXT is swapped in for all of them and the cell reads EXT-AMBIGUOUS.
#             Applies to the ASAN column only; use PRISTINE_MAP for the pristine column,
#             or that column would be run with the instrumented extensions.
#   PRISTINE_MAP  the EXT_MAP equivalent for the pristine column.
#   PRISTINE  the sanitized, UNinstrumented extension (out/pristine/<name>.so).
#   ASAN_RT   LD_PRELOAD for the sanitized columns (the harness skill's find_asan_rt.sh).
#   ALLOC_CAP_MB  fallback allocation ceiling for the sanitized columns (default 1024); the
#             per-bucket ceiling screen.sh recorded in OUT/cap.tsv takes precedence.
#   ENTRIES   space-separated ENTRY names defined in confirm.rb (default: default).
#             Confirm EVERY entry point the gem exposes: on a Node binding, 25 of 111
#             confirmed crashes were reachable only through its second entry point, and a
#             single-entry-point table reports all 25 as harness artifacts.
#   GOOD      a KNOWN-GOOD input (a corpus seed).  Used as a liveness check before the
#             table: if the call does not produce evidence on a seed that works, the
#             column is mis-wired and its CLEANs mean nothing.
#   CELL_TIMEOUT  seconds per cell (default 30).  A C loop that never releases the GVL
#             starves confirm.rb's own watchdog; this is what stops it.
#   OUT       triage work dir (default ./triage); BUCKETS defaults to OUT/buckets.
#   VERDICTS  machine-readable output (default OUT/verdicts.tsv): name, entry, 3 columns.
set -uo pipefail
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
PKG=${PKG:?set PKG=oracle/gems/<gem>-<ver> of a fresh gem install --install-dir oracle --platform ruby}
PKG=$(cd "$PKG" && pwd) || exit 2
OUT=${OUT:-./triage}; BUCKETS=${BUCKETS:-$OUT/buckets}
ENTRIES=${ENTRIES:-default}; CELL_TIMEOUT=${CELL_TIMEOUT:-30}
CONF="$(cd "$(dirname "$0")" && pwd)/confirm.rb"
[ -z "${GOOD:-}" ] || [ -f "$GOOD" ] || { echo "FAIL: GOOD=$GOOD does not exist (relative to $(pwd)). A missing reference input" >&2
                                            echo "      looks 'consistent' at every ceiling and silently disables the guard." >&2; exit 2; }
# symbolize so a sanitizer report is readable; do NOT abort (let it exit 86 after printing).
# The allocation ceiling is set PER BUCKET from OUT/cap.tsv (the ceiling the input reproduced
# at), appended last so nothing inherited overrides it.  (On the Node sibling a fixed 4096 MB
# here acquitted declared-size bugs: a 5-byte input was rc=1 at 4096 and aborted at 1024.)
ALLOC_CAP_MB=${ALLOC_CAP_MB:-1024}
# detect_leaks=0 is appended after an inherited ASAN_OPTIONS too: ruby does not free
# everything at exit, LeakSanitizer would print a SUMMARY, and the `Sanitizer:` test below
# would read every cell as NATIVE-CRASH.
ASAN_BASE="${ASAN_OPTIONS:-abort_on_error=0:exitcode=86:symbolize=1:allocator_may_return_null=1}:detect_leaks=0"
capof() { [ -f "$OUT/cap.tsv" ] && awk -F'\t' -v n="$1" '$1==n{print $2; exit}' "$OUT/cap.tsv"; }

# Timestamped progress.  A triage run has several multi-minute steps and at least two that
# can hang outright, so every phase is stamped: an agent reading the log can tell "slow" from
# "stalled" and name the step it stalled in.
T0=$(date +%s)
ts() { printf '[%s +%ds] %s\n' "$(date +%H:%M:%S)" "$(( $(date +%s) - T0 ))" "$*"; }
# Stack exhaustion's threshold is the stack limit, not the input, and a thread the gem
# starts has its own (RUBY_THREAD_VM_STACK_SIZE / the machine stack of that thread).
# Record it: a depth-sensitive verdict means nothing without it.
echo "# stack limit: $(ulimit -s) KiB   $(ruby -v)   cell timeout: ${CELL_TIMEOUT}s"
nb=$(ls "$BUCKETS" 2>/dev/null | grep -c '^[^.]' || true)
ne=$(set -- $ENTRIES; echo $#)
ncols=1; [ -n "${EXT:-}" ] && ncols=$((ncols+1)); [ -n "${PRISTINE:-}" ] && ncols=$((ncols+1))
ts "# $nb bucket(s) x $ne entry point(s) x $ncols column(s) = up to $((nb*ne*ncols)) ruby runs, ${CELL_TIMEOUT}s each"
echo "# PKG=$PKG"
# Buckets found under a harness MODE need an ENTRIES arm that selects the same mode through
# the gem's API, or a real bug reads CLEAN here.  (Measured on a Node binding: two bugs
# found under harness MODE=2 were CLEAN through its default loader and NATIVE-CRASH(sig11)
# through an arm that set the matching mode.)
HMODE=$(sed -n 's/^HARNESS_ENV=//p' "$OUT/config" 2>/dev/null)
if [ -n "$HMODE" ]; then
  echo "# NOTE: these buckets were found under harness mode '$HMODE'.  Confirm them through"
  echo "#       an ENTRIES arm that selects the same mode via the gem's API; the default arm"
  echo "#       will read CLEAN for a real bug."
fi

# LAST_OUT keeps the raw output of the most recent run, so the liveness check can read
# `evidence=` from the same execution that produced the verdict instead of running twice.
LAST_OUT=
run() {  # <crash file> <env assignments...>  -> prints one cell, sets LAST_OUT
  local f=$1; shift
  local out rc
  # The KEY=VALUE argument parser above EXPORTS whatever you passed, so EVERY swap variable
  # (and the sanitizer environment) has to be unset here and forwarded per column.  Without
  # it the plain column inherits EXT and loads the ASAN extension with no sanitizer runtime
  # preloaded: the load fails, every row of the most important column reads ERROR, and the
  # release build never gets tested.  EXT_MAP is the subtler one -- confirm.rb gives the map
  # precedence over EXT, so an inherited map would also turn the PRISTINE column into a
  # second ASAN column.  ALLOC_CEIL only belongs to the capped (sanitized) columns: in the
  # plain column a NoMemoryError is the gem's real behaviour, not the cap's.
  # -k: ruby defers SIGTERM until the VM checks for interrupts, and a C loop holding the
  # GVL never lets it (measured: a cell ran 10 minutes past an 8 s timeout).  KILL follows.
  local t0=$SECONDS
  out=$(timeout -k 2 "$CELL_TIMEOUT" env -u EXT -u EXT_MATCH -u EXT_MAP -u LD_PRELOAD -u ALLOC_CEIL \
            -u ASAN_OPTIONS "$@" ruby "$CONF" "$f" 2>&1)
  rc=$?
  # 137 after the full timeout is timeout's own KILL; 137 earlier is a real SIGKILL (OOM killer)
  [ "$rc" = 137 ] && [ $((SECONDS - t0)) -lt "$CELL_TIMEOUT" ] && rc=1137
  LAST_OUT=$out
  # A full sanitizer report first ("ERROR: AddressSanitizer: heap-buffer-overflow ..."),
  # then Ruby's own SIGSEGV handler ("x.rb:8: [BUG] Segmentation fault at 0x..." then
  # abort(), which under ASAN adds a bare "AddressSanitizer:DEADLYSIGNAL" with no report):
  # name the signal Ruby reported, not the SIGABRT it ended with.
  if   grep -q 'Sanitizer: ' <<<"$out"; then echo "NATIVE-CRASH($(sed -n 's/.*Sanitizer: \([A-Za-z-]*\( of memory\)\{0,1\}\).*/\1/p' <<<"$out" | head -1 | tr ' ' '-'))"
  elif grep -q '\[BUG\]' <<<"$out"; then echo "NATIVE-CRASH(bug-$(sed -n 's/.*\[BUG\] \([A-Za-z ]*[A-Za-z]\).*/\1/p' <<<"$out" | head -1 | sed 's/ at$//' | tr ' ' '-' | cut -c1-24))"
  elif grep -q 'Sanitizer:DEADLYSIGNAL' <<<"$out"; then echo "NATIVE-CRASH(deadlysignal)"
  elif [ "$rc" = 124 ] || [ "$rc" = 137 ]; then echo "HANG(cell-timeout)"
  elif [ "$rc" = 1137 ];         then echo "NATIVE-CRASH(sig9)"
  elif [ "$rc" -ge 128 ];        then echo "NATIVE-CRASH(sig$((rc-128)))"
  elif [ "$rc" = 86 ];           then echo "NATIVE-CRASH(asan)"
  elif grep -q '^verdict=' <<<"$out"; then
    local v; v=$(sed -n 's/^verdict=\([A-Z-]*\).*/\1/p' <<<"$out" | head -1)
    # A silently un-swapped EXT makes this column a duplicate of the install column and
    # hides every memory bug it exists to find.  That is an error, not a verdict.
    grep -q 'swap=NOT-SWAPPED'    <<<"$out" && v="EXT-NOT-SWAPPED"
    grep -q 'swap=AMBIGUOUS-SWAP' <<<"$out" && v="EXT-AMBIGUOUS"
    echo "$v"
  else echo "ERROR(rc=$rc)"; fi
}

# cell: run the minimized input; if it comes back CLEAN, the shrink may have stopped
# reaching far enough for THIS build (tmin minimized against the harness's redzones, not
# this one), so fall back to the pre-tmin bytes before trusting the CLEAN.  Prints
# `CLEAN->NATIVE-CRASH(..)(orig)` when the original still crashes.
cell() {  # <minimized file> <original file> <env...>
  local min=$1 orig=$2; shift 2
  local v; v=$(run "$min" "$@")
  if [ "$v" = CLEAN ] && [ -f "$orig" ] && ! cmp -s "$min" "$orig"; then
    local vo; vo=$(run "$orig" "$@")
    # SKIPPED and ERROR are reported too: "the minimized input is clean and the original
    # proved nothing" is not the same claim as a plain CLEAN.
    case "$vo" in NATIVE-CRASH*|UNCAUGHT|HANG*|CAUGHT|SKIPPED|ERROR*) echo "CLEAN->${vo}(orig)";;
                  *) echo "$v";; esac
  else echo "$v"; fi
}

[ -n "$(ls "$BUCKETS" 2>/dev/null)" ] || { echo "no representatives in $BUCKETS; run bucket.sh first" >&2; exit 1; }
# Machine-readable verdicts, one line per bucket x entry: name, entry, install, asan, pristine.
# The driver reads this to decide which representatives are worth minimizing.
VERDICTS=${VERDICTS:-$OUT/verdicts.tsv}; : > "$VERDICTS"

for E in $ENTRIES; do
  echo
  echo "===== ENTRY=$E ====="
  # Liveness check.  A column of all-CLEAN is the signature of a mis-wired call, not of a
  # clean gem; prove the call does something on an input that works before believing a
  # CLEAN on an input that crashed the harness.
  if [ -n "${GOOD:-}" ]; then
    # The sanitized columns get a liveness run too, and it must show swap=swapped: a cell
    # that crashes exits before confirm.rb can report its swap state, so this is the only
    # place a silently un-swapped EXT would show up for crashing rows.
    for col in EXT PRISTINE; do
      so=${!col:-}; [ -n "$so" ] || continue
      m=${EXT_MAP:-}; [ "$col" = PRISTINE ] && m=${PRISTINE_MAP:-}
      lv=$(timeout -k 2 "$CELL_TIMEOUT" env -u EXT_MAP ENTRY="$E" PKG="$PKG" EXT="$so" ${EXT_MATCH:+EXT_MATCH="$EXT_MATCH"} \
             ${m:+EXT_MAP="$m"} ${ASAN_RT:+LD_PRELOAD="$ASAN_RT"} ASAN_OPTIONS="$ASAN_BASE" ruby "$CONF" "$GOOD" 2>&1)
      sw=$(sed -n 's/.* swap=\([A-Za-z-]*\).*/\1/p' <<<"$lv" | head -1)
      echo "# liveness $col: $(sed -n 's/^verdict=\([A-Z-]*\).*/\1/p' <<<"$lv" | head -1) swap=${sw:-?}"
      [ "$sw" = swapped ] || echo "# WARN: the $col column did not prove its swap on the known-good seed; its NATIVE-CRASH/CLEAN cells may be the plain build's."
    done
    # NOT $(run ...): a command substitution is a subshell, so LAST_OUT would not come
    # back.  Capture through a file instead, and read the evidence from that one run.
    run "$GOOD" ENTRY="$E" PKG="$PKG" > "$OUT/.liveness"
    g=$(cat "$OUT/.liveness"); rm -f "$OUT/.liveness"
    ev=$(sed -n 's/.*\(evidence=[^ ]*\).*/\1/p' <<<"$LAST_OUT" | head -1)
    echo "# liveness (GOOD=$(basename "$GOOD")): $g ${ev:-NO-EVIDENCE}"
    case "$g" in CLEAN) :;; *) echo "# WARN: the known-good seed is not CLEAN on this entry point;" \
        "every CLEAN below is unverified until the call is right.";; esac
    case "$ev" in ""|evidence=type=nil|evidence=bytes=0|evidence=*=0)
      echo "# WARN: the known-good seed produced ${ev:-no evidence}: the call may be returning" \
        "without doing the work, and every CLEAN below is suspect.";; esac
  else
    echo "# no GOOD= given: the CLEAN cells below are unverified. Pass a corpus seed."
  fi
  cells=0
  printf '%-34s %-24s %-24s %-24s\n' CRASH 'gem-install(plain)' 'gem+asan-ext' 'gem+pristine-ext'
  for c in "$BUCKETS"/*; do
    [ -f "$c" ] || continue
    pname=$(basename "$c" | sed 's/^[0-9a-f]\{6\}-//')
    orig="$OUT/pool/$pname"                                  # pre-tmin bytes (see screen.sh)
    cap=$(capof "$pname"); cap=${cap:-$ALLOC_CAP_MB}
    SANENV=(ASAN_OPTIONS="$ASAN_BASE:allocator_may_return_null=1:max_allocation_size_mb=$cap"
            ALLOC_CEIL=$(( cap * 1048576 )) ${ASAN_RT:+LD_PRELOAD="$ASAN_RT"})
    a=$(cell "$c" "$orig" ENTRY="$E" PKG="$PKG")
    if [ -n "${EXT:-}" ]; then
      b=$(cell "$c" "$orig" ENTRY="$E" PKG="$PKG" EXT="$EXT" \
               ${EXT_MATCH:+EXT_MATCH="$EXT_MATCH"} ${EXT_MAP:+EXT_MAP="$EXT_MAP"} "${SANENV[@]}")
    else b="(no EXT)"; fi
    if [ -n "${PRISTINE:-}" ]; then
      p=$(cell "$c" "$orig" ENTRY="$E" PKG="$PKG" EXT="$PRISTINE" \
               ${EXT_MATCH:+EXT_MATCH="$EXT_MATCH"} ${PRISTINE_MAP:+EXT_MAP="$PRISTINE_MAP"} "${SANENV[@]}")
    else p="(no PRISTINE)"; fi
    printf '%-34s %-24s %-24s %-24s\n' "$(basename "$c" | cut -c1-34)" "$a" "$b" "$p"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(basename "$c")" "$E" "$a" "$b" "$p" >> "$VERDICTS"
    cells=$((cells+1)); ts "# cell $cells/$nb done ($E)" >&2
  done
done
echo
echo "severity: install NATIVE-CRASH = critical (any user, uncatchable);"
echo "          asan-only NATIVE-CRASH = real memory bug, release build hides the symptom;"
echo "          reproduces on PRISTINE too = not an artifact of the coverage instrumentation;"
echo "          HANG = algorithmic DoS, uncatchable by rescue;"
echo "          UNCAUGHT = escapes \`rescue => e\`; a user must rescue Exception (or the class) explicitly;"
echo "          CAUGHT = defensible (\`rescue => e\` is enough);"
echo "          CLEAN on EVERY entry point incl. the path/IO one = not reachable here."
echo "note: an out-of-bounds WRITE of any size outranks a 1-byte READ whatever the column"
echo "      says; bucket.sh prints the access direction in the key."
echo "note: the gem's Ruby side cannot show an over-read of a small INPUT String (it lives in a"
echo "      GC slot, not a malloc block); a direct-harness-only over-read of the input may be that."
