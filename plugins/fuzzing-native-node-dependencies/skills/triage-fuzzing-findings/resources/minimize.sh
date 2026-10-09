#!/bin/bash
# Minimize the bucket REPRESENTATIVES -- one input per bug -- with afl-tmin.  This script
# only STEERS afl-tmin (how it is fed, how strict it is, what counts as success); it does
# not minimize anything itself.  Runs after screen.sh -> bucket.sh (-> confirm.sh).
#
#   minimize.sh OUT=<triage dir> [REPS=<dir>] [KEY=VALUE...]
#
# How afl-tmin is steered, and why (all measured on this host, AFL++ 4.33c):
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
#     decoding binding's GIF input (0 % reduction).  Without it tmin may wander to a different crash (a stylesheet-compiler
#     binding: an over-read in one function minimized into one in an unchecked UTF-8 decoder).  So the
#     result's sanitizer key (kind + file + function, line dropped) is compared with the
#     original's, and EXACT is the retry, not the default.  The key is bucket.sh's, from the
#     same code: an intercepted call (__asan_memcpy) is keyed on its first project frame.
#     Keyed on frame #0, a 12-byte over-read in one function minimized to a 1-byte one in
#     another, both reported at the memcpy interceptor, and the check saw no drift.
#   * Hangs: afl-tmin -H with a SHORT -t (HANG_S), then the result is re-checked at the full
#     timeout -- each candidate that keeps hanging costs the whole -t.
#   * Never trust afl-tmin's exit code: the result must be non-empty, reproduce, and keep its
#     key.  If no attempt verifies, the original bytes are kept and the log says so.
#
# Products:
#   OUT/min/<name>    one reproducer per representative, same name as in buckets/
#   OUT/min/<name>.key  the reproducer's own key, as checked (triage_all.sh flags DRIFT from it)
#   OUT/amplification.min.tsv   out-of-memory representatives: demanded bytes / MINIMIZED size
#   OUT/tmin.log      everything afl-tmin said
#
# Configure with KEY=VALUE arguments or environment:
#   OUT       the triage directory screen.sh and bucket.sh wrote (default ./triage)
#   REPS      directory of inputs to minimize (default OUT/buckets).  The driver passes a
#             subset: representatives CLEAN on every column and entry point keep their
#             original bytes unless MINIMIZE_ALL=1.
#   FORK HARNESS_ENV HANGS   default to what screen.sh recorded in OUT/config
#   LABEL_FORK  the harness the drift check KEYS with (default: OUT/config, else FORK).  A
#             plain harness prints no sanitizer report, so keying with it checks nothing;
#             triage_all.sh records the sanitized one bucket.sh labelled with.
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
LABEL_FORK=${LABEL_FORK:-$(cfg LABEL_FORK)}; LABEL_FORK=${LABEL_FORK:-$FORK}
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
# Collapse C++ template arguments to <>, innermost first, to a fixpoint (twin of bucket.sh's).
collapse() {
  local p=$1 n
  while :; do n=$(printf '%s' "$p" | sed 's/<[^<>]*>/\x01/g'); [ "$n" = "$p" ] && break; p=$n; done
  printf '%s' "$p" | sed 's/\x01/<>/g'
}

