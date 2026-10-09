#!/bin/bash
# Bucket the minimized crashes by their ROOT CAUSE, not by count, and copy one
# representative (the smallest) of each bucket to OUT/buckets/.  The key is the
# sanitizer SUMMARY line: kind + file:line + function + the access (READ/WRITE and size).
# Do NOT bucket on the #0..#2 frames -- with a template-heavy C++ library the frame text
# begins with the RETURN TYPE, so half your crashes bucket under "char".
#
#   bucket.sh FORK=<the harness screen.sh used> [OUT=./triage] [INPUTS=<dir>]
#             [LABEL_FORK=<the ASAN harness>] [CELL_TIMEOUT=30] [ALLOC_CAP_MB=1024]
#             [HARNESS_ENV=...]   (default: the mode recorded in OUT/config)
#             [HANG_SAMPLE_S="1.5 1.75 ... 4.25"]   when each (parallel) stack sample is taken
#             [HANGS=1]   bucket hangs by stack sampling (default: from OUT/config)
#
# The SUMMARY key OVER-separates, so the script ALWAYS prints three groupings (there is no
# flag; you get all three) and you report the merged one:
#   exact   kind @ file:line in function [ACCESS]   (file is a basename; line `?` when the
#           symbolizer gave none)
#   merged  the same with the line number dropped
#   caller  kind <- the first project frame below the crashing function [READ|WRITE].  One
#           run: eight buckets, six per-encoding writer functions, one caller passing an
#           unchecked remaining size to all of them.  A shared caller shows as one line;
#           judge whether it is the bug (a dispatcher above unrelated bugs collapses too).
# One real run (a stylesheet-compiler binding, 111 ASAN crashes): the exact key gives 6
# buckets, the merged key gives 4 -- and 4 is the published answer, because one over-read
# in an unchecked UTF-8 decoder is reported at three lines of one header (:76, :82, :84).  Merge buckets that
# differ only in line number inside one function.  When deciding whether two reports are
# the same bug, compare the ALLOCATION and the ACCESS, not the frame text: inlining
# differs between the instrumented and the pristine build, which name different frame #0s
# for the identical bug.
#
# A crash with no sanitizer report is split two ways, and the difference matters:
#   NO-REPORT signal-only sigN   it DID crash, with no sanitizer frame.  Most often stack
#                               exhaustion in a recursive-descent parser -- a real,
#                               reportable DoS that needs no sanitizer at all (a
#                               stylesheet-compiler binding: 13 of 13 crashes from the
#                               instrumented-only build, the smallest reproducer 170 bytes
#                               of valid ASCII).  Not noise.
#   NO-CRASH (rc=N)             it did not crash here at all: the wrong variant's harness,
#                               or a persistent-mode artifact.
# Conflating the two is how a "these are all non-reproducible" conclusion gets written.
set -uo pipefail
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
FORK=${FORK:?set FORK=the fork harness screen.sh used}
# LABEL_FORK: the harness used to NAME the bug, which is not always the one that reproduces
# it.  screening must use the build that produced the crash (fidelity), but only a
# SANITIZED build prints a SUMMARY line, and the SUMMARY line is the bucket key.  Bucketing
# a plain-campaign pool against the plain harness therefore yields `NO-REPORT signal-only
# sig11` for everything, which groups correctly and tells you nothing.  So: label with
# LABEL_FORK (the ASAN build) when the input reproduces there, and fall back to FORK when it
# does not.  The fall-back is a safety net: across 161 real crashes no input crashed the
# plain build without also crashing the ASAN one.
LABEL_FORK=${LABEL_FORK:-$FORK}
# INPUTS: the RAW reproducers screen.sh wrote (OUT/repro), not minimized ones.  Bucketing
# needs only a sanitizer report, so it runs before the expensive minimization, which then
# handles one representative per bucket.  Measured: 111 raw crashes from a stylesheet-compiler binding bucket to
# exactly the 4 published bugs.  (MIN= is accepted as an old alias.)
OUT=${OUT:-./triage}; MIN=${INPUTS:-${MIN:-$OUT/repro}}
HANGS=${HANGS:-$(sed -n 's/^HANGS=//p' "$OUT/config" 2>/dev/null)}; HANGS=${HANGS:-0}
# Hangs have no sanitizer report, so on their own they all fall into one bucket.  Instead,
# interrupt the sanitized harness with SIGABRT at a few points in time (ASAN prints a
# symbolized stack on SIGABRT with handle_abort=1) and key on the innermost LIBRARY frame
# every sample shares -- where the loop lives.  A single sample is noisy: its top frame is
# wherever the loop happened to be (operator delete, a stringbuf internal).
HANG_SAMPLE_S=${HANG_SAMPLE_S:-"1.5 1.75 2 2.25 2.5 2.75 3 3.25 3.5 3.75 4 4.25"}
CELL_TIMEOUT=${CELL_TIMEOUT:-30}   # seconds per input; a hang pool needs it
# FORCE symbolize=1 instead of deferring to the environment.  screen.sh and minimize.sh export
# symbolize=0 (afl-tmin requires it), so running both steps in one shell left
# that value in place and every bucket key degraded to raw hex --
#   heap-buffer-overflow (harness-fork+0x152744) (BuildId: ...)
# instead of a symbolized `file:line in <function>` naming the GIF decoder.  Measured: the keys still group
# correctly, but they are build-specific, unreadable, and useless in a report.  Extra
# options from the environment are kept; the ones this step depends on are not negotiable.
# The ceiling is PER INPUT: screen.sh records in OUT/cap.tsv the ceiling each input
# reproduced at, and a declared-size bug only reproduces at or below it.  ALLOC_CAP_MB is
# the fallback for inputs not in that file.  The ceiling is appended LAST so an inherited
# ASAN_OPTIONS cannot override it (it used to).
ALLOC_CAP_MB=${ALLOC_CAP_MB:-1024}
ASAN_BASE="${ASAN_OPTIONS:-detect_leaks=0:allocator_may_return_null=1}"
capof() { [ -f "$OUT/cap.tsv" ] && awk -F'\t' -v n="$1" '$1==n{print $2; exit}' "$OUT/cap.tsv"; }
# Run in the same harness mode screen.sh used (OUT/config), unless overridden: a crash
# found under MODE=2 does not reproduce in the default mode.
if [ -z "${HARNESS_ENV:-}" ] && [ -f "$OUT/config" ]; then
  HARNESS_ENV=$(sed -n 's/^HARNESS_ENV=//p' "$OUT/config")
