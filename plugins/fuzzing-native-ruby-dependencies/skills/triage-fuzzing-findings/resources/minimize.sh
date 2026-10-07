#!/bin/bash
# Minimize the bucket REPRESENTATIVES -- one input per bug -- with afl-tmin.  This script
# only STEERS afl-tmin (how it is fed, how strict it is, what counts as success); it does
# not minimize anything itself.  Runs after screen.sh -> bucket.sh (-> confirm.sh).
#
#   minimize.sh OUT=<triage dir> [REPS=<dir>] [KEY=VALUE...]
#
# How afl-tmin is steered, and why (all measured on the Node sibling plugin's harnesses, AFL++ 4.33c):
#   * INPUT THROUGH /dev/stdin, not @@.  afl-tmin's own temp file reached the harness EMPTY
#     (a debug harness printed n=0 bytes read), so tmin saw every input "terminate
#     normally", minimized to zero bytes and exited 0 -- on every target tried.  afl-fuzz
#     and afl-showmap deliver the same bytes to the same binaries correctly.  Passing
#     `/dev/stdin` as the harness's file argument makes tmin feed stdin, which arrives
#     intact: it then enters crash mode and minimizes properly.  This needs a harness that
#     READS its input file; one that stat()s or mmap()s it cannot take a pipe -- checked
#     per input below, and such an input keeps its original bytes.
#   * Free minimization first, then AFL_TMIN_EXACT=1 only if the bug DRIFTED.  EXACT
#     requires the identical execution path and rejected 97 of 112 candidates on an image-
#     decoding Node binding's GIF input (0 % reduction).  Without it tmin may wander to a different crash (a stylesheet-compiler
#     Node binding: an over-read in one function minimized into one in an unchecked UTF-8 decoder).  So the
#     result's sanitizer key (kind + function) is compared with the original's, and EXACT
#     is the retry, not the default.
#   * Hangs: afl-tmin -H with a SHORT -t (HANG_S), then the result is re-checked at the full
#     timeout -- each candidate that keeps hanging costs the whole -t.
#   * Never trust afl-tmin's exit code: the result must be non-empty, reproduce, and keep its
#     key.  If no attempt verifies, the original bytes are kept and the log says so.
#
# Products:
#   OUT/min/<name>    one reproducer per representative, same name as in buckets/
#   OUT/amplification.min.tsv   out-of-memory representatives: demanded bytes / MINIMIZED size
#   OUT/tmin.log      everything afl-tmin said
#
# Configure with KEY=VALUE arguments or environment:
#   OUT       the triage directory screen.sh and bucket.sh wrote (default ./triage)
#   REPS      directory of inputs to minimize (default OUT/buckets).  The driver passes a
#             subset: representatives CLEAN on every column and entry point keep their
#             original bytes unless MINIMIZE_ALL=1.
#   FORK HARNESS_ENV HANGS   default to what screen.sh recorded in OUT/config
#   TIMEOUT   per-exec timeout in ms for crashes, and the final hang check (default: what
#             screen.sh recorded in OUT/config, else 5000)
#   EXEC_PAD_S  start-up seconds added to TIMEOUT (default: OUT/config, else 5)
#   HANG_S    afl-tmin's -t, in seconds, when minimizing a hang (default 2)
#   MAP_SIZE  AFL_MAP_SIZE (default: ask the binary); afl-tmin aborts on a large-map target without it
#   ALLOC_CAP_MB  fallback ceiling for inputs missing from OUT/cap.tsv (default 1024)
set -uo pipefail
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
OUT=${OUT:-./triage}
cfg() { sed -n "s/^$1=//p" "$OUT/config" 2>/dev/null; }
FORK=${FORK:-$(cfg FORK)}; FORK=${FORK:?set FORK, or run screen.sh first so OUT/config has it}
HARNESS_ENV=${HARNESS_ENV:-$(cfg HARNESS_ENV)}
HANGS=${HANGS:-$(cfg HANGS)}; HANGS=${HANGS:-0}
for kv in ${HARNESS_ENV//,/ }; do export "$kv"; done   # several settings may be joined with commas
REPS=${REPS:-$OUT/buckets}
TIMEOUT=${TIMEOUT:-$(cfg TIMEOUT)}; TIMEOUT=${TIMEOUT:-5000}
EXEC_PAD_S=${EXEC_PAD_S:-$(cfg EXEC_PAD_S)}; EXEC_PAD_S=${EXEC_PAD_S:-5}
HANG_S=${HANG_S:-2}; ALLOC_CAP_MB=${ALLOC_CAP_MB:-1024}
MAP_SIZE=${MAP_SIZE:-$(AFL_DUMP_MAP_SIZE=1 "$FORK" 2>/dev/null | tail -1)}; MAP_SIZE=${MAP_SIZE:-131072}
export AFL_MAP_SIZE=$MAP_SIZE          # without it tmin aborts on a large-map target
EXEC_S=$(LC_ALL=C awk -v t="$TIMEOUT" -v p="$EXEC_PAD_S" 'BEGIN{printf "%.3f", t/1000 + p}')   # same threshold screen.sh used; LC_ALL=C: never a decimal comma
asan_opts() { echo "abort_on_error=1:symbolize=0:detect_leaks=0:allocator_may_return_null=1:max_allocation_size_mb=$1"; }

T0=$(date +%s)
ts() { printf '[%s +%ds] %s\n' "$(date +%H:%M:%S)" "$(( $(date +%s) - T0 ))" "$*"; }

reproduces_rc() {
  if [ "$HANGS" = 1 ]; then [ "$1" = 124 ]; else [ "$1" -ge 128 ] || [ "$1" = 86 ]; fi
}
run1() { R_OUT=$( { timeout "$EXEC_S" "$FORK" "$1" >/dev/null; } 2>&1 ); R_RC=$?; }
# The bug's identity, for the drift check: sanitizer kind + function (not the line -- a
# minimized input may reach the same bug at another line of the same function).
key_of() {
  ASAN_OPTIONS="${ASAN_OPTIONS/symbolize=0/symbolize=1}" timeout "$EXEC_S" "$FORK" "$1" 2>&1 >/dev/null \
    | sed -n 's#.*SUMMARY: [A-Za-z]*Sanitizer: \([a-z-]*\) .* in \([^(]*\).*#\1 in \2#p' | head -1
}
verified() {  # <candidate> <original key> -> 0 if non-empty, reproduces, same bug
  [ -s "$1" ] || return 1
  run1 "$1"; reproduces_rc "$R_RC" || return 1
  [ "$HANGS" = 1 ] && return 0
  [ "$(key_of "$1")" = "$2" ]
}
capof() { awk -F'\t' -v n="$1" '$1==n{print $2; exit}' "$OUT/cap.tsv" 2>/dev/null; }

[ -n "$(ls "$REPS" 2>/dev/null)" ] || { echo "no representatives in $REPS; run bucket.sh first" >&2; exit 1; }
mkdir -p "$OUT/min"; rm -f "$OUT/min"/* 2>/dev/null || true
: > "$OUT/amplification.min.tsv"
TL="$OUT/tmin.log"; : > "$TL"
if [ "$HANGS" = 1 ]; then TMIN_T=$(( HANG_S * 1000 )); HFLAG=(-H); else TMIN_T=$TIMEOUT; HFLAG=(); fi
n=$(ls "$REPS" | grep -c .); i=0; nfree=0; nexact=0; nkept=0
ts "== minimize $n representative(s) from $REPS with afl-tmin${HARNESS_ENV:+ under $HARNESS_ENV} =="
for c in "$REPS"/*; do
  [ -f "$c" ] || continue
  name=$(basename "$c"); pname=${name#??????-}          # bucket files are <6 hex>-<pool name>
  dst="$OUT/min/$name"; cap=$(capof "$pname"); cap=${cap:-$ALLOC_CAP_MB}
  export ASAN_OPTIONS="$(asan_opts "$cap")"
  i=$((i+1)); ts "  [$i/$n] $name ($(wc -c <"$c") B, ${cap} MB)"
  # Can this harness take its input through /dev/stdin?  If not, afl-tmin cannot be fed.
  if { timeout "$EXEC_S" "$FORK" /dev/stdin <"$c" >/dev/null; } 2>/dev/null; then rc=0; else rc=$?; fi
  if ! reproduces_rc "$rc"; then
    cp "$c" "$dst"; nkept=$((nkept+1))
    ts "    harness does not reproduce it through /dev/stdin (rc=$rc): afl-tmin cannot be steered; original kept"
    continue
  fi
  okey=$(key_of "$c")
  how=""
  for mode in free exact; do
    rm -f "$dst"
    echo "=== $name ($mode) ===" >> "$TL"
    if [ "$mode" = exact ]; then export AFL_TMIN_EXACT=1; else unset AFL_TMIN_EXACT; fi
    timeout $(( TMIN_T / 100 + 600 )) afl-tmin -m none -t "$TMIN_T" "${HFLAG[@]}" \
        -i "$c" -o "$dst" -- "$FORK" /dev/stdin >>"$TL" 2>&1 || true
    if verified "$dst" "$okey"; then how=$mode; break; fi
    [ "$mode" = free ] && [ -s "$dst" ] && ts "    free minimization drifted from '$okey' (or did not verify); retrying with AFL_TMIN_EXACT=1"
  done
  unset AFL_TMIN_EXACT
  case "$how" in
    free)  nfree=$((nfree+1));;
    exact) nexact=$((nexact+1));;
    *)     cp "$c" "$dst"; nkept=$((nkept+1)); ts "    afl-tmin produced no verified reproducer; original kept (see $TL)";;
  esac
  ts "    $(wc -c <"$c") B -> $(wc -c <"$dst") B${how:+ ($how)}${okey:+  key: $okey}"
  run1 "$dst"
  hex=$(sed -n 's/.*\(trying\|failed\) to allocate 0x\([0-9a-f]*\) bytes.*/\2/p' <<<"$R_OUT" | head -1)
  if [ -n "$hex" ]; then
    req=$((16#$hex)); insz=$(wc -c <"$dst")
    printf '%s\t%s\t%s\t%s\t%s\n' "$pname" "$insz" "$req" "$(( req / (insz > 0 ? insz : 1) ))" "$cap" >> "$OUT/amplification.min.tsv"
  fi
done
echo "  afl-tmin: $nfree minimized freely, $nexact needed AFL_TMIN_EXACT, $nkept kept as original -> $OUT/min"
echo "  (do NOT hand-minimize further: the obvious mechanism is often the guarded one)"
