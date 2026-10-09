#!/bin/bash
# Drive the whole triage: discover every campaign in the workspace, pair each with the
# harness variant that produced it, minimize and bucket crashes AND hangs, re-screen what
# did not reproduce under the harness's other modes, optionally confirm against the npm
# install, and write a report skeleton.
#
#   resources/triage_all.sh [OUT=./triage] [PKG=...] [GOOD=...] [ENTRIES="..."] [MODES="..."]
#
# What it does NOT decide for you, and cannot:
#   * the consumer calls.  Copy confirm.mjs into the workspace ($WORKSPACE/confirm.mjs, found
#     there by default) and fill in its ENTRIES arms first.  Without PKG it stops after
#     bucketing and says so.
#   * the harness's modes.  If the harness reads a mode variable (MODE=, HARNESS_MODE=),
#     list the non-default settings in MODES -- the driver cannot discover them.
#   * severity and the write-up.  OUT/REPORT.md has the facts; you judge.
#
# Configure with KEY=VALUE arguments or environment:
#   OUT       root work directory (default ./triage).  Each run gets
#             OUT/<variant>-<crashes|hangs|crashers>[@<mode>]/.
#   WORKSPACE where to look for campaigns and out/<variant>/ (default .)
#   MODES     space-separated harness settings to try, in order, on whatever has not yet
#             reproduced (e.g. "MODE=2 MODE=3").  Each one gets its own run on the previous
#             run's non-reproducers only, so nothing is minimized twice.  A crash found in a
#             non-default mode does not reproduce in the default one: two crashers from the
#             image-decoding binding's next major version are rc=0 by default and
#             rc=134 under MODE=2.
#   PKG       node_modules/<pkg> of a FRESH npm install; omit to stop after bucketing.
#   GOOD      a reference input: guards minimize.sh's allocation-ceiling ladder AND is
#             confirm.sh's liveness check.
#   GOOD_<entry>  a known-good input for one entry point's liveness check (an entry that
#             takes another encoding or input shape), passed to confirm.sh; see its header.
#   CONFIRM   the confirm.mjs with your ENTRIES arms (default: $WORKSPACE/confirm.mjs when it
#             exists, else the plugin's copy next to this script).  Passed to confirm.sh.
#   ENTRIES ASAN_RT ADDON_MATCH ADDON_MAP PRISTINE_MAP   passed to confirm.sh.
#   ADDON PRISTINE   override the auto-discovered addon paths.
#   TIMEOUT RETRY HANG_S ALLOC_CAP_MB CAP_LADDER CAP_UP CELL_TIMEOUT PROGRESS_EVERY
#             passed through.  TIMEOUT is in ms (screen.sh's unit).  In manifest mode, unless
#             set here: a campaign's hangs are screened at HANG_MULT (default 2) x its
#             exec_timeout_ms plus HANG_PAD_S (default 1) s of process start-up (AFL's fork
#             server excluded start-up; a fresh process does not), not the 5000 ms + 5 s
#             default; and a campaign with stability < 90 % is screened with RETRY=5.
#   HARNESS_RE  regex for the harness's own source files (default: smoke.sh's); a bucket
#             keyed in one is copied code, and the report says to map its line by hand.
#   ONLY      space-separated variant names to restrict to (default: all discovered).
#   SKIP_HANGS=1   crashes only.
#   MINIMIZE_ALL=1 also minimize representatives that are CLEAN on every column and entry.
#
# $WORKSPACE/fuzz.env (the harness skill writes it) supplies defaults below the arguments:
# PKG, ADDON (from ADDON_ASAN), ASAN_RT (from $R/find_asan_rt.sh), and MODES and ALLOC_CAP_MB,
# which rank below the manifest too (it records what the campaigns actually ran with).
#
# Order: screen -> bucket the RAW reproducers -> confirm one representative per bucket on
# its original bytes -> minimize the representatives -> confirm the minimized ones.  The
# expensive step (minimization) runs once per bug, not once per crash.
set -uo pipefail
for kv in "$@"; do case $kv in WORKSPACE=*) export "$kv";; esac; done   # find fuzz.env first
WS=${WORKSPACE:-.}; F_MODES=""; F_CAP=""
if [ -f "$WS/fuzz.env" ]; then
  _m=${MODES:-}; _c=${ALLOC_CAP_MB:-}          # from the caller's environment: kept
  set -a; . "$WS/fuzz.env"; set +a
  F_MODES=${MODES:-}; F_CAP=${ALLOC_CAP_MB:-}; MODES=$_m; ALLOC_CAP_MB=$_c
fi
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
# the sanitized columns need the runtime preloaded; find it the way the harness skill does
if [ -z "${ASAN_RT:-}" ] && [ -n "${R:-}" ] && [ -f "$R/find_asan_rt.sh" ]; then
  rt=$(bash "$R/find_asan_rt.sh" 2>/dev/null) && [ -n "$rt" ] && ASAN_RT=$rt
fi
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-./triage}; WS=${WORKSPACE:-.}
# the confirm script holding the ENTRIES arms: CONFIRM=, else the workspace's copy, else ours
CONFIRM=${CONFIRM:-}; [ -n "$CONFIRM" ] || { CONFIRM="$WS/confirm.mjs"; [ -f "$CONFIRM" ] || CONFIRM="$HERE/confirm.mjs"; }
[ -f "$CONFIRM" ] || { echo "FAIL: CONFIRM=$CONFIRM does not exist" >&2; exit 2; }
CONFIRM="$(cd "$(dirname "$CONFIRM")" && pwd)/$(basename "$CONFIRM")"
for v in $(compgen -v GOOD_); do [ -f "${!v}" ] || { echo "FAIL: $v=${!v} does not exist (relative to $(pwd))" >&2; exit 2; }; done
[ -z "${GOOD:-}" ] || [ -f "$GOOD" ] || { echo "FAIL: GOOD=$GOOD does not exist (relative to $(pwd)). A missing reference input" >&2
                                            echo "      looks 'consistent' at every ceiling and silently disables the guard." >&2; exit 2; }
