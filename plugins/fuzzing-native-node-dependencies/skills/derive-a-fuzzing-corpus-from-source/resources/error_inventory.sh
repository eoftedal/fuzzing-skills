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
# It must equal a whole `err=` value, so `ERROR` does not count every err=*ERROR* token
# as reached (with HASHCMD the hash is still looked for anywhere in the line).
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
# Besides the greps, a python3 pass collects every string literal passed inside the
# parentheses of a call whose name contains [Ee]rror or _err (set_scanner_error(parser,
# ctx, mark, "problem"), report_err(...)), across line breaks: a library that hands its
# problem strings to an error setter, one argument per line, has most of its messages there
# and the keyword grep above misses them.  Adjacent literals are joined.
#
# RESULTS is the concatenated output of running the harness over the corpus -- it only
# tells you anything if the harness prints the library's OWN error name.  If it prints
# just status=0/1, add that field first (most C libraries have *_getErrorName()).
set -uo pipefail
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
: "${SRC:?set SRC}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
{
  # enum members that look like error codes
  grep -rIhoE '\b[A-Z][A-Z0-9_]*(ERROR|ERR)[A-Z0-9_]*\b' "$SRC" 2>/dev/null
  grep -rIhoE "\b(${PREFIX:-[A-Z]{2,8}})_[a-zA-Z]*[Ee]rror[A-Za-z_]*\b" "$SRC" 2>/dev/null
  # error-string literals, which are often the only name a caller ever sees
  grep -rIhoE '"[a-z][a-z0-9 ,._-]{9,60}"' "$SRC" 2>/dev/null \
    | grep -iE 'invalid|unsupported|corrupt|unexpected|too (large|small|many)|missing|not (a|supported)|malformed|truncat|overflow|mismatch' 
  # string arguments of error-setter calls, across line breaks
  if command -v python3 >/dev/null; then python3 - "$SRC" <<'PY'
import os, re, sys
tok = re.compile(r'"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'|/\*.*?\*/|//[^\n]*|\w+|[^\s\w]', re.S)
name = re.compile(r'\w*(?:[Ee]rror|_err)\w*$')
exts = ('.c', '.h', '.cc', '.cpp', '.cxx', '.hh', '.hpp', '.inc', '.y', '.l')
out = set()
for root, _, files in os.walk(sys.argv[1]):
    for fn in files:
        if not fn.endswith(exts):
            continue
        try:
            src = open(os.path.join(root, fn), encoding='latin-1').read()
        except OSError:
            continue
        ts = [t for t in tok.findall(src) if not t.startswith(('/*', '//', "'"))]
        i = 0
        while i < len(ts) - 1:
            if ts[i + 1] == '(' and name.match(ts[i]):
                depth, j, cur = 0, i + 1, []
                while j < len(ts):
                    t = ts[j]
                    if t == '(':
                        depth += 1
                    elif t == ')':
                        depth -= 1
                    if t.startswith('"') and len(t) > 1:
                        cur.append(t[1:-1])           # adjacent literals join
                    elif cur:
                        out.add(''.join(cur)); cur = []
                    if depth == 0 or t in (';', '{', '}'):
                        break
                    j += 1
                if cur:
                    out.add(''.join(cur))
            i += 1
for s in out:
    s = re.sub(r'(\\n)+$', '', s).strip()
    if 3 <= len(s) <= 120 and len(re.findall('[A-Za-z]', s)) >= 3:
        print(s)
PY
  else echo "NOTE: no python3; the error-setter argument pass was skipped" >&2; fi
} | sed 's/^ *//; s/ *$//; s/^"//; s/"$//' | sort -u > "$T/all"
echo "candidate error identifiers in $SRC: $(wc -l < "$T/all")"
for r in ${RESULTS:-}; do [ -f "$r" ] || { echo "FAIL: RESULTS file $r does not exist" >&2; exit 2; }; done
if [ -n "${RESULTS:-}" ]; then
  cat $RESULTS > "$T/results"
  # every err= value, one per line: a candidate then matches a whole token, not a substring
  # (the value can be the line's last field, followed by the .results tab, hence [[:space:]])
  grep -oE '(^|[[:space:]])err=[^[:space:]]*' "$T/results" | sed 's/^[[:space:]]*err=//' | sort -u > "$T/errs"
  hit=0; miss=0
  : > "$T/missing"
  while IFS= read -r e; do
    if [ -n "${HASHCMD:-}" ]; then
      # unchanged: a hash may sit in any field, and its fixed width keeps substrings rare
      needle=$(printf '%s' "$e" | eval "$HASHCMD")
      grep -qF -- "$needle" "$T/results" || grep -qF -- "${needle// /_}" "$T/results"
    else
      grep -qxF -e "$e" -e "${e// /_}" "$T/errs"
    fi
    if [ $? = 0 ]; then hit=$((hit+1))
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
