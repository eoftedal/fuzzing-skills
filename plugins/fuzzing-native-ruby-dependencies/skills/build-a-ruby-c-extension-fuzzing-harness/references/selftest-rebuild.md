# The detection self-test: REBUILD, and the out-of-tree rebuild of a library

Read this when SKILL.md step 6 points here: when writing `REBUILD`, when the library is
vendored through a recipe that re-extracts it or is a system library you rebuilt (step 3b),
or when the self-test's restore leaves you unsure the harness is still the gated one.

## Picking the fault and the seed

The script picks the largest non-empty seed that reports `status=0` with `out_len>0`,
which is often the wrong one, so pass `SEED=`. Anchor `FAULT_SED` to the function
(`/^Func/,/^}/`), because the same line exists in other functions; the script prints where
the fault landed for exactly that reason. The seed must also take the **dispatch branch**
the fault sits on, and the **engine**: a library with several engines behind one call (a
pattern or option that selects another matcher, a format byte that selects another
decoder) runs the fault only for seeds that pick its engine. Read the branch around the
faulted line before picking `SEED=`.

## REBUILD

`REBUILD` is run with `eval`, twice (fault applied, then restore), so keep the commands in
`rebuild.sh` (which sources `fuzz.env` itself) and pass `REBUILD=./rebuild.sh`; a string
built inline must have every list expanded first and be single-quoted, or a `$(find ...)`
reaches `eval` as a literal and the relink fails with an empty log. `rebuild_asan.sh` takes `EXT=` (the directory holding `extconf.rb`) plus the arguments you
gave `build_ext.sh` and `link_harness.sh` (add `EXT_OBJS=`, `LIBS_FROM_MK=`, `EXTRA_LIBS=`
if you used them); it re-runs `build_ext.sh VARIANT=asan` there and relinks. The script
removes its `<src>.injected` copy before the restore rebuild.

**Never discard the rebuild's output** (`>/dev/null`): `detect_selftest.sh` captures it and
shows it when the faulted rebuild fails; discarded, the log it shows is empty and the
failure has no cause (an evaluation run lost time to exactly this).

**Give it what you linked with.** The forms, one per shape:

```sh
cd $W && . ./fuzz.env
cat > rebuild.sh <<'EOF'
#!/bin/bash
cd "$(dirname "$0")" && . ./fuzz.env || exit 1
# (a) library compiled into or vendored by the extension, as an archive:
exec $R/rebuild_asan.sh EXT=$X OUT=$W/out MK=$W/out/asan/Makefile SRCDIR=$X HARNESS=$W/harness.cc \
    EXTCONF_ARGS="$EXTCONF_ARGS" LIB="$(ls $W/out/asan/lib/*.a | tr '\n' ' ')"
# (b) the parser is the extension's own C, through a shim (no lib/ at all):
#   exec $R/rebuild_asan.sh EXT=$X OUT=$W/out MK=$W/out/asan/Makefile SRCDIR=$X HARNESS=$W/harness.cc \
#       EXTCONF_ARGS="$EXTCONF_ARGS" EXT_OBJS="$W/out/asan/obj/<file>.o ..." SHIM=$W/shim.c LIBS_FROM_MK=1
# (c) a separately built static library (system library, step 3b): the next section
EOF
chmod +x rebuild.sh
```

In (b) the `EXT_OBJS` paths are the snapshot's, which the rebuild's `build_ext.sh` run
refreshes, so the faulted object is the one linked; add `EXTRA_FLAGS=` if the link used it.
`rebuild_asan.sh` passes every key on, and each script ignores the ones it does not use.

## A system library rebuilt as a static archive (step 3b)

The library is not built by `build_ext.sh`, so `rebuild_asan.sh` would rebuild the
extension and leave the archive with no fault in it. Make a copy of the source for the
self-test, configured as the asan build, and patch that copy:

