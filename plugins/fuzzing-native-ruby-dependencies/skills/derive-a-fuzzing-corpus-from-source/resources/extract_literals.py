#!/usr/bin/env python3
"""Extract a corpus from string literals in a library's own test source.

Libraries whose tests are compiled, rather than loaded from disk, often carry hundreds of
documents inline. That is a corpus written by the people who wrote the parser, and nothing
in the gem's repo hints it exists.  A gem's own Ruby tests carry fixtures the same way.

    extract_literals.py OUT=./corpus-fixtures STARTS='<' SRC=lib/tests/runtests.c [SRC=...]
    extract_literals.py OUT=./corpus-fixtures RE='^(\\x89PNG|GIF8)' SRC=test/*.c
    extract_literals.py OUT=./corpus-fixtures ALL=1 SRC='test/**/*.rb spec/**/*.rb'

    OUT     directory to write into (one file per unique literal)
    SRC     one or more source files: repeat the key, pass a glob, or one quoted
            whitespace-separated list (SRC="a.c b.c"); `**` recurses.  A directory is
            walked for the LANG's default globs (c: *.c *.h *.cc *.cpp; js: *.js *.mjs
            *.ts; rb: *.rb; auto: all of them).  A path that does not exist is an error
            (exit 1), not a silent "0 unique literals".
    STARTS  keep a literal only if it contains this substring (default '<')
    RE      instead of STARTS, keep it if this regex matches the decoded BYTES
    ALL=1   keep EVERY literal -- use this when the format has no signature byte to filter
            on (patterns, queries, source text). The defaults are tuned for a format with a
            recognisable opening, and on a signature-less format they discard almost
            everything: one target (a Node binding) yielded 30 literals with the defaults and 2444 with ALL=1,
            the latter worth hundreds of edges the former never reached.
    MINLEN  minimum decoded length to keep (default 4)
    LANG    c | js | rb | auto   (default auto, by file extension: .rb/.rake/.gemspec
            are rb, .js/.mjs/.ts are js, everything else c)
    JSREGEX=1 also extract REGEX LITERALS (/pattern/flags, and %r{...} in Ruby) from js
            and rb sources -- the dominant fixture form in a regex binding's own tests.
            The pattern text is written, flags are dropped.  Expect a few false positives
            from division.
    DECODE  hex | base64    fixtures written as an ENCODED string (a complete binary record
                            spelled out as hex in a test file is common); applied BEFORE
                            RE/STARTS/MINLEN, so those match the real bytes

Handles what actually bites: C and JS escapes including \\xNN, \\NNN octal, \\uNNNN and
\\u{...}; line continuations; both quote styles; and ADJACENT LITERAL CONCATENATION, which
is how multi-line documents are written in C test suites. Comments between adjacent
literals are tolerated.

Ruby (LANG=rb) is scanned, not pattern-matched: '...' (only \\\\ and \\' are escapes),
"..." (Ruby escapes incl. \\s \\e \\u{a b}; #{...} interpolation is dropped), %q %Q %()
%w %W %i %I with ( [ { < nesting and | ! / ^ as plain delimiters (each %w word is its own
literal), heredocs <<ID <<-ID <<~ID with 'ID' "ID" quoting (<<~ is dedented), adjacent
"a" "b" concatenation, and everything after __END__ as one literal.  Comments, =begin
blocks, ?x character literals and $" globals are skipped so they do not desync the scan.
"""
import os, re, sys, glob

args, srcs = {}, []
def add_src(v):
    hits = glob.glob(v, recursive=True)
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
EXTS = {'c': ('.c', '.h', '.cc', '.cpp'), 'js': ('.js', '.mjs', '.ts'), 'rb': ('.rb',)}
def expand(paths):                                   # a directory -> its LANG's default globs
    exts = EXTS.get(LANG) or sum(EXTS.values(), ())
    for p in paths:
        if not os.path.isdir(p):
            yield p; continue
        for d, _, fs in os.walk(p):
            for f in sorted(fs):
                if f.endswith(exts): yield os.path.join(d, f)
srcs = list(expand(srcs))
os.makedirs(OUT, exist_ok=True)

SIMPLE = {'n': 10, 't': 9, 'r': 13, '0': 0, '\\': 92, '"': 34, "'": 39,
          'a': 7, 'b': 8, 'f': 12, 'v': 11, '/': 47, '\n': None}
