#!/bin/bash
# Harvest candidate axis values from the parser: comparison literals, switch cases,
# magic strings and range bounds.  Output is a reading list, not a corpus.
#   ./enumerate_constants.sh src/parser.c [more files...]
set -uo pipefail
[ $# -gt 0 ] || { echo "usage: $0 <source files>" >&2; exit 2; }
echo "== literals compared with == or != (most frequent first) =="
grep -ohE '[=!]=\s*(0[xX][0-9a-fA-F]+|[0-9]+[uUlL]*)' "$@" | grep -oE '(0[xX][0-9a-fA-F]+|[0-9]+)' | sort | uniq -c | sort -rn | head -30
echo "== switch/case arms (each is an accepted value; look for the default arm) =="
grep -ohE 'case\s+[^:]+:' "$@" | sort | uniq -c | sort -rn | head -30
echo "== range bounds (< > <= >=) =="
grep -ohE '[<>]=?\s*(0[xX][0-9a-fA-F]+|[0-9]+)' "$@" | grep -oE '(0[xX][0-9a-fA-F]+|[0-9]+)' | sort | uniq -c | sort -rn | head -20
echo "== magic / signature comparisons =="
grep -nE 'memcmp|strncmp|\bmagic\b|\bsignature\b|\bsig\b' "$@" | head -15
echo "== conditions naming two fields at once (the grids worth crossing) =="
grep -nE 'if *\(.*(&&|\|\|).*' "$@" | grep -E '\b(len|size|count|depth|bpp|bits|type|flags|version|mode|offset)\b.*\b(len|size|count|depth|bpp|bits|type|flags|version|mode|offset)\b' | head -15
echo "== unchecked reader primitives / unsigned subtraction on input =="
grep -nE '\-\s*[0-9]+\s*\)|false>|unchecked|_idx\+\+|\[i\+\+\]' "$@" | head -15
