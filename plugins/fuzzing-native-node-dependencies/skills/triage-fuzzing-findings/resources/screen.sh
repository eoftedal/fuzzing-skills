#!/bin/bash
# Collect every crash (or hang) a campaign saved and screen each one against the harness.
# This is the FIRST step: it decides what reproduces, and at which allocation ceiling.
# Bucketing comes next, on these raw reproducers -- not on minimized ones: bucketing is the
# step that collapses a pile into bugs (111 raw crashes from a stylesheet-compiler
# binding -> exactly the 4 published bugs), and minimization, the expensive step, then runs on one representative
# per bucket instead of on everything.  Products:
#   OUT/pool/      the raw union, content-deduplicated, build variant in each name
#   OUT/repro/     the inputs that REPRODUCE (copies from pool/, same names) -> bucket.sh
#   OUT/screen     one line per input per ceiling tried: name, rc, milliseconds, ceiling
#   OUT/cap.tsv    every reproducer and the allocation ceiling it reproduced at
#   OUT/nonrepro/  inputs that reproduced at no ceiling.  The driver re-screens these on the
#                  other build variants and under the harness's MODES.
#   OUT/amplification.tsv  out-of-memory reproducers: name, input B, demanded B, ratio, ceiling
#   OUT/intermittent.tsv   inputs only RETRY made reproduce
#   OUT/config     FORK, HARNESS_ENV, HANGS -- bucket.sh and minimize.sh read it
#
# Configure with KEY=VALUE arguments or environment:
#   FORK      the fork harness to screen against.  Start with the build that produced the
#             inputs.  The risk of the wrong build is ONE-directional (measured, 161 real
#             crashes): an ASAN campaign's crashes reproduce on the plain build 0 of 111
#             times (1-2 byte over-reads are invisible without the sanitizer), while a plain
#             campaign's crashes reproduce on ASAN 13/13 and 25/25, and not one input crashed
#             the plain build alone.  The driver offers non-reproducers to the other builds.
#   HARNESS_ENV  space-separated VAR=value settings the harness reads (MODE=2,
#             HARNESS_MODE=file).  Exported to every harness run.  A crash found in a
#             non-default harness mode does NOT reproduce in the default one -- the image-
#             decoding binding's next major version had two crashers that are rc=0 by
#             default and rc=134 under MODE=2.
#   DIRS      space-separated input directories (default: every crashes/ (or hangs/) under
#             the workspace, plus ./crashers).  A campaign's afl-fuzz -o directory is expanded
#             to every instance's crashes/ (or hangs/): default/, or main/ and s<i>/ when it
#             ran with secondaries.  Inputs are deduplicated by content across all of them
#             (secondaries sync queues, so one bug is often saved by several instances).
#   HANGS=1   collect hangs/ and screen for hangs (`timeout` exit 124) instead of crashes
#   OUT       work directory (default ./triage)
#   MAP_SIZE  AFL_MAP_SIZE (default: ask the binary)
#   TIMEOUT   per-exec timeout in ms (default 5000).  A sanitized build of a real library
#             can take seconds per input (an image-decoding binding: 3.1-3.5 s).
#   EXEC_PAD_S  seconds added to TIMEOUT for process start-up (default 5); the run is killed
#             at TIMEOUT/1000 + EXEC_PAD_S s.  triage_all.sh passes 1 for a manifest
#             campaign's hangs, screened at a multiple of that campaign's exec timeout.
#   ALLOC_CAP_MB  first rung of the allocation ceiling (default 1024).  A declared-size bug
#             -- the library allocates a size the input declared before validating it --
#             only shows if the request EXCEEDS the ceiling.  1 GB is generous for a native
#             dependency on a fuzz-sized input; 4 GB sits above the whole 32-bit range a
#             declared length can express and acquitted every such bug (a block-compression
#             binding: a 5-byte
#             input demanding 3.7 GB is rc=1 at 4096 MB and rc=134 at 1024).
#   CAP_LADDER  ceilings to try, high to low (default "$ALLOC_CAP_MB 256 64").  Walked PER
#             INPUT: each rung re-screens only what has not reproduced yet.  Stopping at the
#             first rung that reproduced anything dropped a 600 MB declared-size input from a
#             pool that also held heap over-reads.
#   CAP_UP    ceilings to try upward when GOOD shows the library's normal work needs more
#             than the first rung (default "2048 4096 8192 16384").
#   GOOD      a reference input.  Guards the ladder: a ceiling is only used if GOOD behaves
#             there as it does with the ceiling lifted.  Differential on purpose: a reference
#             the library legitimately REJECTS is still a valid guard.
#   RETRY     re-run each input that did NOT reproduce N times (default 0), for campaigns
#             with stability below ~90 %.  Only non-reproducers are retried; promotions go to
#             OUT/intermittent.tsv.
#   PROGRESS_EVERY  seconds between progress lines inside long loops (default 20).
#
# This script OWNS ASAN_OPTIONS (abort_on_error=1, symbolize=0, a per-input ceiling).
set -uo pipefail
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
FORK=${FORK:?set FORK=the fork harness matching the campaign}
[ -z "${GOOD:-}" ] || [ -f "$GOOD" ] || { echo "FAIL: GOOD=$GOOD does not exist (relative to $(pwd)). A missing reference input" >&2
                                            echo "      looks 'consistent' at every ceiling and silently disables the guard." >&2; exit 2; }
