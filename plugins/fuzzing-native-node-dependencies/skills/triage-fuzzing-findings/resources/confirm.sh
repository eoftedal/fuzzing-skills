#!/bin/bash
# Run each bucket representative through the package as `npm install` delivers it, and
# tabulate what a real consumer would see.  One column per BUILD, one table per ENTRY
# POINT, because they answer different questions:
#
#   npm-install(plain)    the ACTUAL binary a user runs.  NATIVE-CRASH here = the release
#                         build segfaults/aborts on this input: uncatchable, ship-stopping.
#                         (Called "install", not "prebuilt": on a platform with no prebuilt
#                         npm compiles from source and the column is your own compiler.)
#   npm-js+asan-addon     the package's published JS with the ASAN addon swapped in.
#                         NATIVE-CRASH here while the install was CLEAN/CAUGHT = a real
#                         memory bug (over-read, small overflow) the release build does not
#                         visibly crash on but still commits -- a vulnerability, lower
#                         urgency than a release crash.
#   npm-js+pristine-addon OPTIONAL third column: the sanitizer with NO fuzzer
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
#   NATIVE-CRASH(...)  node died on a signal or printed a sanitizer report: NO JavaScript
#                      handler can catch this (the user's whole point).
#   UNCAUGHT           a JS error escaped the call's own handling (emitter 'error', async
#                      throw): an ordinary try/catch does NOT stop it, a global handler does.
#   HANG               no answer within TIMEOUT_MS: an algorithmic DoS, not a clean run.
#   CAUGHT             threw or rejected: a try/catch or .catch at the call site stops it.
#   CLEAN              no error at all, with `evidence=` of what the call produced.
#   SKIPPED            the JS layer wanted more than ALLOC_CEIL; proves nothing either way.
#   ERROR              bare `ERROR` = confirm.mjs rejected the ENTRY name (exit 40);
#                      `ERROR(rc=N)` = node died without printing a verdict, usually a PKG
#                      that will not load.  `ERROR(version-mismatch=<got>!=<want>)` = PKG
#                      is not the PKG_VERSION you harnessed (exit 41).  None is a finding;
#                      fix it and re-run.
#   NO-VERDICT         node exited 0 without a verdict: the ENTRIES arm returned undefined
#                      and nothing kept the loop alive (a callback that never fires).  The
#                      arm is mis-wired; not CLEAN.
#
# Configure with KEY=VALUE arguments, then $WORKSPACE/fuzz.env (WORKSPACE default .), then
# environment.  From fuzz.env: PKG, PKG_VERSION, ALLOC_CAP_MB, ADDON (from ADDON_ASAN), and
# ASAN_RT (from $R/find_asan_rt.sh) when ADDON is set.
#   PKG       REQUIRED.  node_modules/<pkg> of a FRESH `npm install <pkg>@<version>`, pinned
#             to the version you harnessed -- a newer npm release may have fixed the bug,
#             which is itself a result worth reporting.  Not your build tree, not the oracle.
#   ADDON     the ASAN addon for the second column; omit to skip it (hard crashes still show
#             in column 1).  The path is whatever your build produced -- Release/<name>.node
#             for node-gyp, often flat out/asan/<name>.node, out/asan/lib/ for a zig build.
#   ADDON_MATCH  regex limiting which loaded addon ADDON replaces.
#   ADDON_MAP    `regex=path;regex=path` when the package loads SEVERAL addons (a runtime
#             plus a grammar).  Without it, one ADDON is swapped in for all of them and the
#             cell reads ADDON-AMBIGUOUS rather than a verdict.  Applies to the ASAN column
#             only; use PRISTINE_MAP for the pristine column, or that column would be run
#             with the instrumented addons.
#   PRISTINE_MAP  the ADDON_MAP equivalent for the pristine column.
#   PRISTINE  the sanitized, UNinstrumented addon (out/pristine/Release/<name>.node).
#   ASAN_RT   LD_PRELOAD for the sanitized columns (the harness skill's find_asan_rt.sh).
#   ALLOC_CAP_MB  fallback allocation ceiling for the sanitized columns (default 1024); the
#             per-bucket ceiling screen.sh recorded in OUT/cap.tsv takes precedence.
#   PKG_VERSION  the version you harnessed; confirm.mjs refuses a PKG of another version.
#   ENTRIES   space-separated ENTRY names defined in confirm.mjs (default: default).
#             Confirm EVERY entry point the binding exposes: 25 of a stylesheet-
#             compiler binding's 111
#             confirmed crashes were reachable only through its second one, and a
#             single-entry-point table reports all 25 as harness artifacts.
#   GOOD      a KNOWN-GOOD input (a corpus seed).  Used as a liveness check before the
#             table: if the consumer call does not produce evidence on a seed that works,
#             the column is mis-wired and its CLEANs mean nothing.
#   GOOD_<entry>  a known-good input for ONE entry point, overriding GOOD for its liveness
#             check: entries that differ in encoding or input shape (a UTF-16 arm, a stream
#             arm) need their own, or the UTF-8 GOOD reads NO-EVIDENCE there.  Characters of
#             the entry name outside [A-Za-z0-9_] become _ (GOOD_from_file for from-file).
#   CONFIRM   the confirm.mjs holding your ENTRIES arms (default: $WORKSPACE/confirm.mjs
#             when it exists, else the copy next to this script).  Copy confirm.mjs into the
#             workspace and fill it in there; an installed plugin's copy is shared.
#   CELL_TIMEOUT  seconds per cell (default 30).  A native infinite loop would otherwise
#             wedge the whole table.
#   OUT       triage work dir (default ./triage); BUCKETS defaults to OUT/buckets.
#   VERDICTS  machine-readable output (default OUT/verdicts.tsv): name, entry, 3 columns.
set -uo pipefail
for kv in "$@"; do case $kv in WORKSPACE=*) export "$kv";; esac; done   # find fuzz.env first
WS=${WORKSPACE:-.}; [ -f "$WS/fuzz.env" ] && { set -a; . "$WS/fuzz.env"; set +a; }
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
PKG=${PKG:?set PKG=node_modules/<pkg> of a fresh npm install}
ADDON=${ADDON:-${ADDON_ASAN:-}}
# the sanitized columns need the runtime preloaded; find it the way the harness skill does
if [ -n "$ADDON" ] && [ -z "${ASAN_RT:-}" ] && [ -n "${R:-}" ] && [ -f "$R/find_asan_rt.sh" ]; then
  rt=$(bash "$R/find_asan_rt.sh" 2>/dev/null) && [ -n "$rt" ] && ASAN_RT=$rt
