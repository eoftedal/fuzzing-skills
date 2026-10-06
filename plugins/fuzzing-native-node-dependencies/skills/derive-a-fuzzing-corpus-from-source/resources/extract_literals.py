#!/usr/bin/env python3
"""Extract a corpus from string literals in a library's own test source.

Libraries whose tests are compiled, rather than loaded from disk, often carry hundreds of
documents inline. That is a corpus written by the people who wrote the parser, and nothing
in the binding's repo hints it exists.

    extract_literals.py OUT=./corpus-fixtures STARTS='<' SRC=lib/tests/runtests.c [SRC=...]
    extract_literals.py OUT=./corpus-fixtures RE='^(\\x89PNG|GIF8)' SRC=test/*.c

    OUT     directory to write into (one file per unique literal)
    SRC     one or more source files: repeat the key, pass a glob, or one quoted
            whitespace-separated list (SRC="a.c b.c").  A path that does not exist is
            an error (exit 1), not a silent "0 unique literals".
    STARTS  keep a literal only if it contains this substring (default '<')
    RE      instead of STARTS, keep it if this regex matches the decoded BYTES
    ALL=1   keep EVERY literal -- use this when the format has no signature byte to filter
            on (patterns, queries, source text). The defaults are tuned for a format with a
            recognisable opening, and on a signature-less format they discard almost
            everything: one target yielded 30 literals with the defaults and 2444 with ALL=1,
            the latter worth hundreds of edges the former never reached.
    MINLEN  minimum decoded length to keep (default 4)
    LANG    c | js | auto   (default auto, by file extension)
    JSREGEX=1 also extract JS REGEX LITERALS (/pattern/flags) from .js/.mjs/.ts sources --
            the dominant fixture form in a regex binding's own tests.  The pattern text
            is written, flags are dropped.  Expect a few false positives from division.
    DECODE  hex | base64    fixtures written as an ENCODED string (a complete binary record
                            spelled out as hex in a test file is common); applied BEFORE
                            RE/STARTS/MINLEN, so those match the real bytes

Handles what actually bites: C and JS escapes including \\xNN, \\NNN octal, \\uNNNN and
\\u{...}; line continuations; both quote styles; and ADJACENT LITERAL CONCATENATION, which
is how multi-line documents are written in C test suites. Comments between adjacent
literals are tolerated.
"""
import os, re, sys, glob

args, srcs = {}, []
def add_src(v):
    hits = glob.glob(v)
    if not hits and ' ' in v.strip():          # SRC="a b c": one argument holding a list
        for part in v.split(): add_src(part)
        return
    srcs.extend(hits or [v])
for a in sys.argv[1:]:
    if '=' in a:
        k, v = a.split('=', 1)
        if k == 'SRC': add_src(v)
        else: args[k] = v
    else:
        add_src(a)
OUT    = args.get('OUT', './corpus-fixtures')
STARTS = args.get('STARTS', '<')
MINLEN = int(args.get('MINLEN', 4))
if args.get('ALL') in ('1', 'true', 'yes'):          # must run BEFORE RE is read
    args.setdefault('RE', '(?s).'); MINLEN = min(MINLEN, 1)
RE     = args.get('RE')
DECODE = args.get('DECODE')
LANG   = args.get('LANG', 'auto')
JSREGEX = args.get('JSREGEX') in ('1', 'true', 'yes')
# a regex literal: after ( , = : [ ! & | ? { } ; or line start, not // or /*
JSRE = re.compile(r'(?:^|[(,=:\[!&|?{};\n])\s*(/(?![/*])(?:[^/\\\n\[]|\\.|\[(?:[^\]\\\n]|\\.)*\])+/)[gimsuyd]*')
if not srcs:
    sys.exit(__doc__)
os.makedirs(OUT, exist_ok=True)

SIMPLE = {'n': 10, 't': 9, 'r': 13, '0': 0, '\\': 92, '"': 34, "'": 39,
          'a': 7, 'b': 8, 'f': 12, 'v': 11, '/': 47, '\n': None}

