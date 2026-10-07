#!/bin/bash
# Print, on one line, the preprocessor flags mkmf used for a C extension: the include
# paths, the -D feature macros (HAVE_* from have_header/have_func, and whatever
# extconf.rb appended to $defs / $CPPFLAGS), and the -D/-U tokens in CFLAGS.  Use them
# to compile the harness TU so it sees the same configuration as the objects it links.
# Never guess these: a HAVE_* macro that extconf.rb set changes struct layouts and
# which decoder is compiled in.
#
#   ./lift_flags.sh out/<variant>/Makefile SRCDIR=<ext source dir>
#
# SRCDIR replaces mkmf's $(srcdir).  mkmf's `-I.` means the BUILD directory, which is
# where extconf.h lives when extconf.rb calls create_header; it is mapped to the
# Makefile's own directory (build_ext.sh snapshots extconf.h next to the Makefile).
#
# Deliberately NOT lifted: the rest of CFLAGS.  It is the C compile line of the Ruby
# that ran extconf.rb (distro hardening, gcc-only warnings, -std=gnu99), and the
# harness TU is C++.  Ruby's own include dirs ARE lifted, because the library headers
# are sometimes only reachable through the extension's header; the harness must still
# not call anything from ruby.h (gen_stubs.sh traps it if it does).
set -uo pipefail
MK=${1:?usage: lift_flags.sh <Makefile> SRCDIR=<ext source dir>}; shift
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
HERE=$(cd "$(dirname "$0")" && pwd)
MKDIR=$(cd "$(dirname "$MK")" && pwd)
SRCDIR=${SRCDIR:-$MKDIR}
SRCDIR=$(cd "$SRCDIR" && pwd)
V=$("$HERE/mkvar.sh" "$MK" INCFLAGS CPPFLAGS CFLAGS srcdir="$SRCDIR") || { echo "lift_flags: make could not read $MK" >&2; exit 1; }
# Split the way the shell running make would (shlex), not on spaces: extconf.rb can add a
# string macro with spaces inside quotes (-DPATCHES="\"0001-... 0002-...\""), which a space split cut in half -- `missing terminating '"' character` on
# every harness compile.  The output is word-split by link_harness.sh, so a value that
# contains spaces or quotes cannot be passed through at all: such macros are dropped and
# named on stderr (they are version strings; if the harness needs one, pass it by hand).
# Two-token options (-include <file>, -isystem <dir>) are kept together: a token-wise
# filter kept the option and dropped its argument.
# -I. and -I./x are relative to the build dir and are made absolute.  From CPPFLAGS and
# INCFLAGS only flags that change what the preprocessor sees are kept (-Wdate-time and
# similar are noise); from CFLAGS only -D/-U.
MKDIR="$MKDIR" SRCDIR="$SRCDIR" python3 - "$V" <<'PY'
import os, shlex, sys
mkdir, srcdir = os.environ["MKDIR"], os.environ["SRCDIR"]
var = {}
for line in sys.argv[1].splitlines():
    k, _, v = line.partition("=")
    var[k] = v
TWO = ("-include", "-isystem", "-iquote", "-I", "-D", "-U")
def flags(s, keep):
    toks, out = shlex.split(s), []
    i = 0
    while i < len(toks):
        t = toks[i]
        if t in TWO and i + 1 < len(toks):
            t, i = t + ("" if t in ("-I", "-D", "-U") else " ") + toks[i + 1], i + 1
        i += 1
        if t.startswith(keep):
            out.append(t)
    return out
res, dropped = [], []
for t in flags(var.get("INCFLAGS", ""), ("-I",)) + flags(var.get("CPPFLAGS", ""), ("-D", "-U", "-I", "-include", "-isystem", "-iquote")) \
         + flags(var.get("CFLAGS", ""), ("-D", "-U")):
    if t == "-I.":
        t = "-I" + mkdir
    elif t.startswith("-I./"):
        t = "-I" + mkdir + t[3:]
    body = t.split(" ", 1)[1] if t.startswith(("-include ", "-isystem ", "-iquote ")) else t
    if any(c in body for c in " \"'\\"):
        dropped.append(t.split("=", 1)[0])
        continue
    if t not in res:
        res.append(t)
if "-I" + srcdir not in res:
    res.append("-I" + srcdir)
if dropped:
    print("lift_flags: dropped macro(s) whose value has spaces or quotes: " + " ".join(dropped), file=sys.stderr)
print(" ".join(res))
PY
