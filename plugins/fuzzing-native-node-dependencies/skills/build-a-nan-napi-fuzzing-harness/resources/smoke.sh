#!/bin/bash
# Smoke-test a freshly built harness BEFORE the real campaign: run it briefly and decide
# whether anything crashes on the HARNESS'S account rather than the library's.
#
# The gate (step 5) compares the harness with the real stack on the gate corpus, which is
# mostly valid input, so it never reaches the error paths where a harness is most likely
# wrong.  On an image-decoding binding, a `memset`-zeroed C++ object made every decode
# error crash inside `std::string` -- 43 phantom SIGSEGVs in 15 seconds of fuzzing, none of them seen by the
# gate.  A short run finds that in seconds; discovering it after a 10-minute campaign, in a
# pile of 70 crashes, costs the whole campaign.
#
#   resources/smoke.sh [WORKSPACE=.] [SMOKE_S=30] [MODES="MODE=file MODE=string"] \
#       HOSTSAN="env LD_PRELOAD=$(resources/find_asan_rt.sh) PKG=<oracle>/node_modules/<pkg> \
#                ADDON=/abs/fuzz/out/asan/Release/<name>.node node real_harness.mjs"
#
# Phases:
#   A  every seed through every variant's fork harness, sanitized or not: a seed that
#      crashes or hangs it is listed
#   0  (before any fuzzing) HOSTSAN, when given, runs once on a seed no harness crashed on
#      and must print a result line (status=...); a broken real-side command would
#      otherwise turn every crash into DIRECT-ONLY
#   B  a short afl-fuzz run per variant (campaign.sh, in smoke/, with SELFTEST=skip: the
#      smoke test is about the harness itself and runs BEFORE the detection self-test):
#      execs/s over the measured fuzz time, and stability.  At least one campaign must be
#      `completed` or `walled`, and none `aborted` or `failed`, or nothing was smoked
#   C  every crash that run saved, classified (below)
#   D  one verdict and an exit status
#
# Classes, per crash (grouped by site in the report):
#   REAL            crashes the direct harness AND the real stack (HOSTSAN) -- a library
#                   bug, good.  When the innermost project frame is in the harness's own
#                   files it is tagged "(frame in copied code)": the harness carries a copy
#                   of a package method body or static helper, and the bug is in that copy's
#                   original.  Checked BEFORE the harness-frame test for that reason.
#   HARNESS-FRAME   does NOT reproduce on the real stack (or HOSTSAN was not given), and
#                   the innermost frame in project source is in the harness's own code
#                   (harness*, stubs*, afl_shim*, covstub*): a stub, a placement-new, the
#                   input handling -- fix the harness
#   DIRECT-ONLY     crashes the direct harness but NOT the real stack, on an input the
#                   API can express: the harness reaches code, or builds state, the real
#                   stack does not -- fix the harness (gate step 5 / four-layers.md)
#   OUT-OF-SCOPE    as DIRECT-ONLY but the input cannot pass through a JS string (invalid
#                   UTF-8, a NUL): legitimate, not a harness bug (STRING_API=1)
#   UNVERIFIED      no HOSTSAN, and the frame is not in the harness: cannot be decided
#   PERSISTENT-ONLY does not reproduce through the fork harness but DOES reproduce in a
#                   single-shot run of the persistent binary (same source, compiled without
#                   -DNO_PERSISTENT, so only the memory layout differs: the shared-memory
#                   testcase buffer and the persistent-mode globals).  Not iteration state,
#                   and not a harness frame: a layout-dependent bug such as an uninitialised
#                   read in the library, or an instrumentation artefact.  A warning, with the
#                   sanitizer site: hand it to triage with the persistent binary named
#   STATE           reproduces through neither binary single-shot: the persistent harness
#                   carried state between iterations.  Some is expected; a lot means the
#                   fork driver, or a leak/reset to fix
#
# Exit status: 0 nothing is the harness's fault; 1 HARNESS-FRAME or DIRECT-ONLY crashes;
# 2 the smoke test itself could not run or fuzzed nothing (no corpus, no campaign.sh, a
# broken HOSTSAN, no completed/walled campaign, an aborted/failed campaign).
#
# Configure with KEY=VALUE arguments or environment:
#   WORKSPACE  the fuzz workspace (default .)
#   VARIANTS   builds to smoke (default: every out/<v>/ with an AFL-instrumented fork harness)
#   MODES      harness settings to smoke BESIDES the default, campaign.sh's spelling
#              ("MODE=file MODE=string"): one short campaign per variant per mode, each
#              recorded with its mode_env, and every seed and crash replayed under it
#   CORPUS     seeds (default ./corpus)
#   SMOKE_S    seconds of fuzzing per variant (default 30)
#   HOSTSAN    command for the real stack under the sanitizer; the input path is appended.
#              The differential needs it: without it a crash can only be called UNVERIFIED
#              (or HARNESS-FRAME, which then cannot be told from a bug in copied code).
#   STRING_API=1   the API takes a JS string: classify non-UTF-8 / NUL inputs OUT-OF-SCOPE
#   HARNESS_RE regex for the harness's own source files
#   (a variant built without the sanitizer has no stack of its own; its crashes are re-run
#    on the first sanitized variant to get one, so the harness-frame check still works)
#   MIN_EPS    warn below this many execs/s (default 100); MIN_STAB below this stability %
#              (default 90)
#   CAMPAIGNER path to run-a-fuzzing-campaign's campaign.sh
#   ALLOC_CAP_MB   memory ceiling (default 1024), as everywhere else
set -uo pipefail
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
HERE=$(cd "$(dirname "$0")" && pwd)
WS=${WORKSPACE:-.}; WS=$(cd "$WS" && pwd); cd "$WS" || exit 2
SMOKE_S=${SMOKE_S:-30}; MIN_EPS=${MIN_EPS:-100}; MIN_STAB=${MIN_STAB:-90}; MODES=${MODES:-}
CORPUS=${CORPUS:-$WS/corpus}; ALLOC_CAP_MB=${ALLOC_CAP_MB:-1024}
HARNESS_RE=${HARNESS_RE:-'(^|/)(harness|stubs|afl_shim|covstub)[A-Za-z0-9_.-]*\.(c|cc|cpp|h|hpp)$'}
CAMPAIGNER=${CAMPAIGNER:-$HERE/../../run-a-fuzzing-campaign/resources/campaign.sh}
T0=$(date +%s)
ts() { printf '[%s +%ds] %s\n' "$(date +%H:%M:%S)" "$(( $(date +%s) - T0 ))" "$*"; }
hfork() { for p in "$WS/out/$1/harness-fork" "$WS/out/$1/bin/harness-fork"; do [ -x "$p" ] && { echo "$p"; return; }; done; }
hbin()  { for p in "$WS/out/$1/harness" "$WS/out/$1/bin/harness"; do [ -x "$p" ] && { echo "$p"; return; }; done; }
instrumented() { grep -qa '__afl_area_ptr\|__afl_coverage' "$1" 2>/dev/null; }
# ---- preconditions: everything that can make the run meaningless, checked BEFORE it ----
[ -d "$CORPUS" ] || { echo "FAIL: no corpus at $CORPUS (pass CORPUS=)" >&2; exit 2; }
[ -f "$CAMPAIGNER" ] || { echo "FAIL: campaign.sh not found at $CAMPAIGNER (set CAMPAIGNER=)" >&2; exit 2; }
if [ -z "${VARIANTS:-}" ]; then
  VARIANTS=$(for d in "$WS"/out/*/; do v=$(basename "$d"); f=$(hfork "$v"); [ -n "$f" ] && instrumented "$f" && echo "$v"; done | xargs)
fi
[ -n "$VARIANTS" ] || { echo "FAIL: no instrumented out/<variant>/harness-fork" >&2; exit 2; }
# afl-fuzz picks the driver from the magic string in the binary.  A "harness" without it
# is a fork binary run as persistent, so every input reports as a timeout and nothing is
# smoked; a harness-fork with it would be driven as persistent.
MAGIC='##SIG_AFL_PERSISTENT##'
for v in $VARIANTS; do
  p=$(hbin "$v"); f=$(hfork "$v")
  if [ -n "$p" ] && ! grep -qa "$MAGIC" "$p"; then
    echo "FAIL: $p lacks $MAGIC: a harness TU compiled by something other than afl-clang-fast" >&2
    echo "      needs -include afl_shim.h with all five macros (re-run link_harness.sh)" >&2; exit 2
  fi
  if [ -n "$f" ] && grep -qa "$MAGIC" "$f"; then
    echo "FAIL: $f carries $MAGIC: the fork binary was built without -DNO_PERSISTENT" >&2; exit 2
  fi
done
[ -n "${HOSTSAN:-}" ] || ts "NOTE: no HOSTSAN, so no real-stack differential: crashes can only be classed UNVERIFIED or HARNESS-FRAME."
# crash = a signal, or ASAN's distinctive exit code
ASAN_RUN="exitcode=86:detect_leaks=0:allocator_may_return_null=1:max_allocation_size_mb=$ALLOC_CAP_MB:symbolize=1"
is_crash() { [ "$1" -ge 128 ] || [ "$1" = 86 ]; }
# Real stack: same sanitizer options as the direct run.  node under ASAN otherwise prints a
# LeakSanitizer "SUMMARY: AddressSanitizer: N byte(s) leaked" at exit, which the
# `Sanitizer:` test below would read as a crash.  stdout -> $HOUT, stderr -> $HERR, rc -> $HRC.
hostsan() {  # <mode env or ""> <input>
  local e; e=$(mktemp)
  HOUT=$(env $1 ASAN_OPTIONS="$ASAN_RUN" timeout 60 $HOSTSAN "$2" 2>"$e"); HRC=$?
  HERR=$(cat "$e"); rm -f "$e"
}

# ---- A. every seed through every variant's fork harness ---------------------------------
ts "== A. $(ls "$CORPUS" | wc -l) seed(s) through each variant's fork harness =="
GOOD_SEED=""      # a seed no harness crashes on: the HOSTSAN preflight below uses it
for v in $VARIANTS; do for mode in default $MODES; do
  f=$(hfork "$v"); bad=0; names=""; menv=""; [ "$mode" != default ] && menv=${mode%%:*}
  for s in "$CORPUS"/*; do
    [ -f "$s" ] || continue
    out=$( { env ${menv//,/ } ASAN_OPTIONS="$ASAN_RUN" timeout 30 "$f" "$s" >/dev/null; } 2>&1 ); rc=$?
    if is_crash "$rc" || [ "$rc" = 124 ]; then bad=$((bad+1)); [ "$bad" -le 5 ] && names="$names $(basename "$s")(rc=$rc)"
    elif [ -z "$GOOD_SEED" ]; then GOOD_SEED=$s; fi
  done
  ts "  $v${menv:+ [$menv]}: $bad seed(s) crash or hang the harness${names:+:$names}"
done; done
echo "  (a corpus built to include crashers is expected to show some; a VALID seed crashing is a harness bug)"

# ---- 0. HOSTSAN preflight: before any crash depends on it -------------------------------
# A HOSTSAN that cannot run (a wrong ADDON= or PKG= path, a missing LD_PRELOAD) prints no
# result line and does not crash, so every crash would be classed DIRECT-ONLY.
if [ -n "${HOSTSAN:-}" ]; then
  pre=${GOOD_SEED:-$(ls "$CORPUS"/* 2>/dev/null | head -1)}
  hostsan "" "$pre"
  if grep -qE '(^| )status=' <<<"$HOUT"; then
    ts "HOSTSAN ok on $(basename "$pre"): $(grep -m1 -E '(^| )status=' <<<"$HOUT" | cut -c1-100)"
  else
    echo "FAIL: HOSTSAN printed no result line (status=...) for $(basename "$pre"), rc=$HRC:" >&2
    grep -m3 -E 'Error|ERROR|Cannot|SUMMARY|not found|NOT-SWAPPED|ADDON' <<<"$HERR" | cut -c1-160 | sed 's/^/      /' >&2
    echo "      Fix the real-side command first; otherwise every crash would read DIRECT-ONLY." >&2
    exit 2
  fi
fi

# ---- B. a short fuzz run per variant -----------------------------------------------------
ts "== B. ${SMOKE_S}s of fuzzing per variant${MODES:+ and mode} (campaign.sh -> smoke/, SELFTEST=skip) =="
rm -rf "$WS/smoke"
# SELFTEST=skip: smoke runs BEFORE the detection self-test (a smoke failure forces a harness
# rebuild, which would make an earlier self-test stale), and it judges the harness, not the
# detection.  The manifest records it as skipped.
bash "$CAMPAIGNER" WORKSPACE="$WS" CAMPAIGNS="$WS/smoke" CORPUS="$CORPUS" DURATION="$SMOKE_S" \
    VARIANTS="$VARIANTS" MODES="$MODES" ALLOC_CAP_MB="$ALLOC_CAP_MB" POLL=10 STAB_CHECK=$((SMOKE_S * 10)) \
    WALL=$(( SMOKE_S * 3 + 30 )) SELFTEST=skip \
    2>&1 | sed -u 's/^/  | /' | grep -E "launched|did not|aborted|failed|WARN|FAIL"
MAN="$WS/smoke/manifest.tsv"
[ -f "$MAN" ] || { echo "FAIL: the smoke campaign wrote no manifest" >&2; exit 2; }
# The manifest is read with a NON-whitespace separator: `read` with IFS=$'\t' collapses an
# EMPTY field (a mode row without an :entry) and shifts every later column.
US=$'\037'; rows() { tr '\t' "$US" < "$MAN"; }
warns=0; ran=0; broken=0; ran_variants=" "
while IFS=$US read -r name variant driver harness mode_env entry out_dir mem et map cap start stop reason execs stab sc sh cf hf selftest status rest; do
  [ "$name" = name ] && continue
  # execs/s over the time afl-fuzz actually ran: its own run_time (same snapshot as
  # execs_done), else the manifest's start..stop.  Never SMOKE_S: a walled or early run
  # did not fuzz for SMOKE_S, and calibration/trimming are outside afl-fuzz -V.
  secs=$(sed -n 's/^run_time *: *\([0-9]*\).*/\1/p' "$WS/$out_dir/default/fuzzer_stats" 2>/dev/null | head -1)
  [ -n "$secs" ] && [ "$secs" -gt 0 ] 2>/dev/null || secs=$(( ${stop:-0} - ${start:-0} ))
  [ "$secs" -gt 0 ] 2>/dev/null || secs=1
  eps=0; [ -n "$execs" ] && eps=$(( execs / secs ))
  ts "  $name: status=$status, $execs execs in ${secs}s ($eps/s), stability ${stab:-?}%, $cf crash file(s), $hf hang file(s)"
  case "$status" in
    completed) ran=$((ran+1)); ran_variants="$ran_variants$variant ";;
    walled) ran=$((ran+1)); ran_variants="$ran_variants$variant "
            ts "    NOTE stopped at the wall-clock ceiling: AFL's -V excludes trimming and calibration, so a slow or hang-heavy harness overruns it"; warns=$((warns+1));;
    aborted|failed) broken=$((broken+1)); ts "    FAIL the smoke campaign $status ($reason): this variant was not smoked";;
    *) ts "    WARN the smoke run did not complete ($reason): its result below is not reliable"; warns=$((warns+1));;
  esac
  [ "$eps" -lt "$MIN_EPS" ] && { ts "    WARN only $eps execs/s (< $MIN_EPS): a harness that slow wastes the campaign (init per call? a loop?)"; warns=$((warns+1)); }
  awk -v s="${stab%%.*}" -v m="$MIN_STAB" 'BEGIN{exit !(s!="" && s+0 < m)}' \
    && { ts "    WARN stability ${stab}% < ${MIN_STAB}%: the persistent harness keeps state between iterations; use the fork driver or reset it"; warns=$((warns+1)); }
