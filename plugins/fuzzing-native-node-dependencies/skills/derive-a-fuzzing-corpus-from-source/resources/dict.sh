#!/bin/bash
# Write an AFL++ dictionary (afl-fuzz -x) from the tokens mutation cannot invent: magic
# strings, option and encoding names, framing separators.  campaign.sh passes the
# workspace's dict.afl by default.
#
#   dict.sh [OUT=./dict.afl] [FROM="out/plain/dict.afl ..."] [TOKENS="tok1 tok2 ..."]
#           [TOKENS_FILE=<one token per line>] [SRC="<source files or dirs>"] [MAXLEN=32]
#
#   FROM         AFL dictionaries to merge (the harness build writes out/<variant>/dict.afl
#                from the compiled compares); names are kept, unnamed lines become from_<n>.
#   TOKENS       raw tokens, split on whitespace.
#   TOKENS_FILE  one raw token per line; \xNN, \n, \t, \r, \0 and \\ are decoded.
#   SRC          files or directories (recursed) the build-time pass did not see: a system
#                library's sources, generated parsers, the JS or Ruby layer whose literals
#                select native paths.  Regex extraction, so expect some noise:
#                  string literals passed to strcmp/strncmp/strcasecmp/strncasecmp/memcmp/strstr,
#                  `case "..."`/`case '...'` arms (and Ruby `when "..."`),
#                  integer constants compared with ==/!= that are 2 to 8 bytes wide, emitted
#                  in little- and big-endian order (width rounded up to 2, 4 or 8).
#                Single-byte literals are skipped: havoc already tries every byte value.
#   MAXLEN       SRC entries longer than this many bytes are skipped (default 32).  Every
#                entry over 128 bytes is skipped: afl-fuzz -x aborts on it (MAX_DICT_FILE).
#
# Entries are deduplicated by decoded bytes (first seen wins: FROM, TOKENS, TOKENS_FILE,
# SRC) and written as name="bytes" with non-printables as \xNN and " and \ escaped.  A named
# path that does not exist is a FAIL (exit 2), and so is an empty result (exit 1): a mistyped
# path must not pass as an empty dictionary.
set -uo pipefail
for kv in "$@"; do case $kv in *=*) export "$kv";; *) echo "FAIL: arguments are KEY=VALUE ($kv)" >&2; exit 2;; esac; done
export OUT=${OUT:-./dict.afl} FROM=${FROM:-} TOKENS=${TOKENS:-} TOKENS_FILE=${TOKENS_FILE:-} SRC=${SRC:-} MAXLEN=${MAXLEN:-32}
command -v python3 >/dev/null || { echo "FAIL: dict.sh needs python3" >&2; exit 2; }
python3 - <<'PY'
import os, re, sys

OUT = os.environ["OUT"]; MAXLEN = int(os.environ["MAXLEN"]); AFL_MAX = 128
def fail(msg, rc=2):
    print("FAIL: " + msg, file=sys.stderr); sys.exit(rc)

entries = []                     # (name, bytes)
seen = set()
skip = {"dup": 0, "maxlen": 0, "afl_max": 0, "empty": 0}
def add(name, b, cap):
    if not b: skip["empty"] += 1; return False
    if len(b) > AFL_MAX: skip["afl_max"] += 1; return False
    if len(b) > cap: skip["maxlen"] += 1; return False
    if b in seen: skip["dup"] += 1; return False
    seen.add(b); entries.append((name, b)); return True

def enc(b):
    out = []
    for c in b:
        if c == 0x22: out.append('\\"')
        elif c == 0x5c: out.append('\\\\')
        elif 0x20 <= c < 0x7f: out.append(chr(c))
        else: out.append('\\x%02x' % c)
    return '"' + ''.join(out) + '"'

def ident(s): return re.sub(r'[^A-Za-z0-9_]', '_', s)
def paths(var):
    ps = os.environ[var].split()
    for p in ps:
        if not os.path.exists(p): fail("%s: no such file or directory: %s" % (var, p))
    return ps

