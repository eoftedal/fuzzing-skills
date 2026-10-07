# REBUILD for the detection self-test, when `rebuild_asan.sh` does not fit

Read this when step 6 of SKILL.md sends you here: the package's gyp action re-extracts
the library source during configure, or the package is a zig build. The quoting rule in
SKILL.md (expand lists before building the string, single-quote the result, because
`REBUILD` runs under `eval` twice) applies to every recipe below.

## A gyp action re-extracts the library source during configure

A tarball-vendored library is unpacked fresh by each `node-gyp configure`, so a fault
injected into the package tree is overwritten before it compiles, and `rebuild_asan.sh`
cannot be used. REBUILD is then an out-of-tree build of the library plus a relink:

1. Configure the library once, outside the package, with the line
   `build/<dep>/config.log` records, prefixed with `CC=afl-clang-fast AFL_USE_ASAN=1`.
2. Point `FAULT_SRC=` at the source in that tree, and use
   ```sh
   REBUILD="make -C <that tree> && resources/link_harness.sh VARIANT=asan ... LIB=<that tree>/.libs/lib<dep>.a"
   ```

This relinks the asan harness against a different archive than the one the gate and the
smoke vouched for, so re-run the asan gate on that harness afterwards.

## A zig build

REBUILD is the two asan `zig build` invocations (the package with `-Dasan=true`, then the
`harness` step with `-Dasan=true -Dasan_rt=...`, as in `zig-build.md`) plus a copy of the
drivers. `link_harness.sh` does not run on this route, so `smoke.sh` is
what checks the persistent magic string.

## Cleanup between the two runs

`detect_selftest.sh` removes its `<src>.injected` copy before the restore rebuild, so a
REBUILD that greps the tree for `INJECTED` sees a clean tree then.