fi
OUT=${OUT:-./triage}; BUCKETS=${BUCKETS:-$OUT/buckets}
ENTRIES=${ENTRIES:-default}; CELL_TIMEOUT=${CELL_TIMEOUT:-30}
CONF=${CONFIRM:-}
if [ -z "$CONF" ]; then CONF="$WS/confirm.mjs"; [ -f "$CONF" ] || CONF="$(cd "$(dirname "$0")" && pwd)/confirm.mjs"; fi
[ -f "$CONF" ] || { echo "FAIL: CONFIRM=$CONF does not exist" >&2; exit 2; }
CONF="$(cd "$(dirname "$CONF")" && pwd)/$(basename "$CONF")"
[ -z "${GOOD:-}" ] || [ -f "$GOOD" ] || { echo "FAIL: GOOD=$GOOD does not exist (relative to $(pwd)). A missing reference input" >&2
                                            echo "      looks 'consistent' at every ceiling and silently disables the guard." >&2; exit 2; }
goodfor() { local v="GOOD_${1//[^A-Za-z0-9_]/_}"; printf '%s' "${!v:-${GOOD:-}}"; }   # <entry> -> its known-good input
for E in $ENTRIES; do g=$(goodfor "$E"); [ -z "$g" ] || [ -f "$g" ] || { echo "FAIL: the known-good input for ENTRY=$E ($g) does not exist" >&2; exit 2; }; done
# symbolize so a sanitizer report is readable; do NOT abort (let it exit 86 after printing).
# The allocation ceiling is set PER BUCKET from OUT/cap.tsv (the ceiling the input reproduced
# at), appended last so nothing inherited overrides it.  It used to be a fixed 4096 MB here,
# which made the ASAN column acquit declared-size bugs: a block-compression binding's 5-byte input is rc=1 at
# 4096 and aborts at 1024.
ALLOC_CAP_MB=${ALLOC_CAP_MB:-1024}
# detect_leaks=0 is appended after an inherited ASAN_OPTIONS too: node under ASAN otherwise
# prints a LeakSanitizer SUMMARY at exit, and the `Sanitizer:` test below would read every
# cell as NATIVE-CRASH.
ASAN_BASE="${ASAN_OPTIONS:-abort_on_error=0:exitcode=86:symbolize=1:allocator_may_return_null=1}:detect_leaks=0"
export ASAN_OPTIONS="$ASAN_BASE:allocator_may_return_null=1:max_allocation_size_mb=$ALLOC_CAP_MB"
# confirm.mjs's JS-side ceiling (Buffer.alloc*) is the SAME number as the sanitizer's, per
# bucket: a JS layer that allocates the declared size would otherwise hit a different limit
# first and the cell would read SKIPPED where the ASAN column says allocation-size-too-big.
export ALLOC_CEIL=$(( ALLOC_CAP_MB * 1048576 ))
capof() { [ -f "$OUT/cap.tsv" ] && awk -F'\t' -v n="$1" '$1==n{print $2; exit}' "$OUT/cap.tsv"; }

