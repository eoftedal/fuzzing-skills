#!/bin/bash
# Build a small gate corpus from a few valid samples, so the gate's checks have both arms
# to compare instead of a hand-invented set.
#
#   $R/mkgate.sh OUT=./corpus SAMPLES="<file> [<file>...]" [TRUNC=3] [FLIPS=3] [EMPTY=1]
#
# For each sample it writes into OUT:
#   <sample>          the sample itself (left alone when it already lives in OUT)
#   <sample>.truncN   TRUNC truncations, at roughly 1/4, 1/2, 3/4 of the length (TRUNC
#                     evenly spaced cuts), always at least one byte off the end
#   <sample>.flipN    FLIPS corruptions at deterministic offsets: odd N flips one bit, even
#                     N replaces one byte.  The offsets are seeded by the sample's name, so
#                     a re-run writes the same files
# and, with EMPTY=1 (default), a zero-byte `empty` file: the gate accepts it, the corpus
# skill keeps it out of corpus-final.
#
# This is a starting point, not the corpus: check 3 needs BOTH arms, so at least one
# truncation or corruption must be rejected by the library, and the seeds that take each
# MODE branch (one per entry point) still come from you.
set -uo pipefail
for kv in "$@"; do case $kv in *=*) export "$kv";; *) echo "mkgate.sh: not KEY=VALUE: $kv" >&2; exit 2;; esac; done
OUT=${OUT:-./corpus}; SAMPLES=${SAMPLES:-}; TRUNC=${TRUNC:-3}; FLIPS=${FLIPS:-3}; EMPTY=${EMPTY:-1}
[ -n "$SAMPLES" ] || { echo "mkgate.sh: SAMPLES=\"<file> [<file>...]\" is required" >&2; exit 2; }
mkdir -p "$OUT" && OUT=$(cd "$OUT" && pwd) || exit 2
n=0; skipped=0
byte_at() { od -An -tu1 -j "$2" -N1 "$1" | tr -d ' '; }
put() {  # <src> <offset> <new byte value> <dst>: src with one byte replaced
  { head -c "$2" "$1"; printf "\\$(printf '%03o' "$3")"; tail -c +$(( $2 + 2 )) "$1"; } > "$4"
}
for s in $SAMPLES; do
  [ -f "$s" ] || { echo "  WARN: no such sample: $s" >&2; skipped=$((skipped+1)); continue; }
  b=$(basename "$s"); len=$(wc -c < "$s" | tr -d ' ')
  [ "$(cd "$(dirname "$s")" && pwd)/$b" = "$OUT/$b" ] || cp "$s" "$OUT/$b"; n=$((n+1))
  [ "$len" -gt 1 ] || { echo "  NOTE: $b is $len byte(s): no truncations or corruptions"; continue; }
  # truncations: cut j*len/(TRUNC+1), clamped to 1..len-1, duplicates dropped
  last=-1; k=0
  for ((j = 1; j <= TRUNC; j++)); do
    c=$(( len * j / (TRUNC + 1) )); [ "$c" -lt 1 ] && c=1; [ "$c" -gt $((len - 1)) ] && c=$((len - 1))
    [ "$c" = "$last" ] && continue; last=$c; k=$((k+1))
    head -c "$c" "$s" > "$OUT/$b.trunc$k"; n=$((n+1))
  done
  # corruptions: an LCG seeded by the name picks the offset, so a re-run is identical
  seed=$(printf '%s' "$b" | cksum | cut -d' ' -f1)
  for ((j = 1; j <= FLIPS; j++)); do
    seed=$(( (seed * 1103515245 + 12345) % 2147483648 ))
    off=$(( seed % len )); v=$(byte_at "$s" "$off")
    if [ $((j % 2)) = 1 ]; then nv=$(( v ^ (1 << ((seed >> 8) % 8)) ))
    else nv=255; [ "$v" = 255 ] && nv=0; fi
    put "$s" "$off" "$nv" "$OUT/$b.flip$j"; n=$((n+1))
  done
done
[ "$EMPTY" = 1 ] && { : > "$OUT/empty"; n=$((n+1)); }
miss=""; [ "$skipped" -gt 0 ] && miss=" ($skipped sample(s) missing)"
echo "mkgate.sh: wrote $n file(s) to $OUT$miss"
echo "  Check 3 needs both arms: at least one truncation or corruption should be rejected by the"
echo "  library (if the gate shows one outcome, add an input it must refuse)."
echo "  Seeds that take each MODE branch (one per entry point) still come from you: add them to $OUT."
