# A zig-built addon: the non-gyp route, as it worked on an image-decoding binding

Read this when the package has no `binding.gyp` and builds with `zig build`. Everything
in SKILL.md step 3 that names `build_addon.sh`, `lift_flags.sh` or `link_harness.sh` is
inert here; `resources/wrapper_build.zig` replaces all three. The rest of the skill
(boundary, four layers, gate, self-test, triage) applies unchanged, and the gate is
what proves the swap was faithful.

Why bother rather than harnessing the last gyp tag: a package that moved to zig
usually did it to vendor its dependencies, so every decoder that was an uninstrumented
system `.so` under node-gyp is now in-tree. On an image-decoding binding, the node-gyp release exposed the in-tree glue
only; its next major version (a zig build) exposed its image codecs, its 2D renderer,
its font and text-shaping libraries and zlib, and the bulk of the corpus coverage landed
inside them.

## The route

zig's build graph has no compiler override, so `afl-clang-fast` cannot drive it
(route 3a is out). But `zig cc` is clang, and every `Module`'s C source sets carry an
appendable flag list. So:

1. Coverage goes in through zig: append `-fsanitize-coverage=trace-pc-guard` to every
   C/C++ source set in the graph (and `-fsanitize=address -fno-omit-frame-pointer`
   for the asan variant). The zig analog of overriding `CC.target`.
2. The AFL runtime lives only in the harness executable (`afl-compiler-rt.o` added as an
   object), exactly as in route 3b.
3. `resources/covstub.c` is compiled into the `.node` so its undefined coverage symbols
   resolve to weak no-ops and plain node can still `dlopen` it. Under the harness the
   real runtime interposes.
4. The harness TU is compiled by `zig cc`, not by `afl-clang-fast`, so the persistent
   macros come from `-include $R/afl_shim.h`. The shim defines all five
   (`__AFL_INIT`, `__AFL_LOOP`, `__AFL_FUZZ_INIT`, `__AFL_FUZZ_TESTCASE_BUF`,
   `__AFL_FUZZ_TESTCASE_LEN`); with only the first two, the template's persistent path
   is silently compiled out. Check: `strings harness | grep -c SIG_AFL_PERSISTENT`.

`FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION` cannot fire on this route: only the
afl-clang-fast wrapper defines it, and zig cc does not. `undef_fuzzmode.h` is moot.

## Setting it up

```sh
cd $W && . ./fuzz.env
mkdir zbuild && cd zbuild
cp $R/wrapper_build.zig build.zig
cp $R/covstub.c .
cat > build.zig.zon <<'EOF'
.{ .name = .zbuild, .version = "0.0.0", .fingerprint = 0x0,
   .dependencies = .{ .pkg = .{ .path = "../<pkg>" } }, .paths = .{""} }
EOF
zig build 2>&1 | grep fingerprint        # zig rejects 0x0 and prints the value to use
```

Match the publish workflow's target and optimize mode (read `.github/workflows/`), or
the real stack and the harness are not the same code:

```sh
cd $W && . ./fuzz.env && cd zbuild
T="-Dtarget=aarch64-linux-gnu.2.28 -Doptimize=ReleaseFast"
zig build $T --prefix $W/out/plain                       # .node, lib<name>glue.a, lib<dep>.a
$R/gen_stubs.sh $W/out/plain/lib/lib<name>glue.a > $W/out/plain/stubs.cc   # see below
zig build harness $T -Dharness=$W/harness.cc -Dstubs=$W/out/plain/stubs.cc \
    -Dshim=$R/afl_shim.h -Dafl_rt=$($R/find_afl_rt.sh) --prefix $W/out/plain
zig build $T -Dasan=true --prefix $W/out/asan
zig build harness $T -Dasan=true -Dasan_rt=$(dirname $($R/find_asan_rt.sh)) ... --prefix $W/out/asan
```

The addon is installed to `lib/<name>.node`; point the real-stack harness at it with
`ADDON=` as usual. If the package loads a per-platform optional dependency
(`<pkg>-linux-arm64`), `npm install --no-save --omit=dev --ignore-scripts` fails with
`EBADPLATFORM ... Valid cpu: arm64 / Actual cpu: arm64` (an npm bug); add `--force`.

The wrapper takes `-Dname=` (the Compile step that builds the `.node`; required, there is no
default) and `-Dpkg=` (the dependency name in the zon, default `pkg`).

## Traps met on the way

* **`Module.linkLibrary` asserts `kind == .lib`.** A dependency added with `addObject`
  (the binding's node-api object) panics it with `reached unreachable code`. The wrapper
  branches on `c.kind` and uses `addObject` for objects.
* **zig archives name their members by cache path** (`.zig-cache/o/<hash>/x.o`), so
  `find_boundary.sh` over `ar x` output sees nothing. Copy the objects out of the cache
  by basename and rank those.
* **The addon may not be an ObjectWrap at all.** The zig build's image-surface class takes
  `std::optional<Napi::Env>` and guards every runtime call on it, because the package
  itself decodes SVG-embedded images without an env. Constructed with `std::nullopt` the
  whole decode tree is binding-free, and the real object is linked, nothing copied.
  Look for that pattern before reaching for the copy-the-method recipe.
* **An output buffer the decoder never fully writes** (a MIME-mode JPEG path allocating
  an alpha mask and leaving most of it untouched) hashes differently on every run on
  *both* sides. That is not a fidelity gap and not an oracle ceiling in the usual sense:
  mark the mode lossy, and note it as a finding (uninitialised memory reaches the API).
* **`REBUILD` for the self-test** is two `zig build` invocations of the asan variant
  (`out/asan`, then `harness`) plus copying the drivers; `rebuild_asan.sh` is node-gyp
  only. Write a four-line wrapper that runs them and pass it as `REBUILD=`.

## What it produced

On the image-decoding binding's next major version (a zig build): all three variants' checks passed on the first instrumented
build after about six minutes including the zig download; the gate agreed on 32/32 and
later 341/341 seeds against both the npm oracle and the zig-built addon; the self-test
detected an injected overflow in the BMP parser; and the corpus skill then reached
5057 edges from a 3037-edge baseline, with two real heap overflows reproduced on the real
stack (an unbounded `memcpy` in the PNG read callback, and the "range check before a
sign flip" pattern from the corpus skill's bug table in the BMP parser).