# ---- FROM: AFL syntax, [name[@level]=]"value" ------------------------------------------
afl_line = re.compile(r'^([A-Za-z0-9_]*(?:@[0-9]+)?)\s*=?\s*"(.*)"$')
def afl_decode(v, where):
    b = bytearray(); i = 0
    while i < len(v):
        c = v[i]
        if c == '\\':
            n = v[i + 1:i + 2]
            if n in ('\\', '"'): b.append(ord(n)); i += 2; continue
            if n == 'x' and re.match(r'[0-9A-Fa-f]{2}$', v[i + 2:i + 4]):
                b.append(int(v[i + 2:i + 4], 16)); i += 4; continue
            fail("%s: invalid escape (afl-fuzz takes only \\\\, \\\" and \\xNN)" % where)
        b.extend(c.encode('latin-1', 'replace')); i += 1
    return bytes(b)

counts = []
k = 0
for p in paths("FROM"):
    n = 0
    with open(p, encoding='latin-1') as f:
        for ln, line in enumerate(f, 1):
            s = line.strip()
            if not s or s.startswith('#'): continue
            m = afl_line.match(s)
            if not m: fail("%s:%d: not an AFL dictionary line: %s" % (p, ln, s[:60]))
            k += 1
            if add(m.group(1) or "from_%d" % k, afl_decode(m.group(2), "%s:%d" % (p, ln)), AFL_MAX): n += 1
    counts.append(("FROM " + p, n))

# ---- TOKENS / TOKENS_FILE ------------------------------------------------------------------
k = 0; n = 0
for t in os.environ["TOKENS"].split():
    k += 1; n += add("tok_%d" % k, t.encode(), AFL_MAX)
if os.environ["TOKENS"].strip(): counts.append(("TOKENS", n))

esc = re.compile(rb'\\(x[0-9A-Fa-f]{2}|[ntr0\\])')
def tok_decode(m):
    g = m.group(1)
    if g[:1] == b'x': return bytes([int(g[1:], 16)])
    return {b'n': b'\n', b't': b'\t', b'r': b'\r', b'0': b'\0', b'\\': b'\\'}[g]
for p in paths("TOKENS_FILE"):
    n = 0
    with open(p, 'rb') as f:
        for line in f:
            line = line.rstrip(b'\r\n')
            if not line: continue
            k += 1; n += add("tok_%d" % k, esc.sub(tok_decode, line), AFL_MAX)
    counts.append(("TOKENS_FILE " + p, n))

# ---- SRC: regex extraction -------------------------------------------------------------------
EXT = re.compile(r'\.(c|h|cc|cpp|cxx|hh|hpp|hxx|inc|def|y|yy|l|ll|rl|re|gperf|js|mjs|cjs|ts|rb)$')
def src_files():
    for p in paths("SRC"):
        if os.path.isfile(p): yield p
        else:
            for d, dirs, fs in os.walk(p):
                dirs[:] = [x for x in dirs if x not in ('.git', 'node_modules')]
                for x in sorted(fs):
                    if EXT.search(x): yield os.path.join(d, x)

C_ESC = {'n': 10, 't': 9, 'r': 13, '0': 0, 'a': 7, 'b': 8, 'f': 12, 'v': 11, 'e': 27,
         '\\': 92, '"': 34, "'": 39, '?': 63, '/': 47}
def lit_decode(body):        # C, JS and Ruby escapes, approximately
    b = bytearray(); i = 0
    while i < len(body):
        c = body[i]
        if c != '\\': b.extend(c.encode('utf-8')); i += 1; continue
        n = body[i + 1:i + 2]
        m = re.match(r'x([0-9A-Fa-f]{1,2})', body[i + 1:])
        if m: b.append(int(m.group(1), 16)); i += 1 + len(m.group(0)); continue
        m = re.match(r'[0-7]{1,3}', body[i + 1:])
        if m: b.append(int(m.group(0), 8) & 0xff); i += 1 + len(m.group(0)); continue
        m = re.match(r'u([0-9A-Fa-f]{4})', body[i + 1:])
        if m: b.extend(chr(int(m.group(1), 16)).encode('utf-8')); i += 6; continue
        if n in C_ESC: b.append(C_ESC[n]); i += 2; continue
        b.extend(n.encode('utf-8')); i += 2
    return bytes(b)