# What the USER set wins over anything read from the manifest (per-campaign hang timeout,
# RETRY on a low-stability campaign), so remember it before defaulting.
USER_TIMEOUT=${TIMEOUT:-}; USER_RETRY=${RETRY:-}
HARNESS_RE=${HARNESS_RE:-'(^|/)(harness|stubs|afl_shim|covstub)[A-Za-z0-9_.-]*\.(c|cc|cpp|h|hpp)$'}   # smoke.sh's default
TIMEOUT=${TIMEOUT:-5000}; CELL_TIMEOUT=${CELL_TIMEOUT:-30}
mkdir -p "$OUT"
SUM="$OUT/summary.tsv"; : > "$SUM"
UNRES="$OUT/unresolved.tsv"; : > "$UNRES"     # END of each chain: what no configuration reproduced
REPORT="$OUT/REPORT.md"

# Timestamped progress: every phase is stamped so a reader can tell slow from stalled.
T0=$(date +%s)
ts() { printf '[%s +%ds] %s\n' "$(date +%H:%M:%S)" "$(( $(date +%s) - T0 ))" "$*"; }
say() { printf '%s\n' "$*"; }
rule() { say ""; say "========================================================================"; ts "$*"; say "========================================================================"; }

# ---- 1. discover campaigns, and pair each with its harness ----------------------------
# Each campaign starts on the harness of the build that produced it, and whatever does not
# reproduce there is offered to the other builds (see process() for the measured reason).
rule "1. discovering campaigns in $WS"
ts "  confirm script: $CONFIRM"
[ "$CONFIRM" = "$HERE/confirm.mjs" ] && say "    (the plugin's own copy: copy it to $WS/confirm.mjs and fill in ENTRIES there, or pass CONFIRM=)"
harness_for() {  # <variant> -> path to that variant's fork harness, or empty
  local v=$1 c
  for c in "$WS/out/$v/harness-fork" "$WS/out/$v/bin/harness-fork"; do
    [ -x "$c" ] && { echo "$c"; return; }
  done
  # A campaign directory's name is not always a build's: a second run of one build is
  # routinely asan2, and `campaign/asan2/` has no out/asan2/ -- exact-name pairing once
  # skipped the largest crash set in a workspace (111 of 188 files).
  local base=${v%%[0-9]*}
  if [ -n "$base" ] && [ "$base" != "$v" ]; then
    for c in "$WS/out/$base/harness-fork" "$WS/out/$base/bin/harness-fork"; do
      [ -x "$c" ] && { echo "$c"; return; }
    done
  fi
  local all; all=$(find "$WS/out" -maxdepth 3 -name harness-fork -type f -perm -u+x 2>/dev/null)
  [ "$(grep -c . <<<"$all")" = 1 ] && { echo "$all"; return; }
  echo ""
}
probe_harness() {  # <dir> -> the harness that reproduces the most of this dir's inputs
  local d=$1 best="" bestn=-1 h n f rc i
  while read -r h; do
    [ -n "$h" ] || continue
    n=0; i=0
    for f in "$d"/id:* "$d"/*; do
      [ -f "$f" ] || continue; i=$((i+1)); [ "$i" -gt 5 ] && break
      if { timeout 20 "$h" "$f" >/dev/null; } 2>/dev/null; then :; else
        rc=$?; { [ "$rc" -ge 128 ] || [ "$rc" = 86 ]; } && n=$((n+1)); fi
    done
    [ "$n" -gt "$bestn" ] && { bestn=$n; best=$h; }
  done < <(find "$WS/out" -maxdepth 3 -name harness-fork -type f -perm -u+x 2>/dev/null | sort)
  echo "$best"
}
VARIANTS=$(for d in "$WS"/out/*/; do v=$(basename "$d"); [ -n "$(harness_for "$v")" ] && echo "$v"; done | sort -u)