fi
for kv in ${HARNESS_ENV//,/ }; do export "$kv"; done   # several settings may be joined with commas
mkdir -p "$OUT/buckets"; rm -f "$OUT/buckets"/* 2>/dev/null || true
# Timestamped progress.  Every long loop below reports, because a triage pipeline has
# several steps that can legitimately take minutes and at least two that can hang outright
# (see references/afl-tool-reliability.md) -- and silence is indistinguishable from a stall.
# T0 is script start; each line carries wall-clock time and elapsed seconds.
T0=$(date +%s)
ts() { printf '[%s +%ds] %s\n' "$(date +%H:%M:%S)" "$(( $(date +%s) - T0 ))" "$*"; }
# progress for a loop: ts() at most once every PROGRESS_EVERY seconds, plus the final item
PROGRESS_EVERY=${PROGRESS_EVERY:-20}
_plast=0
prog() { # <done> <total> <what>
  local now; now=$(date +%s)
  if [ "$1" = "$2" ] || [ $((now - _plast)) -ge "$PROGRESS_EVERY" ]; then
    _plast=$now; ts "    $1/$2 $3"
  fi
}
K=$(mktemp); trap 'rm -f "$K"' EXIT
nmin=$(ls "$MIN" 2>/dev/null | grep -vc '^README' || true); seen=0
ts "bucketing $nmin input(s) from $MIN (label harness: $LABEL_FORK${HARNESS_ENV:+, mode $HARNESS_ENV})"

# Collapse C++ template arguments to <>.  A SINGLE pass is not enough: `<[^<>]*>` cannot
# match a template whose arguments contain another template, so
# `match<&Constants::brace_token.<>>` and `match<>` stay distinct and one bug splits
# into two buckets (measured on a stylesheet-compiler binding).  Collapse innermost-first to a placeholder,
# repeat to a fixpoint, then restore.
collapse() {
  local p=$1 n
  while :; do n=$(printf '%s' "$p" | sed 's/<[^<>]*>/\x01/g'); [ "$n" = "$p" ] && break; p=$n; done
  printf '%s' "$p" | sed 's/\x01/<>/g'
}

# ---- bug key: twin of minimize.sh's copy; keep the two identical (from ICEPTOR to sum_key) ----
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
# The caller grouping: the first project frame below the crashing function (the site, or the
# frame an interceptor was keyed on), skipping recursion into it.  The harness template's
# driver (run_one, main) is no caller: every function it calls directly would share it.
caller_of() {  # <sanitizer output> <key> -> "function @ file", or empty
  local site=${2#* in }; site=${site% \[via *}
  frames_of "$1" | awk -F'\t' -v s="$site" 'NR==1{s0=$1} $1==s || $1==s0 {next}
                                           $1 ~ /^(main|run_one|LLVMFuzzerTestOneInput)(\(|$)/ {exit}
                                           {print $1 " @ " $2; exit}'
}

# The frames of one sample that belong to the library: symbolized with a source file, not
# the sanitizer runtime, libc/libstdc++ (/usr/...), or the harness's own main/run loop.
lib_frames() {
  sed -n 's/^ *#[0-9]* 0x[0-9a-f]* in \(.*\) \(\/[^ ]*\):[0-9]*\(:[0-9]*\)\{0,1\}$/\1\t\2/p' \
    | grep -vE $'\t/usr/|sanitizer|compiler-rt' \
    | awk -F'\t' '{n=$2; sub(/.*\//,"",n); sub(/(:[0-9]+)+$/,"",n); if (n ~ /^harness/ || $1 ~ /^main$/) next; print $1 " @ " n}'
}
hang_key() {  # <file> -> a bucket key for a hang
  local f=$1 t smp=() frames k common out j=0 d
  d=$(mktemp -d)
  # Samples are independent processes, so run them IN PARALLEL: 12 samples cost the wall
  # time of the longest one (~4 s), not 12 runs end to end.
  for t in $HANG_SAMPLE_S; do
    j=$((j+1))
    ( { ASAN_OPTIONS="$ASAN_BASE:handle_abort=1:symbolize=1:detect_leaks=0" \
        timeout --foreground -s ABRT "$t" "$LABEL_FORK" "$f" 2>"$d/s$j" >/dev/null; } 2>/dev/null ) &
  done
  wait
  for out in "$d"/s*; do
    frames=$(lib_frames < "$out")
    [ -n "$frames" ] && smp+=("$frames")
  done
  rm -rf "$d"
  if [ "${#smp[@]}" = 0 ]; then echo "NO-REPORT hang (no stack: the sanitized build answered or gave none)"; return; fi
  # Key on the innermost frame that is (a) on the stack in EVERY sample and (b) never
  # recurs in ANY sample.  Why both: a loop that keeps re-walking a tree (an interpreter's
  # visitor -- the compiler library's evaluate/expand passes) puts the same functions on the stack
  # several times, and which of them is innermost at a given instant is chance.  Measured
  # on 8 real hangs in a stylesheet-compiler binding: keying on the innermost common frame flipped between three
  # visitor functions on 6 of 8, run to run, even with 12 samples; keying on the SET of
  # recurring functions flipped too, because one of them sat right at any threshold.  The
  # first non-recurring frame is stable: for a plain loop beneath the walk it is the loop
  # itself (a colour built-in function), and for a loop that IS the walk it is the first
  # frame above the visitor -- coarse, flagged as such, members listed in keys.tsv.
  local rec names k
  rec=$(for frames in "${smp[@]}"; do sed 's/(.*) @ / @ /' <<<"$frames" | sort | uniq -d; done | sort -u)
  while read -r k; do
    names=$(sed 's/(.*) @ / @ /' <<<"$k")
    [ -n "$rec" ] && grep -qxF "$names" <<<"$rec" && continue
    common=1
    for frames in "${smp[@]}"; do sed 's/(.*) @ / @ /' <<<"$frames" | grep -qxF "$names" || { common=0; break; }; done
    if [ "$common" = 1 ]; then
      if [ -n "$rec" ]; then echo "hang in $names (inside a recursive walk)"; else echo "hang in $names"; fi
      return
    fi
  done <<<"${smp[0]}"
  echo "hang in $(collapse "$(head -1 <<<"${smp[0]}")") (no frame common to all samples)"
}

for c in "$MIN"/*; do
  [ -f "$c" ] || continue
  case "$(basename "$c")" in README*) continue;; esac   # AFL's own README.txt is not a crash
  # timeout, and the announcements redirected: bash reports every child that dies on a
  # signal on its own stderr (one line per input here), and without the timeout a HANGS=1
  # pool would wedge this loop on its first input forever.
  cap=$(capof "$(basename "$c")"); cap=${cap:-$ALLOC_CAP_MB}
  # allocator_may_return_null=1 forced too: it is what the screen ran with, and the key must
  # describe the crash AS SCREENED.  Without it the same input was labelled
  # `allocation-size-too-big` here but crashed as a NULL dereference in the screen.
  export ASAN_OPTIONS="$ASAN_BASE:allocator_may_return_null=1:max_allocation_size_mb=$cap:symbolize=1:exitcode=86"
  if [ "$HANGS" = 1 ]; then
    key=$(hang_key "$c")
    acc=""
    prov=$(basename "$c" | sed -n 's/^[0-9]\{4\}-\([^-]*\)-.*/\1/p')
    printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$(wc -c <"$c")" "$c" "${prov:-?}" "$key" >> "$K"
    seen=$((seen+1)); prog "$seen" "$nmin" "bucketed (last key: $(cut -c1-60 <<<"$key"))"
    continue
  fi
  labeller=$LABEL_FORK
  out=$( { timeout "$CELL_TIMEOUT" "$labeller" "$c" 2>&1; } 2>/dev/null )
  rc=$?                                                  # on its own line, immediately
  if [ "$labeller" != "$FORK" ] && ! grep -q 'SUMMARY: [A-Za-z]*Sanitizer:' <<<"$out"; then
    labeller=$FORK                                       # not visible to the sanitizer
    out=$( { timeout "$CELL_TIMEOUT" "$labeller" "$c" 2>&1; } 2>/dev/null )
    rc=$?
  fi
  acc=$(sed -n 's/.*\(READ\|WRITE\) of size \([0-9]*\).*/\1-\2/p' <<<"$out" | head -1)
  key=$(sum_key "$out")
  if [ -z "$key" ]; then
    if   [ "$rc" = 124 ];   then key="NO-REPORT hang (no answer in ${CELL_TIMEOUT}s)"
    elif [ "$rc" -ge 128 ]; then key="NO-REPORT signal-only sig$((rc-128))"
    elif [ "$rc" = 0 ];     then key="NO-CRASH (rc=0, did not reproduce)"
    else                         key="NO-CRASH (rc=$rc, no sanitizer report)"; fi
    ckey=$key
  else
    case $key in *" [via "*) acc=${acc%%-*};; esac      # an interceptor's size is the caller's argument
    cfn=$(caller_of "$out" "$key")
    if [ -n "$cfn" ]; then ckey="${key%% *} <- $(collapse "$cfn")${acc:+ [${acc%%-*}]}"
    else ckey="$(sed 's/\(@ [A-Za-z0-9_.+-]*\):[0-9?]*/\1:*/' <<<"$key")${acc:+ [${acc%%-*}]} (no caller frame)"; fi
  fi
  [ -n "$acc" ] && key="$key [$acc]"
  # provenance (the build variant) is the middle field of the pool name screen.sh made
  prov=$(basename "$c" | sed -n 's/^[0-9a-f]\{6\}-//; s/^[0-9]\{4\}-\([^-]*\)-.*/\1/p')
  printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$(wc -c <"$c")" "$c" "${prov:-?}" "$ckey" >> "$K"
  seen=$((seen+1)); prog "$seen" "$nmin" "bucketed (last key: $(cut -c1-60 <<<"$key"))"