# Timestamped progress.  A triage run has several multi-minute steps and at least two that
# can hang outright, so every phase is stamped: an agent reading the log can tell "slow" from
# "stalled" and name the step it stalled in.
T0=$(date +%s)
ts() { printf '[%s +%ds] %s\n' "$(date +%H:%M:%S)" "$(( $(date +%s) - T0 ))" "$*"; }
# Stack exhaustion's threshold is the stack limit, not the input, and an async entry point
# runs on a libuv thread with its own stack.  Record it: a depth-sensitive verdict means
# nothing without it.
echo "# confirm script: $CONF"
echo "# stack limit: $(ulimit -s) KiB   node: $(node -v)   cell timeout: ${CELL_TIMEOUT}s"
nb=$(ls "$BUCKETS" 2>/dev/null | grep -v '\.key$' | grep -c '^[^.]' || true)   # minimize.sh writes <name>.key beside each reproducer
ne=$(set -- $ENTRIES; echo $#)
ncols=1; [ -n "${ADDON:-}" ] && ncols=$((ncols+1)); [ -n "${PRISTINE:-}" ] && ncols=$((ncols+1))
ts "# $nb bucket(s) x $ne entry point(s) x $ncols column(s) = up to $((nb*ne*ncols)) node runs, ${CELL_TIMEOUT}s each"
echo "# PKG=$PKG"
# Buckets found under a harness MODE need an ENTRIES arm that selects the same mode through
# the npm API, or a real bug reads CLEAN here.  Measured on the image-decoding binding's
# next major version: the two bugs found under harness MODE=2 are CLEAN through its
# promise-based loader and NATIVE-CRASH(sig11) on the npm install through an arm that sets
# the image object's MIME data mode (harness MODE=2 IS that setting).
HMODE=$(sed -n 's/^HARNESS_ENV=//p' "$OUT/config" 2>/dev/null)
if [ -n "$HMODE" ]; then
  echo "# NOTE: these buckets were found under harness mode '$HMODE'.  Confirm them through"
  echo "#       an ENTRIES arm that selects the same mode via the npm API; the default arm"
  echo "#       will read CLEAN for a real bug."
fi

# LAST_OUT keeps the raw output of the most recent run, so the liveness check can read
# `evidence=` from the same execution that produced the verdict instead of running twice.
LAST_OUT=
run() {  # <crash file> <env assignments...>  -> prints one cell, sets LAST_OUT
  local f=$1; shift
  local out rc
  # The KEY=VALUE argument parser above EXPORTS whatever you passed, so EVERY swap variable
  # has to be unset here and forwarded per column.  Without it the plain column inherits
  # ADDON (or ADDON_MAP) and loads the ASAN addon with no sanitizer runtime preloaded: the
  # addon fails to dlopen, every row of the most important column reads ERROR(rc=1), and the
  # release build never gets tested.  ADDON_MAP is the subtler one -- confirm.mjs gives the
  # map precedence over ADDON, so an inherited map would also turn the PRISTINE column into
  # a second ASAN column, i.e. the one column whose job is to rule out an instrumentation
  # artifact would be answered by the instrumented build.
  out=$(timeout "$CELL_TIMEOUT" env -u ADDON -u ADDON_MATCH -u ADDON_MAP -u LD_PRELOAD \
            "$@" node "$CONF" "$f" 2>&1)
  rc=$?
  LAST_OUT=$out
  if   grep -q 'Sanitizer:' <<<"$out"; then echo "NATIVE-CRASH($(sed -n 's/.*Sanitizer: \([a-z-]*\( of memory\)\{0,1\}\).*/\1/p' <<<"$out" | head -1 | tr ' ' '-'))"
  elif [ "$rc" = 124 ];          then echo "HANG(cell-timeout)"
  elif [ "$rc" -ge 128 ];        then echo "NATIVE-CRASH(sig$((rc-128)))"
  elif [ "$rc" = 86 ];           then echo "NATIVE-CRASH(asan)"
  elif grep -q '^verdict=' <<<"$out"; then
    local v; v=$(sed -n 's/^verdict=\([A-Z-]*\).*/\1/p' <<<"$out" | head -1)
    # A silently un-swapped ADDON makes this column a duplicate of the install column and
    # hides every memory bug it exists to find.  That is an error, not a verdict.
    grep -q 'addon=NOT-SWAPPED'    <<<"$out" && v="ADDON-NOT-SWAPPED"
    grep -q 'addon=AMBIGUOUS-SWAP' <<<"$out" && v="ADDON-AMBIGUOUS"
    local why; why=$(sed -n 's/^verdict=ERROR \(version-mismatch=[^ ]*\).*/\1/p' <<<"$out" | head -1)
    [ -n "$why" ] && v="ERROR($why)"
    echo "$v"
  # rc=0 with no verdict line: the ENTRIES arm returned undefined and nothing kept the event
  # loop alive (its callback never fired, or it forgot to call okback/errback), so node simply
  # exited.  Not a package failure to load, and not CLEAN: the arm is mis-wired.
  elif [ "$rc" = 0 ];            then echo "NO-VERDICT(arm-returned-silently)"
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
  # Liveness check.  A column of all-CLEAN is the signature of a mis-wired consumer call,
  # not of a clean package; prove the call does something on an input that works before
  # believing a CLEAN on an input that crashed the harness.
  G=$(goodfor "$E")
  if [ -n "$G" ]; then
    # NOT $(run ...): a command substitution is a subshell, so LAST_OUT would not come
    # back.  Capture through a file instead, and read the evidence from that one run.
    run "$G" ENTRY="$E" PKG="$PKG" > "$OUT/.liveness"
    g=$(cat "$OUT/.liveness"); rm -f "$OUT/.liveness"
    ev=$(sed -n 's/.*\(evidence=[^ ]*\).*/\1/p' <<<"$LAST_OUT" | head -1)
    gv=GOOD; [ "$G" = "${GOOD:-}" ] || gv="GOOD_${E//[^A-Za-z0-9_]/_}"
    echo "# liveness ($gv=$(basename "$G")): $g ${ev:-NO-EVIDENCE}"
    case "$g" in CLEAN) :;; *) echo "# WARN: the known-good seed is not CLEAN on this entry point;" \
        "every CLEAN below is unverified until the consumer call is right.";; esac
    [ -z "$ev" ] && echo "# WARN: no evidence= on the known-good seed: the call may be returning" \
        "without doing the work (an image-decoding binding's hardcoded completion getter 'confirmed' 18 failures)."
  else
    echo "# no GOOD= (or GOOD_${E//[^A-Za-z0-9_]/_}=) given: the CLEAN cells below are unverified. Pass a corpus seed."
  fi
  cells=0
  printf '%-34s %-24s %-24s %-24s\n' CRASH 'npm-install(plain)' 'npm-js+asan-addon' 'npm-js+pristine-addon'
  for c in "$BUCKETS"/*; do
    [ -f "$c" ] || continue
    case $c in *.key) continue;; esac                     # minimize.sh's key file, not an input
    pname=$(basename "$c" | sed 's/^[0-9a-f]\{6\}-//')
    orig="$OUT/pool/$pname"                                  # pre-tmin bytes (see screen.sh)
    cap=$(capof "$pname"); export ASAN_OPTIONS="$ASAN_BASE:allocator_may_return_null=1:max_allocation_size_mb=${cap:-$ALLOC_CAP_MB}"
    export ALLOC_CEIL=$(( ${cap:-$ALLOC_CAP_MB} * 1048576 ))
    a=$(cell "$c" "$orig" ENTRY="$E" PKG="$PKG")
    if [ -n "${ADDON:-}" ]; then
      b=$(cell "$c" "$orig" ENTRY="$E" PKG="$PKG" ADDON="$ADDON" \
               ${ADDON_MATCH:+ADDON_MATCH="$ADDON_MATCH"} ${ADDON_MAP:+ADDON_MAP="$ADDON_MAP"} \
               ${ASAN_RT:+LD_PRELOAD="$ASAN_RT"})
    else b="(no ADDON)"; fi
    if [ -n "${PRISTINE:-}" ]; then
      p=$(cell "$c" "$orig" ENTRY="$E" PKG="$PKG" ADDON="$PRISTINE" \
               ${ADDON_MATCH:+ADDON_MATCH="$ADDON_MATCH"} ${PRISTINE_MAP:+ADDON_MAP="$PRISTINE_MAP"} \
               ${ASAN_RT:+LD_PRELOAD="$ASAN_RT"})
    else p="(no PRISTINE)"; fi
    printf '%-34s %-24s %-24s %-24s\n' "$(basename "$c" | cut -c1-34)" "$a" "$b" "$p"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(basename "$c")" "$E" "$a" "$b" "$p" >> "$VERDICTS"
    cells=$((cells+1)); ts "# cell $cells/$nb done ($E)" >&2
  done
done
echo
echo "severity: install NATIVE-CRASH = critical (any consumer, uncatchable);"
echo "          asan-only NATIVE-CRASH = real memory bug, release build hides the symptom;"
echo "          reproduces on PRISTINE too = not an artifact of the coverage instrumentation;"
echo "          HANG = algorithmic DoS, uncatchable by try/catch;"
echo "          UNCAUGHT = DoS unless the consumer installs a global handler;"
echo "          CAUGHT = defensible (a try/catch is enough);"
echo "          CLEAN on EVERY entry point incl. the raw-byte one = not reachable here."
echo "note: an out-of-bounds WRITE of any size outranks a 1-byte READ whatever the column"
echo "      says; bucket.sh prints the access direction in the key."
