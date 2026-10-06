#!/bin/bash
# The static substitute for `A-only` when no sample corpus exists: every error a library
# author wrote on purpose, and which of them your corpus never provokes.
#
#   ./error_inventory.sh SRC=<vendor dir> [RESULTS="maps_<base>/.results [maps_<base>_MODE_x/.results ...]"] \
#                        [PREFIX=XML] [HASHCMD='<cmd reading stdin>']
#
# PREFIX: the library's identifier prefix (XML, PNG, ZIP, ...) so that
# `<PREFIX>_<something>Error<...>` enum members are collected as well as the generic
# `*_ERROR*` ones.  Several: PREFIX='XML|XSLT'.  Default: any 2-8 capital letters.
# RESULTS: measure.sh writes one per corpus (maps_<base>/.results); any file holding
# the harness's result lines works, and several (space-separated: one per harness mode,
# from sweep.sh) are read together.  Each candidate is looked for both as written and
# in the harness's token form (spaces -> '_'), since `err=` is printed that way.
#
# HASHCMD: if the harness prints a HASH of the error text, give the same hash function here
# and each entry is hashed before being looked for.  USE WITH CARE -- it only works when the
# harness hashes exactly the literal in the source.  If the library COMPOSES the message at
# runtime (`"<prefix>: <offending argument>"`), the hashes can never agree, and the script
# then reports a confident, wrong hit count instead of matching nothing.  A low hit rate
# here means "this comparison is not working", not "the corpus is bad".
#
# TRY THIS FIRST.  If the library exposes `*_ErrorString()` / `*_strerror()`, do not grep at
# all: link a ten-line program against it, walk the enum, and you have an exact inventory in
# minutes.  Grepping literals is the fallback, and it is noisy -- expect macros, header
# guards and sanitizer-suppression strings among the candidates.
#
# RESULTS is the concatenated output of running the harness over the corpus -- it only
# tells you anything if the harness prints the library's OWN error name.  If it prints
# just status=0/1, add that field first (most C libraries have *_getErrorName()).
set -uo pipefail
for kv in "$@"; do export "$kv"; done
: "${SRC:?set SRC}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
{
  # enum members that look like error codes
  grep -rhoE '\b[A-Z][A-Z0-9_]*(ERROR|ERR)[A-Z0-9_]*\b' "$SRC" 2>/dev/null
  grep -rhoE "\b(${PREFIX:-[A-Z]{2,8}})_[a-zA-Z]*[Ee]rror[A-Za-z_]*\b" "$SRC" 2>/dev/null
  # error-string literals, which are often the only name a caller ever sees
  grep -rhoE '"[a-z][a-z0-9 ,._-]{9,60}"' "$SRC" 2>/dev/null \
    | grep -iE 'invalid|unsupported|corrupt|unexpected|too (large|small|many)|missing|not (a|supported)|malformed|truncat|overflow|mismatch' 
} | sed 's/^ *//; s/ *$//; s/^"//; s/"$//' | sort -u > "$T/all"
echo "candidate error identifiers in $SRC: $(wc -l < "$T/all")"
for r in ${RESULTS:-}; do [ -f "$r" ] || { echo "FAIL: RESULTS file $r does not exist" >&2; exit 2; }; done
if [ -n "${RESULTS:-}" ]; then
  cat $RESULTS > "$T/results"
  hit=0; miss=0
  : > "$T/missing"
  while IFS= read -r e; do
    needle=$e
    [ -n "${HASHCMD:-}" ] && needle=$(printf '%s' "$e" | eval "$HASHCMD")
    if grep -qF -- "$needle" "$T/results" || grep -qF -- "${needle// /_}" "$T/results"; then hit=$((hit+1))
    else miss=$((miss+1)); echo "$e" >> "$T/missing"; fi
  done < "$T/all"
  echo "reached by the corpus: $hit    never reached: $miss"
  # a near-total miss is a broken comparison, not a bad corpus -- say so at any low rate,
  # not only at exactly zero
  if [ "$miss" != 0 ] && [ "$hit" -le "$(( (hit + miss) / 5 ))" ]; then
    echo "WARNING: $hit of $((hit+miss)) matched. At this rate the comparison itself is" >&2
    echo "         probably broken: a harness that prints a hash or a numeric code" >&2
    echo "         needs HASHCMD=, or the enum route described in the header. Do not read" >&2
    echo "         this as 'the corpus reaches no error paths'." >&2
  fi
  echo "--- never reached (your gap, by name) ---"
  head -40 "$T/missing"
else
  echo "(no RESULTS given -- listing the inventory only)"
  head -40 "$T/all"
  echo
  echo "Next: make the harness print the library's error name, run the corpus into a"
  echo "file, and re-run with RESULTS=<that file> to get the unreached list."
fi