# ---- manifest-driven: the fuzzing skill recorded every campaign, so drive from that ------
# The run-a-fuzzing-campaign skill writes campaigns/manifest.tsv with, per campaign, the
# build variant, the harness MODE it ran under, the confirm.mjs ENTRIES arm that mode maps
# to, the allocation ceiling it used, and its output directory.  Reading it means triage
# needs no hand-supplied MODES, DIRS, ENTRIES or ALLOC_CAP_MB: every one was a guess this
# file exists to remove.  (NO_MANIFEST=1 forces the discovery path below.)
MANIFEST=${MANIFEST:-$WS/campaigns/manifest.tsv}
if [ -f "$MANIFEST" ] && [ -z "${NO_MANIFEST:-}" ]; then
  rule "1. driving from $MANIFEST"
  col() { awk -F'\t' -v c="$1" 'NR==1{for(i=1;i<=NF;i++)if($i==c)k=i} NR>1&&k{print $k}' "$MANIFEST"; }
  # ENTRIES for confirm = every distinct arm the campaigns map to (so the file-mode arm is
  # run), unless the caller pinned ENTRIES.  ALLOC_CAP_MB = the ceiling they screened at.
  [ -n "${ENTRIES:-}" ] || ENTRIES=$(col entry | sed 's/^$/default/' | sort -u | xargs)
  [ -n "${ALLOC_CAP_MB:-}" ] || ALLOC_CAP_MB=$(col alloc_cap_mb | sort -rn | head -1)
  # The non-default harness modes the campaigns ran under, for the crashers/ chain below
  # (a hand-saved crasher carries no campaign, so it is tried under every recorded mode).
  [ -n "${MODES:-}" ] || MODES=$(col mode_env | grep -v '^default$' | sort -u | xargs)
  sel=$(col selftest | sort -u | xargs)
  ts "  entries: $ENTRIES; ceiling: ${ALLOC_CAP_MB:-default} MB; self-test: ${sel:-?}"
  [ "$sel" = passed ] || say "  NOTE: self-test not 'passed' for every campaign ($sel): a clean result is weaker."
  # Collect one plan entry per (campaign row x kind) with crash/hang files; the actual
  # run_one calls happen below, where run_one is defined.  Each entry is
  # "variant|kind|henv|name|alloc_cap|exec_timeout_ms|stability|dir".
  # stability is past the positional columns, so it is read by name.
  declare -A MSTAB
  while IFS=$'\t' read -r n st; do MSTAB[$n]=$st; done < <(paste <(col name) <(col stability))
  MROWS=()
  # non-whitespace separator: IFS=$'\t' would collapse an EMPTY field (a mode row without an :entry)
  while IFS=$'\037' read -r name variant driver harness mode_env entry out_dir mem et map ac rest; do
    [ "$name" = name ] && continue
    henv=""; [ "$mode_env" != default ] && henv="$mode_env"
    for kind in crashes hangs; do
      [ "${SKIP_HANGS:-0}" = 1 ] && [ "$kind" = hangs ] && continue
      d="$WS/$out_dir/default/$kind"
      [ -d "$d" ] && ls "$d" 2>/dev/null | grep -q '^id:' || continue
      MROWS+=("$variant|$kind|$henv|$name|${ac:-$ALLOC_CAP_MB}|$et|${MSTAB[$name]:-}|$d")
      printf '  %-28s %-7s %s\n' "$name" "$kind" "$(ls "$d" | grep -c '^id:') file(s)"
    done
  done < <(tr '\t' '\037' < "$MANIFEST")
  # A campaign that did not run to completion still has real crashes; only the ABSENCE of
  # more is unreliable.  Say so up front.
  badst=$(awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)if($i=="status")k=i} NR>1&&k&&$k!="completed"&&$k!="switched"{printf "%s=%s ",$1,$k}' "$MANIFEST")
  [ -z "$badst" ] || say "  NOTE: campaigns that did not run to completion: $badst"
  # Crash and hang directories on disk that the manifest does NOT list would be silently
  # missed in manifest mode (an interrupted or hand-run campaign, a leftover from an older
  # layout).  List them rather than lose them.
  # smoke/ is the harness skill's smoke run (its own campaigns and manifest), not a
  # campaign to triage: skip it rather than warn about it.
  LISTED=$(printf '%s\n' "${MROWS[@]}" | awk -F'|' '{print $NF}' | sort -u)
  # (the corpus skill's own crashers/ and hangs/ seed directories are triaged below, not campaigns)
  UNLISTED=$(find "$WS" \( -path "$WS/${OUT#./}" -o -path "$WS/smoke" -o -path "$WS/hangs" -o -path "$WS/crashers" \) -prune -o -type d \( -name crashes -o -name hangs \) -print 2>/dev/null | sort | while read -r ud; do
      ls "$ud" 2>/dev/null | grep -q '^id:' || continue
      grep -qxF "$ud" <<<"$LISTED" || echo "$ud"; done)
  if [ -n "$UNLISTED" ]; then
    say "  WARN: $(echo "$UNLISTED" | wc -l) crash/hang director(ies) with files are NOT in the manifest and will not be triaged:"
    echo "$UNLISTED" | sed 's/^/    /'
    say "  Re-run campaign.sh for them, or NO_MANIFEST=1 to triage by discovery instead."
  fi
  # No campaign row with files: crashers/ and hangs/ are still triaged below, and the
  # no-findings report is written only if they leave no bucket either.
  [ ${#MROWS[@]} -gt 0 ] || say "  manifest lists no campaign with crash or hang files; crashers/ and hangs/ are still screened."
  VARIANTS=$(col variant | sort -u | xargs)    # chain only through the builds the manifest lists
  MANIFEST_DRIVEN=1
fi

# "Nothing found" is a result and needs its own facts: what ran, how long, how stable, from
# which seeds, and that the harness was shown to detect an injected fault.  Without them a
# clean campaign cannot be told from a harness that detects nothing (measured: a 10-minute
# campaign found nothing and the old driver wrote no REPORT.md at all).  Scope says what was
# instrumented: a sanitized real-side column over an uninstrumented system library cannot
# see an overflow inside that library, and a report that does not say so is not a result.
no_findings_report() {
  local stl md=$(dirname "$MANIFEST") n df
  stl=$(grep -h -m1 '^PASS:\|^FAIL:' "$WS"/selftest*.txt 2>/dev/null | head -1)
  {
    echo "# Triage findings: none"
    echo
    echo "No campaign in \`$MANIFEST\` saved a crash or a hang. That is a result only as strong"
    echo "as the facts below: a harness proven to detect an injected fault (self-test), run for"
    echo "this long, at this stability, from this corpus. State them with the claim."
    echo
    echo "| campaign | variant | mode | driver | seconds | execs | stability | crashes | hangs | status | self-test | seeds loaded |"
    echo "|---|---|---|---|---|---|---|---|---|---|---|---|"
    paste <(col name) <(col variant) <(col mode_env) <(col driver) \
          <(paste <(col start) <(col stop) | awk -F'\t' '{print ($2 ~ /^[0-9]+$/ && $1 ~ /^[0-9]+$/) ? $2 - $1 : "?"}') \
          <(col execs) <(col stability) \
          <(col crash_files) <(col hang_files) <(col status) <(col selftest) \
          <(paste -d/ <(col seeds_loaded) <(col seeds_total)) \
      | awk -F'\t' '{printf "| %s |", $1; for (i = 2; i <= NF; i++) printf " %s |", $i; print ""}'
    echo
    echo "Self-test: ${stl:-NOT FOUND -- without a passing self-test this is not a negative result}"
    [ -n "$badst" ] && echo "Campaigns that did not run to completion: $badst"
    [ -n "$UNLISTED" ] && echo "Crash/hang directories NOT in the manifest (not triaged): $(echo "$UNLISTED" | xargs)"
    [ -n "$CRASHERS$HANGSEEDS" ] && echo "Hand-saved inputs ($(echo ${CRASHERS:+crashers/} ${HANGSEEDS:+hangs/})) screened on every variant and mode: none reproduced$([ -s "$UNRES" ] && echo "; see \`$UNRES\`")."
    echo
    echo "## Scope"
    echo
    echo "* Variants: $(col variant | sort -u | xargs)"
    echo "* Modes, and the entry each confirms through: $(paste <(col mode_env) <(col entry) | sort -u \
          | awk -F'\t' '{printf "%s%s -> %s", s, $1, ($2 == "" ? "default" : $2); s = ", "}')"
    echo "* Campaign durations: $(paste <(col name) <(col start) <(col stop) \
          | awk -F'\t' '{printf "%s%s %ss", s, $1, ($2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/) ? $3 - $2 : "?"; s = ", "}')"
    echo "* Seeds loaded: $(paste <(col name) <(col seeds_loaded) <(col seeds_total) \
          | awk -F'\t' '{printf "%s%s %s/%s", s, $1, ($2 == "" ? "?" : $2), $3; s = ", "}')"
    for n in $(col name); do
      df="$md/$n.dropped"; [ -s "$df" ] || continue
      awk -F'\t' -v n="$n" '{printf "  * %s did not fuzz `%s`: %s\n", n, $1, $2}' "$df"
    done
    echo "* Instrumented: <state here what was instrumented and what the real side's sanitized column can and cannot see>"
    echo "* Not covered: <the public API calls these modes correspond to, and the ones not fuzzed>"
  } > "$REPORT"
}

# fuzz.env's modes (gate.sh spelling: drop the :options) and ceiling, below the manifest's
[ -n "${MODES:-}" ] || MODES=$(for m in $F_MODES; do printf '%s\n' "${m%%:*}"; done | xargs)
[ -n "${ALLOC_CAP_MB:-}" ] || ALLOC_CAP_MB=$F_CAP
declare -A CAMPAIGNS                                   # "variant kind" -> space-separated dirs
while [ -z "${MANIFEST_DRIVEN:-}" ] && read -r d; do
  [ -n "$d" ] || continue
  kind=$(basename "$d")                                # crashes | hangs
  n=$(ls "$d" 2>/dev/null | grep -vc '^README'); [ "${n:-0}" -gt 0 ] || continue
  v=$(sed -n 's#.*/\(out\|campaign[^/]*\|hunt\|bench\|fuzzout\)/\([^/]*\)/.*#\2#p' <<<"/${d#./}/" | head -1)
  CAMPAIGNS["${v:-unknown} $kind"]="${CAMPAIGNS["${v:-unknown} $kind"]:-} $d"
done < <(find "$WS" \( -path "$WS/${OUT#./}" -o -path "$WS/hangs" \) -prune -o -type d \( -name crashes -o -name hangs \) -print 2>/dev/null | sort)
# The corpus skill's seed-policy directories: crashers/ (seeds that crash the sanitized harness)
# and hangs/ (seeds over its timeout).  Neither carries a variant, so both are screened against
# every variant, then under every recorded mode.
CRASHERS=""; [ -d "$WS/crashers" ] && [ -n "$(ls "$WS/crashers" 2>/dev/null)" ] && CRASHERS="$WS/crashers"
HANGSEEDS=""; [ -d "$WS/hangs" ] && [ -n "$(ls "$WS/hangs" 2>/dev/null)" ] && [ "${SKIP_HANGS:-0}" != 1 ] && HANGSEEDS="$WS/hangs"

if [ -z "${MANIFEST_DRIVEN:-}" ] && [ "${#CAMPAIGNS[@]}" = 0 ] && [ -z "$CRASHERS" ] && [ -z "$HANGSEEDS" ]; then
  say "No crashes/ or hangs/ with files anywhere under $WS."
  say "That is a reportable result ONLY with the harness skill's detection self-test beside"
  say "it: 'found nothing' and 'detects nothing' produce identical output."
  exit 0
fi
if [ -z "${MANIFEST_DRIVEN:-}" ]; then for k in "${!CAMPAIGNS[@]}"; do
  set -- ${CAMPAIGNS[$k]}; v=${k% *}; kind=${k#* }
  h=$(harness_for "$v")
  printf '  %-10s %-8s %2d dir(s)  harness: %s\n' "$v" "$kind" "$#" "${h:-(will probe)}"
done; fi
[ -n "$CRASHERS" ] && say "  crashers/  screened against every variant: $(echo $VARIANTS)"
[ -n "$HANGSEEDS" ] && say "  hangs/     screened (as hangs) against every variant: $(echo $VARIANTS)"
[ -n "${MODES:-}" ] && say "  non-reproducers are re-screened under: $MODES"
# No pristine build: the confirm column that rules out an instrumentation artifact stays
# empty, and in every evaluation run nothing earlier said to build it.
HAVE_CRASH=""
[ -n "$CRASHERS" ] && HAVE_CRASH=1
for r in "${MROWS[@]:-}"; do case $r in *"|crashes|"*) HAVE_CRASH=1;; esac; done
for k in "${!CAMPAIGNS[@]}"; do case $k in *" crashes") HAVE_CRASH=1;; esac; done
PRISTINE_TODO="build the pristine variant (the harness skill's build_addon.sh VARIANT=pristine plus link_harness.sh VARIANT=pristine) and re-run confirm to earn the 'reproduces without instrumentation' sentence"
NEED_PRISTINE=""; [ -n "$HAVE_CRASH" ] && [ ! -d "$WS/out/pristine" ] && [ -z "${PRISTINE:-}" ] && NEED_PRISTINE=1
[ -n "$NEED_PRISTINE" ] && say "  NOTE: no out/pristine/: $PRISTINE_TODO."

# ---- 2. minimize + bucket ----------------------------------------------------------------
LAST_NONREPRO=""
run_one() {  # <build variant> <kind> <harness env or ""> <source tag or ""> <dirs...>  -> sets LAST_NONREPRO
  local v=$1 kind=$2 henv=$3 src=$4; shift 4
  LAST_NONREPRO=""
  local fork; fork=$(harness_for "$v")
  if [ -z "$fork" ]; then
    fork=$(probe_harness "$1")                 # last resort: whichever reproduces most
    [ -n "$fork" ] && say "  $v/$kind: no out/$v/ build; probed and chose $fork"
  fi
  [ -n "$fork" ] || { say "  SKIP $v/$kind: no harness-fork found under $WS/out."; return; }
  # A chained run is named after the campaign it CAME FROM plus the build it ran on
  # (plain-crashes.on-asan), never just "<build>-<kind>": that is a real campaign's output
  # directory, and minimize.sh wipes its OUT on start.
  # A manifest campaign's name already carries its mode (asan@MODE=2); appending the mode
  # again gave `asan@MODE=2@MODE=2@MODE=2`.  Only a name built here gets the suffix.
  local tag="${TAG_OVERRIDE:-}" named=0
  if [ -n "$tag" ]; then named=1
  else tag="${src:-$v-$kind}"; [ -n "$src" ] && [ "$src" != "$v-$kind" ] && tag="$src.on-$v"; fi
  unset TAG_OVERRIDE   # consumed; must not carry to the next campaign
  [ -n "$henv" ] && [ "$named" = 0 ] && tag="$tag@$(tr -c 'A-Za-z0-9=' _ <<<"$henv" | sed 's/_*$//')"
  local o="$OUT/$tag"
  rule "2. $tag  ->  $o"
  local hargs=(); [ "$kind" = hangs ] && hargs=(HANGS=1)
  [ -n "$henv" ] && hargs+=(HARNESS_ENV="$henv")
  # A manifest campaign's hangs were judged at its own exec timeout (CAMP_HANG_MS, set per
  # campaign below); screen them there, not at the generic default.
  local tmo=$TIMEOUT
  if [ "$kind" = hangs ] && [ -n "${CAMP_HANG_MS:-}" ]; then
    tmo=$CAMP_HANG_MS; hargs+=(EXEC_PAD_S="${HANG_PAD_S:-1}")
  fi
  mkdir -p "$o"
  bash "$HERE/screen.sh" FORK="$fork" DIRS="$*" OUT="$o" TIMEOUT="$tmo" "${hargs[@]}" \
      ${RETRY:+RETRY="$RETRY"} ${ALLOC_CAP_MB:+ALLOC_CAP_MB="$ALLOC_CAP_MB"} \
      ${CAP_LADDER:+CAP_LADDER="$CAP_LADDER"} ${CAP_UP:+CAP_UP="$CAP_UP"} ${GOOD:+GOOD="$GOOD"} \
      2>&1 | tee "$o/screen.out" | sed -u 's/^/    /'
  local mrc=${PIPESTATUS[0]}
  [ -n "$(ls "$o/nonrepro" 2>/dev/null)" ] && LAST_NONREPRO="$o/nonrepro"
  [ "$mrc" = 0 ] || { say "    (nothing to bucket for $tag)"; return; }
  # Label with the sanitized build when there is one: only it prints a SUMMARY line, and
  # that line is the bucket key; bucket.sh falls back to $fork per input.
  # (any SANITIZED fork harness, found by looking in the binary -- the build is not always named asan)
  local lab; lab=$(harness_for asan)
  [ -n "$lab" ] && grep -qa '__asan_report_load' "$lab" || lab=$(find "$WS/out" -maxdepth 3 -name harness-fork -type f -perm -u+x 2>/dev/null \
                                                              | while read -r h; do grep -qa '__asan_report_load' "$h" && { echo "$h"; break; }; done)
  [ -n "$lab" ] || lab=$fork
  echo "LABEL_FORK=$lab" >> "$o/config"            # minimize.sh's drift check keys with it too
  # tee BEFORE the indenting sed, so bucketing progress is live (it used to be replayed
  # after the fact) and bucket.out stays unindented for the key extraction below.
  bash "$HERE/bucket.sh" FORK="$fork" LABEL_FORK="$lab" OUT="$o" CELL_TIMEOUT="$CELL_TIMEOUT" \
      ${ALLOC_CAP_MB:+ALLOC_CAP_MB="$ALLOC_CAP_MB"} 2>&1 | tee "$o/bucket.out" | sed -u 's/^/    /'
  local b key
  for b in "$o/buckets"/*; do
    [ -f "$b" ] || continue
    key=$(grep -F "$(basename "$b" | cut -c1-6)" "$o/bucket.out" | head -1 \
          | sed 's/^ *[0-9a-f]\{6\} *[0-9]* B *[^ ]* *//')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${src:-$v-$kind}" "$v" "${henv:--}" "$(wc -c <"$b")" "${b#$OUT/}" "${key:-?}" "$o" >> "$SUM"
  done
}
# Run one campaign on its own build, then chain whatever did not reproduce through the
# OTHER variants and then each MODES setting -- each step sees only the previous step's
# non-reproducers, so nothing is minimized twice.
#
# Why the other variants: measured over 161 real crashes, the variant risk runs ONE way.
# An ASAN campaign's crashes on the plain build: 0 of 111 reproduce (1-2 byte over-reads
# are invisible without the sanitizer).  A plain campaign's crashes on the ASAN build:
# 13 of 13 (a stylesheet-compiler binding) and 25 of 25 (an image-decoding binding) -- plus
# 2 of the image-decoding binding's crashes that ONLY the ASAN
# build reproduces.  Not one input crashed the plain build alone.  So pairing a plain
# campaign with the plain harness and stopping there lost those 2.
# Manifest mode passes the campaign's own mode (henv), its name, and a tag base so every
# chained run gets a readable explicit tag (TAG_OVERRIDE) instead of re-appending the mode.
process() {  # <variant> <kind> <henv> <campaign name or ""> <dirs...>
  local v=$1 kind=$2 henv=$3 name=$4; shift 4
  local src="${name:-$v-$kind}"
  # One campaign's crashes and hangs need separate run directories: under the bare name
  # the hangs run wiped the crashes run (screen.sh clears its OUT).
  local nm=$name; [ -n "$name" ] && [ "$kind" = hangs ] && nm="$name.hangs"
  TAG_OVERRIDE=${nm:+$nm} run_one "$v" "$kind" "$henv" "$src" "$@"
  local rest=$LAST_NONREPRO m ov mt
  for ov in $VARIANTS; do
    [ -n "$rest" ] || break
    [ "$ov" = "$v" ] || [ "$ov" = "${v%%[0-9]*}" ] && continue
    ts "  $(ls "$rest" | wc -l) input(s) did not reproduce on $v; re-screening them on $ov"
    TAG_OVERRIDE=${nm:+$nm.on-$ov} run_one "$ov" "$kind" "$henv" "$src" "$rest"
    rest=$LAST_NONREPRO
  done
  for m in ${MODES:-}; do
    [ -n "$rest" ] || break
    [ "$m" = "$henv" ] && continue                     # that is the campaign's own mode
    mt=$(tr -c 'A-Za-z0-9=' _ <<<"$m" | sed 's/_*$//')
    ts "  $(ls "$rest" | wc -l) input(s) still do not reproduce; re-screening them under $m"
    TAG_OVERRIDE=${nm:+$nm.under-$mt} run_one "$v" "$kind" "$m" "$src" "$rest"
    rest=$LAST_NONREPRO
  done
  if [ -n "$rest" ]; then
    ts "  $(ls "$rest" | wc -l) input(s) of $v/$kind reproduce in no configuration tried: $rest"
    printf '%s\t%s\t%s\n' "$v/$kind" "$(ls "$rest" | wc -l)" "${rest#$OUT/}" >> "$UNRES"
    [ -z "${MODES:-}" ] && [ -z "${MANIFEST_DRIVEN:-}" ] && say "    if the harness reads a mode variable (MODE=, HARNESS_MODE=), pass MODES=..."
  fi
}

if [ -n "${MANIFEST_DRIVEN:-}" ]; then
  # Each campaign starts on its own build and mode, then its non-reproducers are chained
  # through the other manifest variants and modes (process).  ASAN-only inputs exist (a
  # plain campaign's crash that only the ASAN build reproduces), so reproduction is
  # one-directional and "not in its own configuration" does not mean "a non-reproducer".
  for row in "${MROWS[@]}"; do
    IFS='|' read -r v kind henv name ac et stab d <<<"$row"
    [ -n "${ONLY:-}" ] && ! grep -qw "$v" <<<"$ONLY" && continue
    # Per campaign, from the manifest, unless the user set them: the hang threshold (its
    # exec_timeout_ms, in ms like TIMEOUT) and RETRY=5 when its stability was below 90 %.
    chm=""; crt=${USER_RETRY:-}
    if [ "$kind" = hangs ] && [ -z "$USER_TIMEOUT" ] && [ "${et:-0}" -gt 0 ] 2>/dev/null; then
      chm=$(( et * ${HANG_MULT:-2} ))
      ts "  $name: hangs screened at ${HANG_MULT:-2} x exec_timeout_ms ${et} = ${chm} ms (+${HANG_PAD_S:-1} s start-up), from the manifest"
    fi
    if [ -z "$USER_RETRY" ] && [ -n "$stab" ] && awk -v s="$stab" 'BEGIN{exit !(s+0 < 90)}'; then
      crt=5; ts "  $name: stability ${stab}% < 90%: RETRY=5 for this campaign, from the manifest"
    fi
    CAMP_HANG_MS="$chm" RETRY="$crt" ALLOC_CAP_MB="$ac" process "$v" "$kind" "$henv" "$name" "$d"
  done
else
for k in "${!CAMPAIGNS[@]}"; do
  v=${k% *}; kind=${k#* }
  [ "${SKIP_HANGS:-0}" = 1 ] && [ "$kind" = hangs ] && continue
  [ -n "${ONLY:-}" ] && ! grep -qw "$v" <<<"$ONLY" && continue
  process "$v" "$kind" "" "" ${CAMPAIGNS[$k]}
done
fi
# crashers/ carries no variant in its path: run it against EVERY variant, each run getting
# only what the previous ones could not reproduce, then through MODES.
if [ -n "$CRASHERS" ] && [ -z "${ONLY:-}" ]; then
  rest=$CRASHERS
  for v in $VARIANTS; do
    [ -n "$rest" ] || break
    run_one "$v" crashers "" "crashers" "$rest"; rest=$LAST_NONREPRO
  done
  first_v=$(echo $VARIANTS | awk '{print $1}')
  for m in ${MODES:-}; do
    [ -n "$rest" ] || break
    run_one "$first_v" crashers "$m" "crashers" "$rest"; rest=$LAST_NONREPRO
  done
  if [ -n "$rest" ]; then
    ts "  $(ls "$rest" | wc -l) crasher(s) reproduce in no configuration tried: $rest"
    printf '%s\t%s\t%s\n' "crashers" "$(ls "$rest" | wc -l)" "${rest#$OUT/}" >> "$UNRES"
  fi
fi
if [ -n "$HANGSEEDS" ] && [ -z "${ONLY:-}" ]; then
  rest=$HANGSEEDS
  for v in $VARIANTS; do
    [ -n "$rest" ] || break
    TAG_OVERRIDE="hangseeds.on-$v" run_one "$v" hangs "" "hangs" "$rest"; rest=$LAST_NONREPRO
  done
  if [ -n "$rest" ]; then
    ts "  $(ls "$rest" | wc -l) hang seed(s) hang in no configuration tried: $rest"
    printf '%s\t%s\t%s\n' "hangs" "$(ls "$rest" | wc -l)" "${rest#$OUT/}" >> "$UNRES"
  fi
fi

if [ -n "${MANIFEST_DRIVEN:-}" ] && [ ${#MROWS[@]} -eq 0 ] && [ ! -s "$SUM" ]; then
  rule "no findings: writing $REPORT"
  no_findings_report
  ts "  wrote $REPORT (no bucket; fill in its Scope lines)"
  exit 0
fi

# ---- 3. confirm the representatives, on their ORIGINAL bytes --------------------------
# Before minimization, for two reasons: it is cheap (about 0.1 s per node run, the same as
# the bare harness), and original bytes are the safer test -- an image-decoding binding's GIF bug reads CLEAN
# on the npm install once minimized and crashes it only as the original.  The verdicts
# RANK the buckets; they never remove one.  A node CLEAN means "not reachable through the
# ENTRIES arms written so far", and those arms are the part that gets things wrong.
disc() { find "$WS/out/$1" -name '*.node' -not -path '*obj.target*' 2>/dev/null | head -1; }
A=${ADDON:-${ADDON_ASAN:-${EXT_ASAN:-$(disc asan)}}}; P=${PRISTINE:-$(disc pristine)}
confirm_dir() {  # <dir> <buckets dir> <verdicts file> <output file>
  bash "$HERE/confirm.sh" OUT="$1" BUCKETS="$2" VERDICTS="$3" PKG="$PKG" CELL_TIMEOUT="$CELL_TIMEOUT" CONFIRM="$CONFIRM" \
      ${A:+ADDON="$A"} ${P:+PRISTINE="$P"} ${ASAN_RT:+ASAN_RT="$ASAN_RT"} \
      ${GOOD:+GOOD="$GOOD"} ${ENTRIES:+ENTRIES="$ENTRIES"} ${ALLOC_CAP_MB:+ALLOC_CAP_MB="$ALLOC_CAP_MB"} \
      ${ADDON_MATCH:+ADDON_MATCH="$ADDON_MATCH"} ${ADDON_MAP:+ADDON_MAP="$ADDON_MAP"} \
      ${PRISTINE_MAP:+PRISTINE_MAP="$PRISTINE_MAP"} \
      2> >(sed -u 's/^/    /' >&2) | tee "$4" | sed -u 's/^/    /'
}
if [ -n "${PKG:-}" ]; then
  for d in "$OUT"/*/; do
    d=${d%/}; [ -n "$(ls "$d/buckets" 2>/dev/null)" ] || continue
    rule "3. confirm $(basename "$d") (original bytes) against $PKG"
    confirm_dir "$d" "$d/buckets" "$d/verdicts.tsv" "$d/confirm.out"
  done
else
  rule "3. confirm: SKIPPED"
  say "  No PKG given, so nothing was confirmed against the real package -- and the"
  say "  confirm step is the only one that answers whether a crash reaches a user."
  say "  Fill in the ENTRIES arms in $CONFIRM, npm install the pinned version,"
  say "  and re-run with PKG=<that>/node_modules/<pkg> GOOD=<a reference input>."
fi

# ---- 4. minimize the representatives only ------------------------------------------------
# A representative that is CLEAN on every column of every entry point keeps its original
# bytes (MINIMIZE_ALL=1 to minimize it anyway): it stays in the report, it just does not
# earn the expensive step.  Everything else is minimized.
clean_everywhere() {  # <verdicts file> <bucket name> -> 0 if no cell is a finding
  awk -F'\t' -v n="$2" '$1==n{for(i=3;i<=5;i++) if($i!="CLEAN" && $i !~ /^\(no /) bad=1; seen=1}
                         END{exit !(seen && !bad)}' "$1"
}
for d in "$OUT"/*/; do
  d=${d%/}; [ -n "$(ls "$d/buckets" 2>/dev/null)" ] || continue
  reps="$d/.reps"; rm -rf "$reps"; mkdir -p "$reps"; skipped=0
  for b in "$d/buckets"/*; do
    if [ -n "${PKG:-}" ] && [ "${MINIMIZE_ALL:-0}" != 1 ] && clean_everywhere "$d/verdicts.tsv" "$(basename "$b")"; then
      skipped=$((skipped+1)); continue
    fi
    cp "$b" "$reps/"
  done
  rule "4. minimize $(basename "$d"): $(ls "$reps" | wc -l) representative(s)$([ "$skipped" -gt 0 ] && echo ", $skipped CLEAN everywhere kept as original")"
  [ -n "$(ls "$reps")" ] || { rm -rf "$reps"; continue; }
  bash "$HERE/minimize.sh" OUT="$d" REPS="$reps" ${USER_TIMEOUT:+TIMEOUT="$USER_TIMEOUT"} ${HANG_S:+HANG_S="$HANG_S"} \
      ${ALLOC_CAP_MB:+ALLOC_CAP_MB="$ALLOC_CAP_MB"} 2>&1 | tee "$d/minimize.out" | sed -u 's/^/    /'
  rm -rf "$reps"
  # The minimized reproducer is what a reader runs, so confirm IT too: shrinking happened
  # against the harness's redzones and can stop reaching far enough to fault the release
  # build.  confirm.sh falls back to the original bytes and says so: CLEAN->...(orig).
  if [ -n "${PKG:-}" ] && [ -n "$(ls "$d/min" 2>/dev/null)" ]; then
    rule "4b. confirm the minimized reproducers of $(basename "$d")"
    confirm_dir "$d" "$d/min" "$d/verdicts.min.tsv" "$d/confirm.min.out"
  fi
done

# ---- 4. report skeleton ----------------------------------------------------------------
# minimize.sh's key for <min>/<name>.key is bucket.sh's key without the line and the access;
# compare in that form.  DRIFT: the minimized bytes reach another bug than the bucket's.
norm_key() { sed -E -e 's/ \[(READ|WRITE)(-[0-9]+)?\]$//' -e 's/^([A-Za-z-]+ @ [^ ]*):[0-9?]+ in /\1 in /' <<<"$1"; }
min_key_cell() {  # <bucket key> <key file> -> table cell
  [ -f "$2" ] || { echo "-"; return; }
  local mk; mk=$(head -1 "$2")
  case $mk in "("*) echo "$mk"; return;; esac
  if [ "$mk" = "$(norm_key "$1")" ]; then echo "$mk"; else echo "**DRIFT** $mk"; fi
}
copied_code() {  # <bucket key> -> 0 when its file is one of the harness's own sources
  local f; f=$(sed -n 's/^[^ ]* @ \([^ :]*\):.*/\1/p' <<<"$1")
  [ -n "$f" ] && grep -qE "$HARNESS_RE" <<<"$f"
}
NDRIFT=0; NCOPIED=0
if [ -s "$SUM" ]; then
  while IFS=$'\t' read -r from on henv sz b key o; do
    n=$(basename "$b")
    case $(min_key_cell "$key" "$o/min/$n.key") in "**DRIFT**"*) NDRIFT=$((NDRIFT+1)); say "  WARN: ${b#$OUT/}: the minimized reproducer's key differs from the bucket's (DRIFT); report the original bytes";; esac
    copied_code "$key" && NCOPIED=$((NCOPIED+1))
  done < "$SUM"
fi
rule "4. $REPORT"
{
  say "# Triage findings"
  say ""
  say "Workspace \`$WS\`. One row per BUCKET (exact sanitizer key); merge rows that differ"
  say "only in line number inside one function before reporting -- bucket.out prints that"
  say "merged grouping, and a grouping on the caller below the crashing function."
  say "Severity is yours to judge (skill step 4); this file has the facts."
  say ""
  say "| from campaign | reproduced on | harness mode | bucket key | original | minimized | minimized key | worst verdict (original / minimized) | memory amplification | note |"
  say "|---|---|---|---|---|---|---|---|---|---|"
  worst() {  # <verdicts file> <name> -> most severe cell over all entries and columns
    awk -F'\t' -v n="$2" 'function r(v){ if(v~/NATIVE/)return 6; if(v~/UNCAUGHT/)return 5; if(v~/HANG/)return 4;
        if(v~/CAUGHT/)return 3; if(v~/ERROR|ADDON-|SKIPPED/)return 2; if(v~/CLEAN/)return 1; return 0 }
      $1==n{for(i=3;i<=5;i++) if(r($i)>best){best=r($i); w=$i}} END{print (w==""?"-":w)}' "$1" 2>/dev/null
  }
  if [ -s "$SUM" ]; then
    sort -t$'\t' -k1,1 -k2,2 -k3,3 "$SUM" | while IFS=$'\t' read -r from on henv sz b key o; do
      n=$(basename "$b"); pn=${n#??????-}
      msz="-"; [ -f "$o/min/$n" ] && msz="$(wc -c <"$o/min/$n") B"
      vo=$(worst "$o/verdicts.tsv" "$n"); vm=$(worst "$o/verdicts.min.tsv" "$n")
      amp=$(cat "$o/amplification.min.tsv" "$o/amplification.tsv" 2>/dev/null \
            | awk -F'\t' -v n="$pn" '$1==n{printf "%s B in, %s B demanded, %sx at %s MB", $2, $3, $4, $5; exit}')
      mk=$(min_key_cell "$key" "$o/min/$n.key")
      note="-"; copied_code "$key" && note="copied code: see the copy's source comment for the package line"
      say "| $from | $on | $henv | $key | \`${b#$OUT/}\` $sz B | $msz | $mk | $vo / $vm | ${amp:--} | $note |"
    done
  else
    say "| — | — | — | nothing survived screening | — | — | — | — | — | — |"
  fi
  say ""
  say "## Did not reproduce in any configuration tried"
  say ""
  # Only the END of each chain: a run whose non-reproducers a later mode or variant picked
  # up is superseded by that later run's own nonrepro/.
  if [ -s "$UNRES" ]; then
    while IFS=$'\t' read -r what n dir; do
      say "* $what: $n input(s) in \`$dir\` -- tried: variants $(echo $VARIANTS), default mode${MODES:+, $MODES}"
    done < "$UNRES"
  else
    say "_none_"
  fi
  say ""
  say "## Confirm tables"
  say ""
  for f in "$OUT"/*/confirm.out "$OUT"/*/confirm.min.out; do
    [ -f "$f" ] || continue
    say "### $(basename "$(dirname "$f")") -- $( [ "${f##*/}" = confirm.out ] && echo original bytes || echo minimized)"
    say ""; say '```'; cat "$f"; say '```'; say ""
  done
  [ -n "${PKG:-}" ] || { say "_Not confirmed: no PKG given. Nothing here says whether a user is affected._"; say ""; }
  say "## Still to do by hand"
  say ""
  say "* Merge buckets that differ only in line number inside one function. When bucket.out's"
  say "  'merged on caller' grouping collapses several functions into one, judge whether that is the bug."
  [ "$NDRIFT" -gt 0 ] && say "* $NDRIFT row(s) marked DRIFT: the minimized bytes reach a different bug; report the original bytes for them."
  [ "$NCOPIED" -gt 0 ] && say "* $NCOPIED row(s) keyed in the harness's copied code: map each harness line to the package line through the copy's source comment."
  [ -n "$NEED_PRISTINE" ] && say "* No pristine build: $PRISTINE_TODO."
  say "* Severity per row, and the npm entry point a reader should use (a harness mode"
  say "  usually corresponds to one)."
  say "* \`od -An -tx1\` the reproducer bytes inline for each native crash."
  say "* For a hang: say whether the BARE HARNESS hangs (native code loops; no consumer-side"
  say "  mitigation for a sync call) or only the node stack does, and the budget you allowed."
  say "* For a \`NO-REPORT signal-only\` bucket: check for stack exhaustion; record \`ulimit -s\`."
  say "* For an \`out-of-memory\` bucket: quote the amplification and the ceiling."
  say "* Hang buckets are keyed by stack sampling and are approximate: a loop inside an"
  say "  interpreter's recursive walk can land in a coarser bucket on another run."
  say "* Anything listed under 'did not reproduce' was tried on every build variant and every"
  say "  MODES setting; most such inputs are persistent-mode artifacts (10 of 37 on an image-decoding binding)."
  say "  Name the configurations tried before calling it an artifact."
  say "* If nothing was confirmed, cite the harness skill's detection self-test."
} > "$REPORT"
ts "  wrote $REPORT ($(wc -l < "$SUM") bucket row(s))"
say ""
say "Buckets by campaign:"
[ -s "$SUM" ] && awk -F'\t' '{printf "  %-16s on %-7s %-8s %5s B  %s\n", $1, $2, $3, $4, $6}' "$SUM" || say "  (none)"