```sh
cd $W && . ./fuzz.env
cp -a $W/src/<lib>-<ver> $W/selftest/<lib>        # -a: keep mtimes, or make runs the autotools
(cd $W/selftest/<lib> && AFL_USE_ASAN=1 CC=afl-clang-fast \
   CFLAGS="-O2 -g -fPIC -include $R/undef_fuzzmode.h" ./configure --disable-shared --enable-static)
cat > rebuild.sh <<'EOF'
#!/bin/bash
cd "$(dirname "$0")" && . ./fuzz.env || exit 1
export AFL_USE_ASAN=1
make -C $W/selftest/<lib> -j6 && exec $R/link_harness.sh VARIANT=asan MK=$W/out/asan/Makefile \
    SRCDIR=$X OUT=$W/out HARNESS=$W/harness.cc LIB=$W/selftest/<lib>/src/.libs/lib<x>.a \
    EXTRA_FLAGS=-I$W/src/<lib>-<ver>/include
EOF
chmod +x rebuild.sh
$R/detect_selftest.sh FAULT_SRC=$W/selftest/<lib>/src/<file>.c FAULT_SED='...' REBUILD=./rebuild.sh ...
```

A `cp -r` copy gives every file a new mtime, and `make` then tries to regenerate
`configure` and the Makefiles (`config/missing: aclocal-1.15: command not found`; seen on
an evaluation run). The restore relinks the asan harness against the restored copy, built
with the same flags as `out/asan/lib/`, so re-gate afterwards (below) as for every form.

## A library the gem extracts or patches during configure

`rebuild_asan.sh` cannot be used when `extconf.rb` extracts or patches the library during
configure (mini_portile2 recipes, anything under `ports/` or `tmp/`): the rebuild
re-extracts the tarball over your patch, and a gem may delete the build tree (and its
`config.log`) afterwards anyway. Rebuild that library out of tree from what `build_ext.sh`
recorded:

```sh
cd $W && . ./fuzz.env
$R/rebuild_vendored.sh RECIPE=$W/out/asan/vendor/<lib>-<ver> VARIANT=asan OUT=$W/out \
    DEST=$W/selftest/<lib>          # extract, apply the gem's patches, configure, make install
cat > rebuild.sh <<'EOF'
#!/bin/bash
cd "$(dirname "$0")" && . ./fuzz.env || exit 1
L=$(ls $W/out/asan/lib/*.a | grep -v lib<lib>.a | tr '\n' ' ')
make -C $W/selftest/<lib>/src -j6 install && exec $R/link_harness.sh VARIANT=asan \
    MK=$W/out/asan/Makefile SRCDIR=$X OUT=$W/out HARNESS=$W/harness.cc \
    LIB="$W/selftest/<lib>/install/lib/lib<lib>.a $L" LIBS_FROM_MK=1
EOF
chmod +x rebuild.sh
$R/detect_selftest.sh FAULT_SRC=$W/selftest/<lib>/src/<lib file>.c FAULT_SED='...' REBUILD=./rebuild.sh ...
```

(Measured: the rebuilt library, with the gem's patches and the logged options, carried
the same coverage symbols as the extension's build. Both evaluation runs had to do this
by hand before the helper existed.) Only recipes with a `./configure` are supported; a
vendored library built from a source directory inside the gem (not a tarball) with its
own rules is not (copy `DEST/src` and run the extension's compile step by hand, per the
script's header).

## Re-gate afterwards

That relinks the asan harness against a different archive than the gate and smoke
vouched for, so re-run the asan gate on it afterwards. The same holds for every REBUILD:
the restore step relinks the asan harness, which counts as a harness change, so the asan
gate runs once more after the self-test (the map size may move by a few entries, which is
expected).

## selftest.txt and the staleness check

The campaign skill flags a harness newer than `selftest.txt` as stale, so re-run the
self-test whenever the harness is rebuilt. The self-test's own restore relink leaves `out/asan/harness*` and `selftest.txt` in the
same second; that is fine, the campaign skill's `-nt` check compares nanoseconds and
`selftest.txt` is written last (measured: 11-13 ms later in both evaluation runs).