OUT=${OUT:-./triage}
HANGS=${HANGS:-0}; WANT=crashes; [ "$HANGS" = 1 ] && WANT=hangs
WANT_VERB=crash; [ "$HANGS" = 1 ] && WANT_VERB=hang
TIMEOUT=${TIMEOUT:-5000}; RETRY=${RETRY:-0}
HARNESS_ENV=${HARNESS_ENV:-}
for kv in ${HARNESS_ENV//,/ }; do export "$kv"; done   # several settings may be joined with commas
MAP_SIZE=${MAP_SIZE:-$(AFL_DUMP_MAP_SIZE=1 "$FORK" 2>/dev/null | tail -1)}; MAP_SIZE=${MAP_SIZE:-131072}
export AFL_MAP_SIZE=$MAP_SIZE
ALLOC_CAP_MB=${ALLOC_CAP_MB:-1024}
CAP_LADDER=${CAP_LADDER:-"$ALLOC_CAP_MB 256 64"}
CAP_UP=${CAP_UP:-"2048 4096 8192 16384"}
LIFTED=16384
asan_opts() { echo "abort_on_error=1:symbolize=0:detect_leaks=0:allocator_may_return_null=1:max_allocation_size_mb=$1"; }
export ASAN_OPTIONS="$(asan_opts "$ALLOC_CAP_MB")"
EXEC_PAD_S=${EXEC_PAD_S:-5}
EXEC_S=$(LC_ALL=C awk -v t="$TIMEOUT" -v p="$EXEC_PAD_S" 'BEGIN{printf "%.3f", t/1000 + p}')   # timeout(1) takes fractions; LC_ALL=C: never a decimal comma

# Timestamped progress: several steps legitimately take minutes and two can hang outright
# (references/afl-tool-reliability.md); silence is indistinguishable from a stall.
T0=$(date +%s)
ts() { printf '[%s +%ds] %s\n' "$(date +%H:%M:%S)" "$(( $(date +%s) - T0 ))" "$*"; }
PROGRESS_EVERY=${PROGRESS_EVERY:-20}
_plast=0
prog() { # <done> <total> <what>: at most once per PROGRESS_EVERY seconds, plus the last item
  local now; now=$(date +%s)
  if [ "$1" = "$2" ] || [ $((now - _plast)) -ge "$PROGRESS_EVERY" ]; then _plast=$now; ts "    $1/$2 $3"; fi
}

mkdir -p "$OUT"
# Stale files from a previous run would be bucketed and confirmed as if new.
rm -rf "$OUT/pool" "$OUT/repro" "$OUT/nonrepro" "$OUT/buckets" "$OUT/min"
mkdir -p "$OUT/pool" "$OUT/repro" "$OUT/nonrepro"
{ echo "FORK=$FORK"; echo "HARNESS_ENV=$HARNESS_ENV"; echo "HANGS=$HANGS"
  echo "TIMEOUT=$TIMEOUT"; echo "EXEC_PAD_S=$EXEC_PAD_S"; } > "$OUT/config"

# ONE reproduction predicate for every step: deciding it separately per step is how an input
# counted in one step gets dropped by the next.  Under HANGS=1 it inverts: `timeout` exits 124.
reproduces_rc() {
  if [ "$HANGS" = 1 ]; then [ "$1" = 124 ]; else [ "$1" -ge 128 ] || [ "$1" = 86 ]; fi
}
# One run, in the CURRENT shell: sets R_RC and R_OUT (the harness's stderr, for the
# amplification parser) so the screen runs each input once, not once per question.
# `{ ...; } 2>&1` keeps bash's own "Aborted"/"Segmentation fault" announcements out of the log.
run1() {
  R_OUT=$( { timeout "$EXEC_S" "$FORK" "$1" >/dev/null; } 2>&1 )
  R_RC=$?
}
run_rc() { run1 "$1"; echo "$R_RC"; }
# ASAN names the size it refused ("allocator is trying to allocate 0x<hex> bytes").  The
# ratio to the INPUT size is the finding: a 5-byte input demanding 3.7 GB is a denial of
# service whatever ceiling happens to catch it.
amp_from() {  # <file>, reading R_OUT of the run just made -> "demanded ratio" or nothing
  local hex req insz
  hex=$(sed -n 's/.*trying to allocate 0x\([0-9a-f]*\) bytes.*/\1/p' <<<"$R_OUT" | head -1)
  [ -n "$hex" ] || hex=$(sed -n 's/.*failed to allocate 0x\([0-9a-f]*\) bytes.*/\1/p' <<<"$R_OUT" | head -1)
  [ -n "$hex" ] || return 0
  req=$((16#$hex)); insz=$(wc -c <"$1")
  echo "$req $(( req / (insz > 0 ? insz : 1) ))"
}

# ---- 1. collect --------------------------------------------------------------------------
ts "== 1. collect ($WANT) =="
if [ -n "${DIRS:-}" ]; then
  # an -o directory (no id:* of its own, instance dirs below): every instance's $WANT/
  SRCS=$(for d in $DIRS; do
           if ! ls "$d" 2>/dev/null | grep -q '^id:' && ls -d "$d"/*/"$WANT" >/dev/null 2>&1; then
             ls -d "$d"/*/"$WANT"; else echo "$d"; fi; done | xargs)
else
  # NOT just ./out: real workspaces keep campaigns in campaign/, hunt/, bench/.
  SRCS=$(find . -path "./${OUT#./}" -prune -o -type d -name "$WANT" -print 2>/dev/null | sort)
  [ "$WANT" = crashes ] && [ -d ./crashers ] && SRCS="$SRCS ./crashers"
fi
[ -n "$SRCS" ] || { echo "FAIL: no $WANT directories found; pass DIRS=" >&2; exit 1; }
declare -A seen; i=0; dup=0
for d in $SRCS; do
  # Provenance = the BUILD VARIANT.  The path is anchored with a leading "/" so a relative
  # DIRS=campaign/asan/... matches like ./campaign/asan/... does.
  prov=$(sed -n 's#.*/\(out\|campaign[^/]*\|hunt\|bench\|fuzzout\)/\([^/]*\)/.*#\2#p' <<<"/${d#./}/" | head -1)
  [ -z "$prov" ] && prov=$(basename "$(dirname "$d")")
  case "$prov" in .|''|default) prov=$(tr -c 'A-Za-z0-9' _ <<<"${d#./}" | sed 's/_*$//');; esac
  prov=${prov//-/_}                     # bucket.sh splits pool names on '-'
  st="$(dirname "$d")/fuzzer_stats"
  if [ -f "$st" ] && [ "$WANT" = crashes ]; then
    want=$(sed -n 's/^saved_crashes *: *//p' "$st" | tr -d ' ')
    have=$(ls "$d" 2>/dev/null | grep -c '^id:')
    [ -n "$want" ] && [ "$want" != "$have" ] && \
      echo "  WARN: $d has $have id:* files but fuzzer_stats says saved_crashes=$want;" \
           "two fuzzers shared this -o directory. Triage $have and quote $have."
    stab=$(sed -n 's/^stability *: *//p' "$st" | tr -d ' %')
    [ -n "$stab" ] && awk -v s="${stab%%.*}" 'BEGIN{exit !(s+0 < 90)}' && \
      echo "  WARN: $d stability was $stab% (<90): reproduction is not deterministic. Set RETRY=5."
  fi
  # the instance that saved it, when a campaign ran several (main, s1, ...): kept in the pool
  # name so a reader can find the original file
  inst=$(basename "$(dirname "$d")"); case $inst in main|s[0-9]*) inst="${inst}_";; *) inst="";; esac
  declare -A vis=()
  for c in "$d"/id:* "$d"/*; do
    [ -f "$c" ] || continue
    [ -n "${vis[$c]:-}" ] && continue; vis[$c]=1          # id:* first, then the rest: once each
    case "$(basename "$c")" in README*) continue;; esac   # AFL writes README.txt here
    h=$(md5sum "$c" | cut -d' ' -f1)
    [ -n "${seen[$h]:-}" ] && { dup=$((dup+1)); continue; }; seen[$h]=1
    cp "$c" "$OUT/pool/$(printf '%04d' $i)-${prov}-${inst}$(basename "$c" | tr -c 'A-Za-z0-9._' _ | cut -c1-20)"
    i=$((i+1))
  done
done
echo "  $i unique $WANT files from:"; for d in $SRCS; do echo "    $d"; done
[ "$dup" -gt 0 ] && echo "  ($dup more were byte-identical to one already pooled: same input saved twice, e.g. by two instances)"
[ -n "$HARNESS_ENV" ] && echo "  harness mode: $HARNESS_ENV"
[ "$i" -gt 0 ] || { echo "FAIL: pool is empty" >&2; exit 1; }

# ---- 2. screen, walking the allocation-ceiling ladder per input ---------------------------
ts "== 2. screen the pool against FORK${HARNESS_ENV:+ under $HARNESS_ENV} =="
: > "$OUT/screen"; : > "$OUT/cap.tsv"; : > "$OUT/amplification.tsv"; : > "$OUT/intermittent.tsv"
GOOD_BASE_RC=""
good_ok_at() {  # <cap> -> 0 if GOOD behaves here as with the ceiling lifted
  [ -n "${GOOD:-}" ] || return 0
  if [ -z "$GOOD_BASE_RC" ]; then
    GOOD_BASE_RC=$( export ASAN_OPTIONS="$(asan_opts $LIFTED)"; run_rc "$GOOD" )
    ts "  GOOD=$(basename "$GOOD") baseline rc=$GOOD_BASE_RC (ceiling lifted to $LIFTED MB)"
  fi
  [ "$( export ASAN_OPTIONS="$(asan_opts "$1")"; run_rc "$GOOD" )" = "$GOOD_BASE_RC" ]
}
if ! grep -qa '__asan_report_load' "$FORK" 2>/dev/null; then
  ts "  $FORK is not sanitized: the allocation ceiling does not apply; one screen"
  LADDER=$ALLOC_CAP_MB
elif [ "$HANGS" = 1 ]; then
  LADDER=$ALLOC_CAP_MB                    # a hang has nothing to do with the allocator
else
  LADDER=$CAP_LADDER
  top=${LADDER%% *}
  if ! good_ok_at "$top"; then
    # The library's normal work needs more than the first rung.  Walk UP to the first
    # ceiling GOOD tolerates and screen only there: any lower rung would convict inputs
    # for the ceiling's fault.  (This used to crash on an unset counter.)
    start=$LIFTED
    for up in $CAP_UP; do [ "$up" -gt "$top" ] && good_ok_at "$up" && { start=$up; break; }; done
    ts "  GOOD=$(basename "$GOOD") behaves differently at $top MB than with the ceiling lifted:"
    ts "  the library's normal work needs more. Screening at $start MB only."
    LADDER=$start
  fi
fi
mapfile -t remaining < <(ls -d "$OUT/pool"/* 2>/dev/null)
rep=0; slow=0; first=1
for cap in $LADDER; do
  if [ "$first" = 0 ] && ! good_ok_at "$cap"; then
    ts "  GOOD=$(basename "$GOOD") behaves differently at $cap MB: not going lower"
    break
  fi
  first=0
  export ASAN_OPTIONS="$(asan_opts "$cap")"
  next=(); newly=0; scanned=0; n=${#remaining[@]}
  for p in "${remaining[@]}"; do
    nm=$(basename "$p")
    st=$(date +%s%N); run1 "$p"; ms=$(( ($(date +%s%N) - st) / 1000000 ))
    printf '%s\trc=%s\t%sms\t%sMB\n' "$nm" "$R_RC" "$ms" "$cap" >> "$OUT/screen"
    if reproduces_rc "$R_RC"; then
      newly=$((newly+1)); printf '%s\t%s\n' "$nm" "$cap" >> "$OUT/cap.tsv"
      a=$(amp_from "$p")
      # "$a" unquoted on purpose: "demanded ratio" becomes two columns
      [ -n "$a" ] && printf '%s\t%s\t%s\t%s\t%s\n' "$nm" "$(wc -c <"$p")" $a "$cap" >> "$OUT/amplification.tsv"
    else
      next+=("$p")
    fi
    [ "$HANGS" = 1 ] || [ "$ms" -le "$TIMEOUT" ] || slow=$((slow+1))
    scanned=$((scanned+1)); prog "$scanned" "$n" "screened at $cap MB (last: $nm rc=$R_RC ${ms}ms)"
  done
  rep=$((rep + newly)); remaining=("${next[@]}")
  ts "  at max_allocation_size_mb=$cap: $newly ${WANT_VERB}, ${#remaining[@]} still do not"
  [ "${#remaining[@]}" = 0 ] && break
done

if [ "$RETRY" -gt 0 ] && [ "${#remaining[@]}" -gt 0 ]; then
  top=${LADDER%% *}; export ASAN_OPTIONS="$(asan_opts "$top")"
  ts "  RETRY=$RETRY: re-running the ${#remaining[@]} input(s) that did not reproduce"
  next=(); pr=0
  for p in "${remaining[@]}"; do
    hit=0
    for k in $(seq "$RETRY"); do run1 "$p"; reproduces_rc "$R_RC" && { hit=$k; break; }; done
    if [ "$hit" -gt 0 ]; then
      nm=$(basename "$p"); pr=$((pr+1)); rep=$((rep+1))
      printf '%s\t%s\n' "$nm" "$top" >> "$OUT/cap.tsv"
      printf '%s\tfailed the screen, reproduced on retry %s of %s\n' "$nm" "$hit" "$RETRY" >> "$OUT/intermittent.tsv"
    else next+=("$p"); fi
  done
  remaining=("${next[@]}")
  ts "  RETRY promoted $pr genuinely intermittent input(s) (see $OUT/intermittent.tsv)"
fi
for p in "${remaining[@]}"; do cp "$p" "$OUT/nonrepro/"; done
norep=${#remaining[@]}

if [ -s "$OUT/amplification.tsv" ]; then
  ts "  AMPLIFICATION (input bytes -> bytes the library demanded):"
  sort -t$'\t' -k4,4 -rn "$OUT/amplification.tsv" | head -3 \
    | while IFS=$'\t' read -r nm insz req ratio cap; do
        ts "    $nm: $insz B in -> $req B demanded (${ratio}x) at $cap MB"; done
  ts "  => RESOURCE EXHAUSTION / DoS: a small input that demands this much memory is a"
  ts "     denial of service on its own, worse without node (no GC, no heap limit)."
  ts "     Report the ratio and the ceiling, not just 'out-of-memory'."
  [ -n "${GOOD:-}" ] || ts "     NOTE: no GOOD= given: unverified that these ceilings permit normal work."
fi
echo "  $rep of $i ${WANT_VERB} this FORK; $norep do not (per-input detail in $OUT/screen)"
[ "$slow" -gt 0 ] && echo "  WARN: $slow input(s) exceeded TIMEOUT=${TIMEOUT}ms; raise TIMEOUT or they drop out"
if [ "$norep" -gt 0 ]; then
  echo "  $norep non-reproducer(s) kept in $OUT/nonrepro.  Before dismissing them: the other"
  echo "  build variant, and the harness's other MODES (HARNESS_ENV=MODE=...) -- the driver"
  echo "  re-screens them under both."
fi
if [ "$rep" = 0 ]; then
  echo "FAIL: nothing reproduces against $FORK${HARNESS_ENV:+ under $HARNESS_ENV}." >&2
  echo "      Wrong variant, wrong harness mode, wrong MAP_SIZE=$MAP_SIZE, or persistent-mode" >&2
  echo "      artifacts.  A pool of sig:09/sig:06 that reproduces nowhere is often a declared-" >&2
  echo "      size bug the allocator accepted: take it to step 3, where the install convicts." >&2
  [ "$HANGS" = 1 ] && echo "      For hangs, TIMEOUT=$TIMEOUT ms may be too generous." >&2
  exit 1
fi


# reproducers go to repro/ under their pool names: that name is how every later step finds
# an input's ceiling (cap.tsv) and its original bytes (pool/)
cut -f1 "$OUT/cap.tsv" | while read -r nm; do cp "$OUT/pool/$nm" "$OUT/repro/"; done
echo "  $rep reproducer(s) in $OUT/repro"
echo "next: bucket.sh FORK=$FORK OUT=$OUT   (ceilings and harness mode are read from $OUT)"