done
[ -s "$K" ] || { echo "no crashes in $MIN" >&2; exit 1; }
# every input -> its bucket key, so a reader can see which inputs a bucket holds
awk -F'\t' '{n=$3; sub(/.*\//,"",n); print n "\t" $1}' "$K" | sort > "$OUT/keys.tsv"

echo "== buckets (exact key; one representative each, the smallest) =="
sort -t$'\t' -k1,1 -k2,2n "$K" | awk -F'\t' '!seen[$1]++' | while IFS=$'\t' read -r key sz c prov ckey; do
  n=$(printf '%s' "$key" | md5sum | cut -c1-6)
  cp "$c" "$OUT/buckets/$n-$(basename "$c")"
  printf '  %s  %5s B  %-8s %s\n' "$n" "$sz" "$prov" "$key"
done
echo "== distribution, exact key ($(cut -f1 "$K" | sort -u | wc -l) buckets) =="
cut -f1 "$K" | sort | uniq -c | sort -rn | sed 's/^/  /'
echo "== distribution, MERGED on function ($(sed 's/\(@ [A-Za-z0-9_.+-]*\):[0-9?]*/\1:*/' <(cut -f1 "$K") | sort -u | wc -l) group(s)) =="
echo "   report these: one row per group. The per-line split above over-separates."
echo "   When the caller grouping below collapses several functions into one, judge whether that is the bug."
cut -f1 "$K" | sed 's/\(@ [A-Za-z0-9_.+-]*\):[0-9?]*/\1:*/' | sort | uniq -c | sort -rn | sed 's/^/  /'
echo "== distribution, MERGED on caller ($(cut -f5 "$K" | sort -u | wc -l) group(s)) =="
echo "   kind <- the first project frame below the crashing function; the functions it covers in ()"
awk -F'\t' '{fn=$1; sub(/ \[[A-Z]+(-[0-9]+)?\]$/,"",fn); sub(/ \[via [^]]*\]$/,"",fn); sub(/^.* in /,"",fn)
             n[$5]++; if (!((($5) SUBSEP fn) in s)) {s[$5,fn]=1; f[$5]=f[$5] (f[$5]=="" ? "" : ", ") fn; nf[$5]++}}
     END{for (k in n) printf "%7d %s  (%d function%s: %s)\n", n[k], k, nf[k], (nf[k]==1 ? "" : "s"), f[k]}' "$K" | sort -rn | sed 's/^/  /'
# An out-of-memory bucket is a declared-size DoS; the ratio is the severity, so surface it
# here rather than leaving it in screen.sh's log.
# Keyed on the amplification file, not on the bucket text: ASAN names the same class
# `out-of-memory` (C++ new), `allocation-size-too-big` (malloc), or -- once the library
# dereferences the NULL it got back -- a plain SEGV.
AMPF="$OUT/amplification.tsv"
if [ -s "$AMPF" ]; then
  echo "== memory amplification (declared-size denial of service) =="
  echo "   a small input demanding this much memory is a denial of service by itself"
  sort -t$'\t' -k4,4 -rn "$AMPF" | head -5 \
    | while IFS=$'\t' read -r nm insz req ratio capmb; do
        printf '  %-44s %6s B in -> %14s B demanded  (%sx at %s MB)\n' "$(cut -c1-44 <<<"$nm")" "$insz" "$req" "$ratio" "$capmb"; done
fi
echo "next: confirm.sh  (then minimize.sh, which works on these representatives)"
echo "      confirm.sh PKG=<fresh npm install>/node_modules/<pkg> [ADDON=...] [PRISTINE=...] [ASAN_RT=...] OUT=$OUT"