RB_SIMPLE = dict(SIMPLE, s=32, e=27)

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
                if j > 0:                                # Ruby allows \u{41 42 43}
                    try: out.extend(''.join(chr(int(h, 16)) for h in text[i + 3:j].split()).encode('utf-8', 'surrogatepass'))
                    except ValueError: pass
                    i = j + 1; continue
            h = text[i + 2:i + 6]
            if len(h) == 4 and all(ch in '0123456789abcdefABCDEF' for ch in h):
                out.extend(chr(int(h, 16)).encode('utf-8', 'surrogatepass')); i += 6; continue
        if lang in ('c', 'rb') and n in '01234567':    # \NNN octal
            j, o = i + 1, ''
            while j < len(text) and len(o) < 3 and text[j] in '01234567':
                o += text[j]; j += 1
            out.append(int(o, 8) & 0xff); i = j; continue
        if n == '\n':                                  # line continuation
            i += 2; continue
        table = RB_SIMPLE if lang == 'rb' else SIMPLE
        if n in table:
            v = table[n]
            if v is not None: out.append(v)
            i += 2; continue
        out.extend(n.encode('utf-8', 'surrogatepass')); i += 2
    return bytes(out)

# ---- Ruby: a small scanner, because heredocs, %-literals and interpolation do not regex
RB_PAIRS = {'(': ')', '[': ']', '{': '}', '<': '>'}
RB_REGEX_PREV = set('(,=:[!&|?{};~^+-*%<>\n')
HEREDOC = re.compile(r"""<<([~-]?)(?:([A-Za-z_]\w*)|"([^"\n]+)"|'([^'\n]+)'|`([^`\n]+)`)""")
PCT = re.compile(r'%([qQwWiIr]?)([(\[{<|!/^])')

def rb_strip_interp(body):                           # drop #{...}, keep escapes for unescape()
    out, i = [], 0
    while i < len(body):
        if body[i] == '\\':
            out.append(body[i:i + 2]); i += 2; continue
        if body.startswith('#{', i):
            depth, j = 0, i + 1
            while j < len(body):
                if body[j] == '\\': j += 1
                elif body[j] == '{': depth += 1
                elif body[j] == '}':
                    depth -= 1
                    if depth == 0: break
                j += 1
            i = j + 1; continue
        out.append(body[i]); i += 1
    return ''.join(out)

def rb_sq(body, delims):                             # single-quoted: only \\ and \<delim>
    return re.sub(r'\\([\\' + re.escape(delims) + '])', r'\1', body).encode('utf-8', 'surrogatepass')

def rb_dq(body):
    return unescape(rb_strip_interp(body), 'rb')

def rb_delimited(text, i, open_):
    """text[i] is just past the opening delimiter; return (raw body, index past the close)."""
    close, depth, j = RB_PAIRS.get(open_, open_), 1, i
    while j < len(text):
        ch = text[j]
        if ch == '\\': j += 2; continue
        if ch == '#' and text.startswith('#{', j):    # an interpolation may hold the delimiter
            depth2, k = 0, j + 1
            while k < len(text):
                if text[k] == '\\': k += 1
                elif text[k] == '{': depth2 += 1
                elif text[k] == '}':
                    depth2 -= 1
                    if depth2 == 0: break
                k += 1
            j = k + 1; continue
        if ch == close:
            depth -= 1
            if depth == 0: return text[i:j], j + 1
        elif ch == open_:
            depth += 1
        j += 1
    return text[i:], len(text)

