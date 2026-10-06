#!/bin/bash
# Set differences between two map directories, then attribute the gap.
#   A=maps_baseline B=maps_derived ./compare.sh
# A-only is YOUR GAP: edges the existing corpus reaches and yours does not.
set -uo pipefail
for kv in "$@"; do export "$kv"; done
: "${A:?set A}" "${B:?set B}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat "$A"/* 2>/dev/null | cut -d: -f1 | sort -u > "$T/a"
cat "$B"/* 2>/dev/null | cut -d: -f1 | sort -u > "$T/b"
printf 'A (%s)      %s edges\n' "$A" "$(wc -l < "$T/a")"
printf 'B (%s)      %s edges\n' "$B" "$(wc -l < "$T/b")"
printf 'B-only (B finds, A misses)  %s\n' "$(comm -13 "$T/a" "$T/b" | wc -l)"
printf 'A-only (YOUR GAP)           %s\n' "$(comm -23 "$T/a" "$T/b" | wc -l)"
comm -23 "$T/a" "$T/b" > "$T/gap"
[ -s "$T/gap" ] || { echo "gap is empty: B subsumes A"; exit 0; }
echo "which A files hold the edges B misses:"
for m in "$A"/*; do
  [ -f "$m" ] || continue
  c=$(cut -d: -f1 "$m" | sort -u | comm -12 - "$T/gap" | wc -l)
  if [ "$c" != 0 ]; then printf '  %-5s %s\n' "$c" "$(basename "$m")"; fi
done | sort -rn | head -20
exit 0