def unescape(text, lang):
    out, i = bytearray(), 0
    while i < len(text):
        c = text[i]
        if c != '\\' or i + 1 >= len(text):
            out.extend(c.encode('utf-8', 'surrogatepass')); i += 1; continue
        n = text[i + 1]
        if n == 'x':                                  # \xNN (C) / \xNN (JS)
            j, h = i + 2, ''
            while j < len(text) and len(h) < 2 and text[j] in '0123456789abcdefABCDEF':
                h += text[j]; j += 1
            if h: out.append(int(h, 16)); i = j; continue
        if n == 'u':                                  # \uNNNN or \u{...} (JS)
            if text[i + 2:i + 3] == '{':
                j = text.find('}', i + 3)
                if j > 0:
                    try: out.extend(chr(int(text[i + 3:j], 16)).encode('utf-8', 'surrogatepass'))
                    except ValueError: pass
                    i = j + 1; continue
            h = text[i + 2:i + 6]
            if len(h) == 4 and all(ch in '0123456789abcdefABCDEF' for ch in h):
                out.extend(chr(int(h, 16)).encode('utf-8', 'surrogatepass')); i += 6; continue
        if lang == 'c' and n in '01234567':            # \NNN octal
            j, o = i + 1, ''
            while j < len(text) and len(o) < 3 and text[j] in '01234567':
                o += text[j]; j += 1
            out.append(int(o, 8) & 0xff); i = j; continue
        if n == '\n':                                  # line continuation
            i += 2; continue
        if n in SIMPLE:
            v = SIMPLE[n]
            if v is not None: out.append(v)
            i += 2; continue
        out.extend(n.encode('utf-8', 'surrogatepass')); i += 2
    return bytes(out)

# one literal, either quote style, escapes allowed; then runs of adjacent literals
LIT = r'"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)*\''
RUN = re.compile(rf'(?:{LIT}|\s|/\*.*?\*/|//[^\n]*\n)+', re.S)
ONE = re.compile(LIT, re.S)
keep = re.compile(RE.encode() if RE else b'')

seen, n, read_ok = {}, 0, 0
for src in srcs:
    lang = LANG if LANG != 'auto' else ('js' if src.endswith(('.js', '.mjs', '.ts')) else 'c')
    try: text = open(src, encoding='utf-8', errors='replace').read()
    except OSError as e:
        print(f'skip {src}: {e}', file=sys.stderr); continue
    read_ok += 1
    cands = [(''.join(p[1:-1] for p in ONE.findall(run.group(0))), False) for run in RUN.finditer(text)]
    if JSREGEX and lang == 'js':
        cands += [(m.group(1)[1:-1], True) for m in JSRE.finditer(text)]
    for joined, is_regex in cands:
        if not joined: continue
        data = joined.encode() if is_regex else unescape(joined, lang)   # a regex keeps its backslashes
        if DECODE:                       # the literal spells out encoded bytes
            import binascii, base64
            txt = bytes(c for c in data if not chr(c).isspace())
            try:
                data = binascii.unhexlify(txt) if DECODE == 'hex' else base64.b64decode(txt, validate=True)
            except Exception:
                continue                  # not a well-formed encoded literal; skip it
        if len(data) < MINLEN: continue
        if RE:
            if not keep.search(data): continue
        elif STARTS.encode() not in data:
            continue
        if data in seen: continue
        n += 1
        name = f'up-{n:03d}'
        seen[data] = name
        open(os.path.join(OUT, name), 'wb').write(data)

if not read_ok:
    sys.exit(f'extract_literals.py: none of the SRC files could be read: {" ".join(srcs)}')
print(f'{n} unique literals -> {OUT}')
if n:
    sizes = sorted(len(d) for d in seen)
    print(f'bytes: min {sizes[0]} median {sizes[len(sizes)//2]} max {sizes[-1]}')
    print('NOTE: this is someone else\'s fixture set -- measure it as an A-side (step 7),')
    print('      then minimise.sh it into your corpus rather than shipping all of it.')