LIT = r'"((?:[^"\\\n]|\\.)*)"|\'((?:[^\'\\\n]|\\.)*)\''
CALL = re.compile(r'\b(?:strn?cmp|strn?casecmp|memcmp|strstr)\s*\(')
CASE = re.compile(r'\b(?:case|when)\s+(?:' + LIT + r')')
LITS = re.compile(r'(?:' + LIT + r')(?:\s*(?:' + LIT + r'))*')      # adjacent C literals concatenate
INT = r'(0[xX][0-9A-Fa-f]+|[0-9]+)[uUlL]*\b'
CMP = re.compile(r'(?:[!=]=\s*' + INT + r')|(?:\b' + INT + r'\s*[!=]=)')

def call_args(text, start):   # literals in one call's argument list, parens balanced
    depth = 1; i = start; out = []
    while i < len(text) and depth:
        c = text[i]
        if c in '"\'':
            m = LITS.match(text, i)
            if m:
                out.append(b''.join(lit_decode(x) for x in re.findall(r'"((?:[^"\\\n]|\\.)*)"', m.group(0)))
                           if c == '"' else lit_decode(m.group(2) or ''))
                i = m.end(); continue
        depth += c == '('; depth -= c == ')'; i += 1
    return out

def int_bytes(tok):
    v = int(tok, 16) if tok[:2] in ('0x', '0X') else int(tok)
    need = (len(tok) - 1) // 2 if tok[:2] in ('0x', '0X') else (v.bit_length() + 7) // 8
    need = max(need, (v.bit_length() + 7) // 8)
    if need < 2 or need > 8: return []
    w = 2 if need <= 2 else 4 if need <= 4 else 8
    return [v.to_bytes(w, 'little'), v.to_bytes(w, 'big')]

nfiles = 0; ns = 0; ni = 0
for p in src_files():
    try:
        text = open(p, encoding='utf-8', errors='replace').read()
    except OSError as e:
        fail("SRC: %s" % e)
    nfiles += 1; tag = ident(os.path.basename(p)); j = 0
    found = []
    for m in CALL.finditer(text): found += [("s", b) for b in call_args(text, m.end())]
    for m in CASE.finditer(text):
        found.append(("s", lit_decode(m.group(1) if m.group(1) is not None else m.group(2))))
    for m in CMP.finditer(text):
        found += [("i", b) for b in int_bytes(m.group(1) or m.group(2))]
    for kind, b in found:
        if len(b) < 2: continue
        j += 1
        if add("src_%s_%d" % (tag, j), b, MAXLEN):
            if kind == "s": ns += 1
            else: ni += 1
if os.environ["SRC"].strip():
    counts.append(("SRC (%d files: %d literals, %d integer byte orders)" % (nfiles, ns, ni), ns + ni))

for what, n in counts: print("  %-52s %d new entries" % (what, n))
print("  skipped: %d duplicates, %d over MAXLEN=%d (SRC), %d over %d bytes, %d empty"
      % (skip["dup"], skip["maxlen"], MAXLEN, skip["afl_max"], AFL_MAX, skip["empty"]))
if not entries:
    fail("no entries: nothing written to %s (check FROM/TOKENS/TOKENS_FILE/SRC)" % OUT, 1)
d = os.path.dirname(OUT)
if d: os.makedirs(d, exist_ok=True)
with open(OUT + ".tmp", "w") as f:
    for name, b in entries: f.write("%s=%s\n" % (name, enc(b)))
os.replace(OUT + ".tmp", OUT)
print("wrote %d entries to %s" % (len(entries), OUT))
PY