def rb_literals(text, want_regex):
    """[(bytes, is_regex)] for every string literal in Ruby source."""
    out, i, n, resume, last_end = [], 0, len(text), None, -1
    def prev(k):                                     # (last non-blank char before k, spaced?)
        j = k - 1
        while j >= 0 and text[j] in ' \t': j -= 1
        return (text[j] if j >= 0 else '\n'), j < k - 1
    def literal_position(k):                         # / or % here starts a literal, not an operator
        p, spaced = prev(k)
        nxt = text[k + 1:k + 2]
        return p in RB_REGEX_PREV or (spaced and (p.isalnum() or p == '_') and nxt not in ' \t=')
    def add(data, start, end, joinable=False):
        nonlocal last_end
        if joinable and out and last_end >= 0 and out[-1][2] and \
                re.fullmatch(r'[ \t]*(?:\\\r?\n[ \t]*)?', text[last_end:start]):
            out[-1] = (out[-1][0] + data, False, True)    # "a" "b" is one literal
        else:
            out.append((data, False, joinable))
        last_end = end if joinable else -1
    while i < n:
        c = text[i]
        bol = i == 0 or text[i - 1] == '\n'
        if bol and text.startswith('=begin', i):
            j = text.find('\n=end', i)
            j = -1 if j < 0 else text.find('\n', j + 1)
            i = n if j < 0 else j; continue
        if bol and re.match(r'__END__\r?\n', text[i:i + 9]):
            out.append((text[text.find('\n', i) + 1:].encode('utf-8', 'surrogatepass'), False, False)); break
        if c == '\n':
            if resume is not None and resume > i:
                i, resume = resume, None; continue
            resume = None; i += 1; continue
        if c == '#':                                 # comment to end of line (keep the \n)
            j = text.find('\n', i); i = n if j < 0 else j; continue
        if c == '$' and text[i + 1:i + 2] in ('"', "'", '`'):
            i += 2; continue
        if c == '?' and text[i + 1:i + 2] in ('"', "'", '`') and not text[i + 2:i + 3].isalnum():
            i += 2; continue
        if c == '<' and text.startswith('<<', i):
            m = HEREDOC.match(text, i)
            if m:
                flag, ident = m.group(1), next(g for g in m.groups()[1:] if g)
                quote = '"' if m.group(3) else "'" if m.group(4) else '`' if m.group(5) else ''
                if quote or flag or not (prev(i)[0].isalnum() and not prev(i)[1]):
                    start = resume if resume is not None else text.find('\n', i) + 1
                    k, body_end, after = start, None, None
                    while 0 < k <= n:
                        e = text.find('\n', k); e = n if e < 0 else e
                        line = text[k:e].rstrip('\r')
                        if (line.strip(' \t') if flag else line) == ident:
                            body_end, after = k, min(e + 1, n); break
                        if e >= n: break
                        k = e + 1
                    if body_end is not None:
                        body = text[start:body_end]
                        if flag == '~':              # squiggly: strip the common indentation
                            lines = body.split('\n')
                            ind = [len(l) - len(l.lstrip(' \t')) for l in lines if l.strip()]
                            cut = min(ind) if ind else 0
                            body = '\n'.join(l[cut:] for l in lines)
                        if quote != '`':
                            add(body.encode('utf-8', 'surrogatepass') if quote == "'" else rb_dq(body), i, m.end())
                        resume = after; i = m.end(); continue
            i += 2; continue
        if c in '"\'`':
            body, j = rb_delimited(text, i + 1, c)
            if c != '`':
                add(rb_sq(body, "'") if c == "'" else rb_dq(body), i, j, joinable=True)
            i = j; continue
        if c == '%' and literal_position(i):
            m = PCT.match(text, i)
            if m:
                kind, d = m.group(1), m.group(2)
                body, j = rb_delimited(text, m.end(), d)
                delims = d + RB_PAIRS.get(d, '')
                if kind == 'r':
                    if want_regex: out.append((body.encode('utf-8', 'surrogatepass'), True, False))
                elif kind and kind in 'wWiI':
                    for w in re.split(r'(?<!\\)\s+', body.strip()):
                        if w: add(rb_sq(w, delims + ' ') if kind in 'wi' else rb_dq(w), i, j)
                else:
                    add(rb_sq(body, delims) if kind == 'q' else rb_dq(body), i, j)
                i = j; continue
        if c == '/' and literal_position(i) and text[i + 1:i + 2] not in ('', '\n'):
            body, j = rb_delimited(text, i + 1, '/')
            if want_regex: out.append((body.encode('utf-8', 'surrogatepass'), True, False))
            i = j; continue
        i += 1
    return [(d, r) for d, r, _ in out]

# one literal, either quote style, escapes allowed; then runs of adjacent literals
LIT = r'"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)*\''
RUN = re.compile(rf'(?:{LIT}|\s|/\*.*?\*/|//[^\n]*\n)+', re.S)
ONE = re.compile(LIT, re.S)
keep = re.compile(RE.encode() if RE else b'')

seen, n, read_ok = {}, 0, 0
for src in srcs:
    lang = LANG if LANG != 'auto' else ('js' if src.endswith(('.js', '.mjs', '.ts')) else
                                        'rb' if src.endswith(('.rb', '.rake', '.gemspec')) else 'c')
    try: text = open(src, encoding='utf-8', errors='replace').read()
    except OSError as e:
        print(f'skip {src}: {e}', file=sys.stderr); continue
    read_ok += 1
    if lang == 'rb':                     # already decoded: (bytes, is_regex)
        cands = rb_literals(text, JSREGEX)
    else:
        cands = [(''.join(p[1:-1] for p in ONE.findall(run.group(0))), False) for run in RUN.finditer(text)]
    if JSREGEX and lang == 'js':
        cands += [(m.group(1)[1:-1], True) for m in JSRE.finditer(text)]
    for joined, is_regex in cands:
        if not joined: continue
        if isinstance(joined, bytes): data = joined
        else: data = joined.encode() if is_regex else unescape(joined, lang)   # a regex keeps its backslashes
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
