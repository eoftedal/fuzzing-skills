# The detection self-test: placing the fault, and REBUILD when `rebuild_asan.sh` does not fit

Read this when step 6 of SKILL.md sends you here: writing `rebuild.sh` for a package that
needs more than the sketch there, the self-test passed on nothing or
failed in a way you do not understand, the package's gyp action re-extracts the library
source during configure, the library is a step-3b archive, or the package is a zig build. Each recipe below is the body
of `rebuild.sh` (after its `cd "$(dirname "$0")" && . ./fuzz.env` line), passed as
`REBUILD=./rebuild.sh`. If you still pass `REBUILD` as a string, it runs under `eval`
twice, so expand any `$(find ...)` before building it and single-quote the result, or a
literal `$(find ...)` reaches `eval` and the relink fails with an empty log.

## The default `rebuild.sh`, argument by argument

```sh
#!/bin/sh
cd "$(dirname "$0")" && . ./fuzz.env
exec $R/rebuild_asan.sh PKGDIR=<package dir> OUT=$W/out MK=$W/out/asan/<target>.target.mk \
    SRCDIR=<package dir> HARNESS=$W/harness.cc [TARGET=<target>] \
    LIB="$(find $W/out/asan/Release/obj.target/<target>/<lib dir> -name '*.o' | tr '\n' ' ')" \
    [ADDON_OBJS="..."] [EXTRA_FLAGS="-I..."] [EXTRA_LDFLAGS=-Wl,-Bsymbolic] [NODE_GYP=...]
```

`rebuild_asan.sh` passes every argument to both `build_addon.sh` and `link_harness.sh`,
so give it exactly what you gave them for the asan variant:

* `LIB=` is wherever the vendored objects landed, the same `find` you gave
  `link_harness.sh`: `obj.target/<target>/<lib dir>`, where `<lib dir>` is the vendored
  subtree's own name (`vendor/<dep>`, `deps/<dep>`, the library's name at the top level),
  or `obj.target/<dep>/` for a separate gyp target. Not always `vendor`.
* `TARGET=` when the package has several gyp targets (`build-traps.md`, "Several addons
  in one package").
* `ADDON_OBJS=` when the link uses an addon object (a custom allocator's TU).
* `EXTRA_FLAGS=` when the harness includes a second addon's headers or sources.
* `EXTRA_LDFLAGS=-Wl,-Bsymbolic` when the addon is built symbolic (`interposition.md`);
  without it the restore step leaves a non-symbolic asan addon behind.

## Placing the fault and choosing the seed

Without the self-test, "no crashes found" is indistinguishable from "detects nothing".

* `FAULT_SED` must **introduce the word `INJECTED`** (a `/* INJECTED */` comment on the
  faulted line): `detect_selftest.sh` greps for it to prove the edit applied, and fails
  with `FAULT_SED did not apply` when it is missing, even if the code changed. Set
  `MARKER=` to look for another word.
* The fault must land **past an allocation boundary**: a 1-byte over-*read* into a larger
  buffer fires nothing.
* The seed must **reach** it. The script picks the largest non-empty seed that reports
  `status=0` with `out_len>0`, which is often the wrong one (a compressed-block seed for
  a raw-block fault), so pass `SEED=`.
* Anchor `FAULT_SED` to the function (`/^Func/,/^}/`), because the same line exists in
  other functions; the script prints where the fault landed for exactly that reason.
* Reaching the function is not enough: the seed must take the **dispatch branch** the
  fault sits on (an unsized frame goes down a streaming path whose oversized buffer hides
  a 1-byte over-write; UTF-8 input never touches a transcoding buffer; a simple pattern
  that a regex library runs on a one-pass engine never reaches a fault in its
  backtracking engine), so read the branch around the faulted line before picking
  `SEED=`. When the library picks among several engines by inspecting the input, the
  seed has to be one that selects the faulted engine, and the script's own pick knows
  nothing of that.
* The self-test runs the harness in the current environment, so for a fault on a path
  only a mode reaches, export that `MODE=` first and pick `SEED=` from a seed that takes it.

## After the self-test

Every REBUILD's restore step relinks the asan harness, which counts as a harness change,
so the asan gate runs once more after the self-test (ten seconds; the map size may move
by a few entries, which is expected).

## A gyp action re-extracts the library source during configure

A tarball-vendored library is unpacked fresh by each `node-gyp configure`, so a fault
injected into the package tree is overwritten before it compiles, and `rebuild_asan.sh`
cannot be used. REBUILD is then an out-of-tree build of the library plus a relink:

1. Configure the library once, outside the package, with the line
   `build/<dep>/config.log` records, prefixed with `CC=afl-clang-fast AFL_USE_ASAN=1`.
2. Point `FAULT_SRC=` at the source in that tree, and make the body of `rebuild.sh`
   ```sh
   make -C <that tree> && exec $R/link_harness.sh VARIANT=asan ... LIB=<that tree>/.libs/lib<dep>.a
   ```

This relinks the asan harness against a different archive than the one the gate and the
smoke vouched for, so re-run the asan gate on that harness afterwards.

## A static archive of a system library (step 3b, first choice)

The default `rebuild.sh` covers it once the archive was built with `build_lib.sh`, which
records its arguments: `rebuild_asan.sh` re-runs the asan `build_lib.sh` with them (out of
tree, `AFL_USE_ASAN=1` exported, the archive and headers copied back into
`out/asan/lib/`), then relinks with `link_harness.sh VARIANT=asan`. Give `rebuild.sh` the
asan link's own arguments, `LIB=$W/out/asan/lib/lib<x>.a ARCHIVE_LIBS=<x>` and any
`ADDON_OBJS=` / `EXTRA_LIBS=` among them, and point `FAULT_SRC=` into the `SRC=` tree
(`$W/src-lib/...`). Leave its output on the terminal: `detect_selftest.sh` shows a failed
rebuild's output, and a `>/dev/null` in `rebuild.sh` leaves it nothing to show.

A library that allocates from its own pools hides a small overrun inside the pool: place
the fault past the end of a large allocation the library requests on its own (a per-row
or per-block buffer sized from the header), not one carved from a pool. Case: on the
JPEG library the fault that fired grew a clear of a block buffer by one block, past the
large allocation holding it.

## A zig build

REBUILD is the two asan `zig build` invocations (the package with `-Dasan=true`, then the
`harness` step with `-Dasan=true -Dasan_rt=...`, as in `zig-build.md`) plus a copy of the
drivers. `link_harness.sh` does not run on this route, so `smoke.sh` is
what checks the persistent magic string.

## Cleanup between the two runs

`detect_selftest.sh` removes its `<src>.injected` copy before the restore rebuild, so a
REBUILD that greps the tree for `INJECTED` sees a clean tree then.
