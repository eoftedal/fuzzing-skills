#!/bin/bash
# The REBUILD step for detect_selftest.sh on an mkmf extension: rebuild the asan
# variant of the extension (which recompiles the patched source) and relink the asan
# harness.  Pass the SAME KEY=VALUE arguments you gave build_ext.sh and
# link_harness.sh; both ignore the ones they do not use.
#
#   REBUILD="resources/rebuild_asan.sh EXT=/path/to/gem/ext/<name> OUT=/abs/fuzz/out \
#            MK=/abs/fuzz/out/asan/Makefile SRCDIR=/path/to/gem/ext/<name> \
#            HARNESS=/abs/fuzz/harness.cc LIB='...' [EXT_OBJS='...'] [EXTRA_LIBS='...'] \
#            [EXTCONF_ARGS='...'] [GEM_PATH=/abs/oracle] [ORACLE=...]"
# EXTCONF_ARGS must repeat what the builds used, or the faulted rebuild is configured
# differently from the harness it is meant to prove.
#
# NOT usable when extconf.rb itself unpacks or patches the library (mini_portile
# recipes, anything under ports/): a rebuild re-extracts the
# tarball and overwrites the file you patched.  For those, build the library once
# out-of-tree with CC=afl-clang-fast AFL_USE_ASAN=1, and make REBUILD a `make` in that
# tree plus a relink of the harness -- see detect_selftest.sh's header.
set -uo pipefail
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
EXT=${EXT:?set EXT=<ext source dir, where extconf.rb is>}
HERE=$(cd "$(dirname "$0")" && pwd)
export AFL_USE_ASAN=1
# output is NOT discarded: detect_selftest.sh captures it as the build log it shows you
# when the faulted rebuild fails
( cd "$EXT" && "$HERE/build_ext.sh" VARIANT=asan "$@" ) || exit 1
"$HERE/link_harness.sh" VARIANT=asan "$@"