# ---- bug key: twin of bucket.sh's copy; keep the two identical (from ICEPTOR to sum_key) ----
# An INTERCEPTED libc call (memcpy, strlen, ...) is reported by the sanitizer at the
# interceptor, so the SUMMARY names `__asan_memcpy`, not the code that called it -- and the
# access size is just the caller's length argument, which changes with the input.  Measured
# on the image-decoding binding's next major version: one over-read in the PNG stream
# reader filed as four
# buckets (READ-8, -1024, -8192, -10660) under an unsymbolized `__asan_memcpy`.  Key on the
# first frame in project source instead, and drop the size.
ICEPTOR='__asan_(memcpy|memmove|memset)|__interceptor_|__sanitizer_|(^|[^A-Za-z_:])(memcpy|memmove|memset|memchr|memcmp|strlen|strcpy|strncpy|strcat|strcmp|strncmp|strchr|strstr)$'
# The faulting stack's project frames, innermost first: "function<TAB>file basename<TAB>line"
# (line `?` when absent).  Only the first stack (the access, not the allocation); no
# interceptor, no libc/libstdc++ (/usr/... or a relative csu/ path), no sanitizer runtime.
frames_of() {  # <sanitizer output>
  awk '/^ *#0 /{n++} n==1' <<<"$1" \
    | sed -nE 's#^ *\#[0-9]+ 0x[0-9a-f]+ in (.*) (/[^ :]*)(:([0-9]+))?(:[0-9]+)?$#\1\t\2\t\4#p' \
    | awk -F'\t' -v ic="$ICEPTOR" '$1 ~ ic || $2 ~ /^\/usr\/|compiler-rt|sanitizer_common/ {next}
        {f=$2; sub(/.*\//,"",f); print $1 "\t" f "\t" ($3=="" ? "?" : $3)}'
}
# "kind @ file:line in function", file a basename and line `?` when the SUMMARY has none;
# an interceptor's report keyed on its first project frame, "[via <interceptor>]" appended.
# Empty when there is no SUMMARY line.  No access size: the caller adds it.
sum_key() {  # <sanitizer output>
  local out=$1 key ifn site sfn sfile sline
  key=$(sed -nE 's#.*SUMMARY: [A-Za-z]*Sanitizer: ([A-Za-z-]+) ([^ (][^ ]*/)?([A-Za-z0-9_.+-]+)(:([0-9]+))?(:[0-9]+)? in (.*)#\1 @ \3:\5 in \7#p' <<<"$out" \
        | sed -E 's/^([A-Za-z-]+ @ [^ ]*): in /\1:? in /' | head -1)
  [ -z "$key" ] && key=$(sed -n 's/.*SUMMARY: [A-Za-z]*Sanitizer: \(.*\)/\1/p' <<<"$out" | head -1)
  [ -n "$key" ] || return 0
  ifn=$(sed -n 's/.* in \(.*\)$/\1/p' <<<"$key" | head -1)
  if [ -n "$ifn" ] && grep -qE "$ICEPTOR" <<<"$ifn"; then
    site=$(frames_of "$out" | head -1)
    if [ -n "$site" ]; then
      IFS=$'\t' read -r sfn sfile sline <<<"$site"
      key="${key%% *} @ $sfile:$sline in $sfn [via $ifn]"
    fi
  fi
  key=$(collapse "$key")
  # Strip build-specific noise: a BuildId and the absolute path of the harness say nothing
  # about the bug and make the report table unreadable.  An unsymbolized frame keeps its
  # offset and, crucially, its function name.
  sed -e 's/ *(BuildId: [0-9a-f]*)//g' -e 's#(/[^ )]*/\([^/ )]*\)+0x#(\1+0x#g' <<<"$key"
}
# ---- end of the twin ----
# The bug's identity, for the drift check: bucket.sh's key without the line (a minimized
# input may reach the same bug at another line of the same function).
key_of() {
  local out
  out=$(ASAN_OPTIONS="${ASAN_OPTIONS/symbolize=0/symbolize=1}" timeout "$EXEC_S" "$LABEL_FORK" "$1" 2>&1 >/dev/null)
  sum_key "$out" | sed -E 's/^([A-Za-z-]+ @ [^ ]*):[0-9?]+ in /\1 in /'
}
verified() {  # <candidate> <original key> -> 0 if non-empty, reproduces, same bug
  [ -s "$1" ] || return 1
  run1 "$1"; reproduces_rc "$R_RC" || return 1
  [ "$HANGS" = 1 ] && return 0
  [ "$(key_of "$1")" = "$2" ]
}
keyfile() {  # <reproducer> -> <reproducer>.key: its own key, or why it has none
  local k=""
  if [ "$HANGS" = 1 ]; then k="(hang: not keyed)"; else k=$(key_of "$1"); fi
  printf '%s\n' "${k:-(no sanitizer report from $(basename "$LABEL_FORK"))}" > "$1.key"
}
capof() { awk -F'\t' -v n="$1" '$1==n{print $2; exit}' "$OUT/cap.tsv" 2>/dev/null; }

[ -n "$(ls "$REPS" 2>/dev/null)" ] || { echo "no representatives in $REPS; run bucket.sh first" >&2; exit 1; }
mkdir -p "$OUT/min"; rm -f "$OUT/min"/* 2>/dev/null || true
: > "$OUT/amplification.min.tsv"
TL="$OUT/tmin.log"; : > "$TL"
if [ "$HANGS" = 1 ]; then TMIN_T=$(( HANG_S * 1000 )); HFLAG=(-H); else TMIN_T=$TIMEOUT; HFLAG=(); fi
n=$(ls "$REPS" | grep -c .); i=0; nfree=0; nexact=0; nkept=0
ts "== minimize $n representative(s) from $REPS with afl-tmin${HARNESS_ENV:+ under $HARNESS_ENV} =="
[ "$LABEL_FORK" != "$FORK" ] && ts "  drift check keyed with $LABEL_FORK"
for c in "$REPS"/*; do
  [ -f "$c" ] || continue
  name=$(basename "$c"); pname=${name#??????-}          # bucket files are <6 hex>-<pool name>
  dst="$OUT/min/$name"; cap=$(capof "$pname"); cap=${cap:-$ALLOC_CAP_MB}
  export ASAN_OPTIONS="$(asan_opts "$cap")"
  i=$((i+1)); ts "  [$i/$n] $name ($(wc -c <"$c") B, ${cap} MB)"
  # Can this harness take its input through /dev/stdin?  If not, afl-tmin cannot be fed.
  if { timeout "$EXEC_S" "$FORK" /dev/stdin <"$c" >/dev/null; } 2>/dev/null; then rc=0; else rc=$?; fi
  if ! reproduces_rc "$rc"; then
    cp "$c" "$dst"; nkept=$((nkept+1)); keyfile "$dst"
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
  keyfile "$dst"
  ts "    $(wc -c <"$c") B -> $(wc -c <"$dst") B${how:+ ($how)}${okey:+  key: $okey}"
  [ "$(cat "$dst.key")" = "${okey:-(no sanitizer report from $(basename "$LABEL_FORK"))}" ] || [ "$HANGS" = 1 ] \
    || ts "    WARN: the kept reproducer's key is now '$(cat "$dst.key")' (nondeterministic report?)"
  run1 "$dst"
  hex=$(sed -n 's/.*\(trying\|failed\) to allocate 0x\([0-9a-f]*\) bytes.*/\2/p' <<<"$R_OUT" | head -1)
  if [ -n "$hex" ]; then
    req=$((16#$hex)); insz=$(wc -c <"$dst")
    printf '%s\t%s\t%s\t%s\t%s\n' "$pname" "$insz" "$req" "$(( req / (insz > 0 ? insz : 1) ))" "$cap" >> "$OUT/amplification.min.tsv"
  fi
done
echo "  afl-tmin: $nfree minimized freely, $nexact needed AFL_TMIN_EXACT, $nkept kept as original -> $OUT/min"
echo "  (do NOT hand-minimize further: the obvious mechanism is often the guarded one)"