done < <(rows)
unsmoked=""; for v in $VARIANTS; do case "$ran_variants" in *" $v "*) ;; *) unsmoked="$unsmoked $v";; esac; done
if [ "$ran" = 0 ]; then
  echo; ts "== D. verdict =="
  echo "  FAIL: no smoke campaign completed or reached its wall clock (read the status lines above and"
  echo "        $WS/smoke/*.log): nothing was fuzzed, so nothing about the harness was tested."
  exit 2
fi

# ---- C. classify every crash the smoke run saved ----------------------------------------
ts "== C. classify the saved crashes =="
declare -A CNT SITE
total=0; copied=0
LABEL=""; for v in $VARIANTS; do f=$(hfork "$v"); grep -qa '__asan_report_load' "$f" 2>/dev/null && { LABEL=$f; break; }; done
site_of() {  # stack text on stdin -> "func<TAB>file<TAB>line" of the innermost project-source frame
  sed -n 's#^ *\#[0-9]* 0x[0-9a-f]* in \(.*\) \(/[^ :]*\):\([0-9]*\).*#\1\t\2\t\3#p' \
    | grep -vE $'^(__asan_|__interceptor_|__sanitizer_|operator new|operator delete|malloc|free|memcpy|memmove|memset)|\t/usr/|compiler-rt|sanitizer_common' | head -1
}
expressible() { [ -z "${STRING_API:-}" ] && return 0
  iconv -f UTF-8 -t UTF-8 "$1" >/dev/null 2>&1 && ! grep -qaP '\x00' "$1"; }
