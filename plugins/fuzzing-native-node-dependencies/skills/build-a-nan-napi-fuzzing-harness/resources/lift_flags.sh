#!/bin/bash
# Print, on one line, the compile flags node-gyp used for a target: the -D feature
# macros, the include paths and the C++ flags.  Use them to compile the harness TU so
# it sees the same ABI as the object it links (-fno-rtti, HAVE_* macros, config
# headers).  Never guess these.
#
#   ./lift_flags.sh build/<target>.target.mk [SRCDIR=<package dir>]
#
# SRCDIR replaces gyp's $(srcdir) in include paths; it defaults to the parent of the
# makefile's directory, which is right when the makefile is still in <pkg>/build/.
# When you lifted it from a snapshot (out/<variant>/<target>.target.mk), pass SRCDIR.
set -uo pipefail
MK=${1:?usage: lift_flags.sh <target.mk> [SRCDIR=dir] [BUILDTYPE=Release]}; shift
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
BT=${BUILDTYPE:-Release}
SRCDIR=${SRCDIR:-$(cd "$(dirname "$MK")/.." && pwd)}
for v in DEFS_$BT INCS_$BT CFLAGS_$BT CFLAGS_CC_$BT; do
  sed -n "/^$v :=/,/^$/p" "$MK" | tr -d '\\' | tr '\n' ' ' | sed "s/^$v := //"
done | sed "s#\$(srcdir)#$SRCDIR#g; s#\$(obj)#$SRCDIR/build/$BT/obj#g" | tr -d "'" | tr -s ' \t\n' ' '
# gyp compiles each TU with includes relative to its own directory, so the lifted -I
# list never names the addon's own source dirs; the harness TU needs them for
# `#include "Decoder.h"` / "util.h".
for d in "$SRCDIR" "$SRCDIR/src" "$SRCDIR/lib"; do [ -d "$d" ] && printf ' -I%s' "$d"; done
echo
