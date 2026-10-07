#!/bin/bash
# Print variables of an mkmf Makefile, fully expanded by make itself, one per line as
# NAME=value.  mkmf writes `VAR = $(other) ...` chains ($(arch_hdrdir), $(LIBRUBYARG),
# $(DEFS) inside CPPFLAGS); re-implementing that expansion with sed gets it wrong, so
# let make do it.
#
#   mkvar.sh out/plain/Makefile INCFLAGS CPPFLAGS LIBS [srcdir=/path/to/ext]
#
# NAME=value arguments are passed to make as overrides (srcdir= is the one that
# matters: mkmf writes `srcdir = .` or the path at extconf time, which is wrong once
# the Makefile has been snapshotted into out/<variant>/).
set -uo pipefail
MK=${1:?usage: mkvar.sh <Makefile> VAR... [name=value...]}; shift
VARS=() ; OVR=()
for a in "$@"; do case $a in *=*) OVR+=("$a");; *) VARS+=("$a");; esac; done
[ ${#VARS[@]} -ge 1 ] || { echo "mkvar.sh: name at least one variable" >&2; exit 2; }
DIR=$(cd "$(dirname "$MK")" && pwd)
# -C so the Makefile's own relative includes (depend files) resolve; the printing
# rule comes from a second makefile so nothing in the real one runs.
make -s --no-print-directory -C "$DIR" -f "$(basename "$MK")" \
     -f <(printf '__mkvar_print:\n\t@:$(foreach v,$(__MKVARS),$(info $(v)=$($(v))))\n') \
     __MKVARS="${VARS[*]}" "${OVR[@]}" __mkvar_print