while IFS=$US read -r name variant driver harness mode_env entry out_dir rest; do
  [ "$name" = name ] && continue
  fork=$(hfork "$variant"); menv=""; [ "$mode_env" != default ] && menv=$mode_env
  for c in "$WS/$out_dir"/default/crashes/id:*; do
    [ -f "$c" ] || continue; total=$((total+1))
    out=$( { env ${menv//,/ } ASAN_OPTIONS="$ASAN_RUN" timeout 30 "$fork" "$c" >/dev/null; } 2>&1 ); rc=$?
    if ! is_crash "$rc"; then
      # Not through the fork binary.  Before calling it iteration state, try the PERSISTENT
      # binary single-shot (argv path): a crash that reproduces there every time is a
      # layout-dependent bug, not state, and a plain PASS would bury it.
      cls=STATE; site="-"; pb=$(hbin "$variant")
      if [ -n "$pb" ]; then
        pout=$( { env ${menv//,/ } ASAN_OPTIONS="$ASAN_RUN" timeout 30 "$pb" "$c" >/dev/null; } 2>&1 ); prc=$?
        if is_crash "$prc"; then
          cls=PERSISTENT-ONLY
          IFS=$'\t' read -r sfn spath sline <<<"$(site_of <<<"$pout")"
          site="${sfn:-?} @ $(basename "${spath:-?}"):${sline:-?} (rc=$prc)"
        fi
      fi
    else
      st=$(site_of <<<"$out")
      # a build without the sanitizer has no stack: get one from the sanitized fork harness
      if [ -z "$st" ] && [ -n "$LABEL" ] && [ "$LABEL" != "$fork" ]; then
        lout=$( { env ${menv//,/ } ASAN_OPTIONS="$ASAN_RUN" timeout 30 "$LABEL" "$c" >/dev/null; } 2>&1 ); lrc=$?
        is_crash "$lrc" && st=$(site_of <<<"$lout")
      fi
      IFS=$'\t' read -r sfn spath sline <<<"$st"
      site="${sfn:-?} @ $(basename "${spath:-?}"):${sline:-?}"
      inharness=0; [ -n "$spath" ] && grep -qE "$HARNESS_RE" <<<"$spath" && inharness=1
      if [ -n "${HOSTSAN:-}" ]; then
        # The real stack FIRST: the harness holds copies of package method bodies and static
        # helpers (step 2), so a frame in a harness file can be a real bug in copied code.
        hostsan "${menv//,/ }" "$c"
        if is_crash "$HRC" || grep -q 'Sanitizer:' <<<"$HERR"; then
          cls=REAL; [ "$inharness" = 1 ] && { site="$site (frame in copied code)"; copied=$((copied+1)); }
        elif [ "$inharness" = 1 ]; then cls=HARNESS-FRAME
        elif ! expressible "$c"; then cls=OUT-OF-SCOPE
        else cls=DIRECT-ONLY; fi
      elif [ "$inharness" = 1 ]; then cls=HARNESS-FRAME
      else cls=UNVERIFIED; fi
    fi
    CNT[$cls]=$(( ${CNT[$cls]:-0} + 1 )); SITE["$cls|$site"]=$(( ${SITE["$cls|$site"]:-0} + 1 ))
  done
done < <(rows)
# keys hold spaces (`func @ file:line`), so iterate them quoted, not through word-splitting
for k in "${!SITE[@]}"; do printf '  %-14s %3d  %s\n' "${k%%|*}" "${SITE[$k]}" "${k#*|}"; done | sort
[ "$total" = 0 ] && echo "  (the smoke run saved no crashes)"

# ---- D. verdict --------------------------------------------------------------------------
echo; ts "== D. verdict =="
fail=0
if [ "${CNT[HARNESS-FRAME]:-0}" -gt 0 ]; then fail=1
  echo "  FAIL: ${CNT[HARNESS-FRAME]} crash(es) in the HARNESS'S OWN code${HOSTSAN:+, not reproduced on the real stack}. Fix the"
  echo "        harness (a stub, a placement-new, the input handling); do not fuzz on. A zeroed C++ object is the"
  echo "        classic: every error path crashes inside it."
  [ -z "${HOSTSAN:-}" ] && echo "        (No HOSTSAN: a bug in package code COPIED into the harness also lands here. Give HOSTSAN to tell them apart.)"
fi
if [ "${CNT[DIRECT-ONLY]:-0}" -gt 0 ]; then fail=1
  echo "  FAIL: ${CNT[DIRECT-ONLY]} crash(es) the direct harness has and the real stack does not, on inputs the API can"
  echo "        express. The harness reaches code or builds state the real stack does not (gate step 5, four-layers.md)."; fi
[ "${CNT[STATE]:-0}" -gt 0 ] && echo "  NOTE: ${CNT[STATE]} crash(es) reproduce through neither binary single-shot: state carried between persistent iterations."
if [ "${CNT[PERSISTENT-ONLY]:-0}" -gt 0 ]; then warns=$((warns+1))
  echo "  WARN: ${CNT[PERSISTENT-ONLY]} crash(es) reproduce single-shot on the PERSISTENT binary but not on the fork binary (sites"
  echo "        above). Not iteration state: a layout-dependent read (uninitialised memory?) or an instrumentation"
  echo "        artefact. Not the harness's fault as far as this check can tell, so not a FAIL -- but an open finding:"
  echo "        keep the files, name the persistent binary in the write-up, and have triage replay them on it."
fi
[ "${CNT[UNVERIFIED]:-0}" -gt 0 ] && echo "  NOTE: ${CNT[UNVERIFIED]} crash(es) UNVERIFIED -- pass HOSTSAN= to compare them with the real stack."
[ "${CNT[REAL]:-0}" -gt 0 ] && echo "  ok:   ${CNT[REAL]} crash(es) reproduce on the real stack: library bugs, not harness bugs."
[ "$copied" -gt 0 ] && echo "        $copied of them have their innermost frame in code copied into the harness: report against the package source the copy came from."
[ "${CNT[OUT-OF-SCOPE]:-0}" -gt 0 ] && echo "  ok:   ${CNT[OUT-OF-SCOPE]} crash(es) need input a JS string cannot carry: out of scope, not a harness bug."
[ "$warns" -gt 0 ] && echo "  WARN: $warns speed/stability/completion warning(s) above."
if [ "$broken" -gt 0 ] || [ -n "$unsmoked" ]; then
  echo "  FAIL: ${broken} smoke campaign(s) aborted or failed${unsmoked:+; variant(s) with no completed/walled run:$unsmoked}."
  echo "        Those builds were not smoked; read $WS/smoke/*.log, fix, and re-run."
  exit 2
fi
if [ "$fail" = 0 ]; then echo "  PASS: nothing crashed on the harness's account in ${SMOKE_S}s per variant. This shows the harness is not"; echo "        obviously wrong; it does not show the harness is right (the gate and the self-test do that)."; fi
exit $fail
