---
name: build-a-nan-napi-fuzzing-harness
description: Build a direct AFL++ fuzzing harness for the native library behind a Node NAN, node-addon-api or N-API addon, bypassing node while executing the same machine code. Use when asked to fuzz a native Node dependency or an npm package with a native addon (an image, XML, compression, regex, stylesheet or parser binding), to harness the C or C++ library behind a node-gyp build (binding.gyp) or a prebuild or prebuilt .node file, or when an interpreter-hosted fuzzer is too slow. It proves the harness before any campaign with a fidelity gate against an independently installed copy of the package, a detection self-test with an injected fault, and a smoke run for crashes of its own. The first of four skills - then derive-a-fuzzing-corpus-from-source, run-a-fuzzing-campaign, triage-fuzzing-findings.
---

# Build a direct fuzzing harness for a NAN/N-API dependency

Goal: delete node from the loop while still executing **the same machine code** the
addon executes. A fast harness that tests something subtly different is worse than no
harness, so every step below ends in a check that it is still faithful.

`resources/` holds the scripts (`$R/` in every command); every step names the one it
uses. `references/` holds the long form of each rule, with its cases. Read a reference only
when the step points you at it or a check fails. `EVIDENCE.md` says which target taught
each rule. Read this file with a file reader, not `cat` into a terminal.

**Layout convention** (the scripts assume it): a fuzz workspace holding `fuzz.env`
(step 1), an independent `oracle/` install for the real stack, `out/<variant>/` for each
build (`plain`, `asan`, and `pristine` when you need it) with the snapshotted `Release/` tree, vendored archives
under `lib/`, the makefile, `harness`, `harness-fork`, `map_size` and `dict.afl`, and the corpus in
`corpus/`. The package itself is an unpacked tarball, a clone or `node_modules/<pkg>`
elsewhere; always pass `build_addon.sh` an **absolute** `OUT=` into the workspace, or it
writes `out/` into the package.

**The whole path, for the common case** (library compiled into a node-gyp addon):

```sh
cd $W && . ./fuzz.env     # first line of every block, once step 1 has written fuzz.env
# 1  <this skill's resources directory>/init_workspace.sh W=/abs/fuzz PKG_NAME=<pkg> PKG=/abs/fuzz/oracle/node_modules/<pkg>
#    an independent oracle install ($W/oracle), then $R/check_symbols.sh
# 2  (cd <package dir> && $R/build_addon.sh VARIANT=plain OUT=$W/out)   # FROM THE PACKAGE DIRECTORY
#    $R/find_boundary.sh $(find out/plain/Release/obj.target -name '*.o')   -> the function to call
#    decide the modes: $R/init_workspace.sh W=$W MODES="MODE=file"
# 3  (cd <package dir> && $R/build_addon.sh VARIANT=asan OUT=$W/out)        -> out/asan/
#    $R/init_workspace.sh W=$W ADDON_ASAN=... REAL_ASAN="..."
# 4  harness.cc from $R/harness_template.cc, then for v in plain asan:
#    $R/link_harness.sh VARIANT=$v MK=out/$v/<target>.target.mk SRCDIR=<package dir> \
#        LIB="$(find out/$v/Release/obj.target/<dep> -name '*.o')" [ADDON_OBJS=...]
# 5  real_harness.mjs from $R/real_harness_template.mjs; $R/init_workspace.sh W=$W REAL="..."
#    $R/mkgate.sh OUT=./corpus SAMPLES=...; $R/gate.sh DIRECT=./out/plain/harness-fork, then asan
# 6  $R/smoke.sh SMOKE_S=30, then, once smoke passes (its fixes rebuild the harness,
#    which would stale a self-test): $R/detect_selftest.sh ... REBUILD=./rebuild.sh > selftest.txt 2>&1
#    then: corpus skill -> run-a-fuzzing-campaign -> triage-fuzzing-findings
```

The order is **gate -> smoke -> self-test**. Smoke failures force harness fixes, and the
self-test vouches only for the binary it ran against, so running it before the smoke
means running it twice. After any harness change, re-run the gate too.

---

## Step 1 — Triage, before building anything

**First, write the workspace file**, running the script by its absolute path in this
skill's resources directory:

```sh
<this skill's resources directory>/init_workspace.sh W=/abs/fuzz PKG_NAME=<pkg> PKG=/abs/fuzz/oracle/node_modules/<pkg>
```

Each tool call is a fresh shell, so `fuzz.env` holds `R`, `W`, `MODES` and the rest
once: every skill's scripts read it as defaults (an explicit argument wins), and **every
command block in all four skills starts with `cd $W && . ./fuzz.env`**, `$W` written out
as the absolute path. `init_workspace.sh` ends by running `preflight.sh` (toolchain, GNU sed, `timeout`, core_pattern), so a missing tool fails
now, not mid-campaign. Keys learned later (`MODES`, `ADDON_ASAN`, `REAL_ASAN`, `REAL`)
are added by re-running it with only those keys, at the step that names them.

Then the independent install the gate compares against:

```sh
cd $W && . ./fuzz.env
mkdir -p out oracle
(cd oracle && npm init -y >/dev/null && npm install $PKG_NAME@<version>)   # the REAL stack, at $PKG
ls oracle/node_modules/$PKG_NAME/build/Release/*.node    # or the prebuild it fetched
$R/init_workspace.sh W=$W PKG=$PKG     # again, so it reads PKG_VERSION from the install
$R/check_symbols.sh                    # [DEPENDENCY-]INTERPOSED: references/interposition.md
```

Pin `@<version>`: `PKG_VERSION` is read back from whatever got installed. The `ls` is
the check (npm 11's `allowScripts` warning is only a warning). A package that loads a prebuilt instead of building: snapshot it
(`references/build-traps.md`, "The oracle install").

**`INTERPOSED`**: the installed addon binds to node's own copy of a library it vendors,
so the vendored code is dead in the real stack. Build the symbolic oracle in
`references/interposition.md` before step 2.

**Build from the published tarball**, `npm pack $PKG_NAME@$PKG_VERSION` unpacked (`tar
xzf` gives `package/`): it is what the oracle compiled, and a clone can lack sources a
release step generates. Use a clone only when HEAD is the target, and state both
versions in the write-up. Either tree takes only the dependency-only install, `npm
install --no-save --omit=dev --ignore-scripts` (`references/build-traps.md`, "Building
from a clone"), never a plain `npm install`.

**Is a direct harness the right tool here?** Decide now. If every call costs
milliseconds *at the smallest input the API accepts* (a renderer, a compressor at its
default level), or everything interesting is inside an uninstrumented system library,
say so and stop. Not that case: an input-chosen cost (bound it, step 4), or a slow entry
point beside a cheap parser of the same bytes (harness the parser as a mode). Do not
measure or report the speed-up over the interpreter.

**No `binding.gyp` at HEAD** (a zig, cargo or meson build): harness that build (for zig,
`references/zig-build.md`). **A lockfile pinning an old `nan`**: retry with
`--no-package-lock`. **A binding over system libraries** (image codecs): build the oracle
from source, `npm_config_build_from_source=true npm install`. All three in
`references/build-traps.md`.

Then answer six questions. Each is one command.

1. **Which ABI, and is the glue hand-written or generated?** Find the glue by what it
   includes, not by directory: run the block in `references/build-traps.md`, "Finding the
   glue" (it prints the glue files, `$SRCDIR`, `NAN` / `node-addon-api` / `N-API (C)` and a
   generator's mark). Generated glue (SWIG, pybind11, napi-rs) has no binding-free
   function and nothing to link: the risk is the state its init block installs (step 4,
   layer 3). Hand-written glue *may* have a boundary; step 2 settles it.
   Questions 2 and 3 read `build/`: answer them after the first `build_addon.sh` (step 2),
   or question 2 on the oracle's addon. A pack tree's own `build/` is the publisher's
   (stale binaries); `build_addon.sh` deletes it.
2. **Is the library compiled into the addon, or a separate shared object?**
   ```sh
   cd $W && . ./fuzz.env && cd <package dir>
   ldd build/Release/*.node | grep -vE "libc|libstdc|libgcc|libm|linux-vdso|ld-linux"
   ```
   Empty: compiled in, link its objects (step 3a). A project-built or system `.so`: step
   3b decides what to instrument (the addon's own parsing, plus an archive of the one
   library the bytes go straight into); the rest stay uninstrumented, and you **state
   that scope** (step 5 reads differently then).
3. **Which optional features did the build detect?** A missing `-dev` package does not
   fail the build; it turns a decoder into dead code.
   ```sh
   cd $W && . ./fuzz.env && cd <package dir>
   find build -name '*.target.mk' | xargs grep -ohE 'HAVE_[A-Z0-9_]+|WITH_[A-Z0-9_]+' | sort -u
   ```
   A lone `HAVE_*_CONFIG_H` means reading the vendored config header (`references/build-traps.md`).
4. **Which binary does the package actually load?** Ask the loader (`bindings`,
   `node-gyp-build`, a plain `require` in `lib/*.js`, a copy such as
   `build/bindings/<name>.node`), not the directory, and run `file` on the result: a
   prebuild can be the wrong architecture. A prebuilt that loads is an asset: gate
   against it later. The commands: `references/build-traps.md`.
5. **Does the addon build on this node?** If not (removed V8 API, `#error "C++20 or
   later required."`), install the node version the package supports. Never patch the
   package: then the real stack is no longer the published package. Check whether a
   peer range is what pinned the version before concluding you are stuck.
6. **How many addons?** `grep target_name binding.gyp`. With several, name the
   boundary's target (`TARGET=` from step 3 on) and record
   `$R/init_workspace.sh W=$W ADDON_MATCH='<name>\.node$'`, so the sanitized swap and
   triage pick one. A second addon the JS needs is compiled into the harness
   (`references/build-traps.md`, "Several addons in one package"). A `postbuild` target
   whose `.node` no `lib/*.js` requires is not an addon: no `ADDON_MATCH`.

---

## Step 2 — Find the boundary

The deepest function the binding calls that touches no binding API itself.

**Look for an AsyncWorker first.** In node-addon-api and NAN packages the real work is
usually in `SomeWorker::Execute()` (or the callback given to `napi_create_async_work` /
`uv_queue_work`), which by construction may not touch the runtime. When it exists it is
the boundary, run on a libuv thread whose stack size matters for triage, if the JS passes
the async flag: a wrapper that never does runs it on the main thread.

```sh
cd $W && . ./fuzz.env
grep -rn 'AsyncWorker\|::Execute()\|napi_create_async_work\|uv_queue_work' <glue dir>/
$R/find_boundary.sh $(find out/plain/Release/obj.target -name '*.o')   # rank EVERY object
nm -uC <candidate.o> | grep -E 'Napi::|napi_|v8::|node::'          # which functions own the refs?
```

The ranking needs objects (after a prebuilt fetch, `build_addon.sh VARIANT=plain` first);
rank an archive in `out/plain/lib/` too (`references/boundary-shapes.md`). Library objects at 0 and addon objects at 20-60 is the
whole picture; the lowest count is where to start reading, not the answer: the criterion
is *a function on your input path whose own body is binding-free*.

Prefer a function that already does the dispatch and the option plumbing, so the
package's format sniffing and limit checks are *its* code, not your copy. If the package
exposes several entry points over the same engine (buffer vs file, parse vs parse-html),
harness them behind an **environment variable**, never an input byte: a corpus
file stays byte-for-byte what the real API consumes, so any seed or crash replays
unchanged on the real stack. A mode is for a handful of entry points; a free-form
argument with a large value space that selects code (an encoding-name pair choosing one
of a hundred converters, a flags string) is input, framed into the file (step 4), when
the mode is about it; otherwise the arm uses the defaults and the write-up lists those
options as not covered.
**Decide the modes now**, before the first gate: a mode
added later rebuilds the harness and reruns gate, smoke and self-test. Keep a mode only
if it reaches library code the default does not (a different decoder, the compressor
behind a decompressor, a different parser state machine), and stop at two or three, since
each multiplies every later step. Thin wrappers over one call (exec vs test vs match) are
one mode: fuzz the richest and say so. A mode that cannot reject its input (a compressor)
gets `:min_arms=1` in the gate's `MODES=` spec, so check 3 stays strict for the default.
Record the modes now, in the gate's spelling; every later script reads them from there:

```sh
cd $W && . ./fuzz.env
$R/init_workspace.sh W=$W MODES="MODE=file"     # MODES="" when there is only the default
```

For a generated binding, skip the ranking: `grep -n '<libraryEntryPoint>(' <glue dir>/<generated>.cc`.

**No single binding-free function?** Expect one of three shapes, each with its recipe in
`references/boundary-shapes.md`: the work is a method of an `ObjectWrap` subclass (copy
its body; by script when it fans out to many helpers), every addon function emits into the runtime (mirror the library's API and the
handler registration), or the dispatch is in JavaScript (library objects at 0, every glue
function short: drive the C API as `lib/*.js` does, after probing the oracle for a deferred
`_flush` error and a state that loops forever).

---

## Step 3 — Build the variants

Two variants now, one at a time, each snapshotted into `out/<variant>/`: `plain`
(throughput) and `asan` (bug finding). A third, `pristine` (ASAN, no AFL
instrumentation), is the control for "did my instrumentation invent this bug?": build
it once a smoke or campaign has saved a crash, before triage (triage skill, step 2).

Every afl-clang-fast variant gets `-include undef_fuzzmode.h` (the scripts pass it):
the wrapper defines `FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION` and libraries compile
checks **out** under it (`references/build-traps.md`). Each also writes
`out/<variant>/dict.afl`, the constants the instrumented code compares input against,
which the corpus skill merges into the campaign's dictionary.

### 3a. Library compiled into the addon (the common case)

```sh
cd $W && . ./fuzz.env && cd <package dir>
for v in plain asan; do
  $R/build_addon.sh VARIANT=$v OUT=$W/out [TARGET=<gyp target_name>] [NODE_GYP=...] [EXTRA_LDFLAGS=-Wl,-Bsymbolic]
done
```

It checks the runtime, coverage, ASAN and that node loads the result, then snapshots
the build into `out/<variant>/` (`references/build-traps.md`).

Then record the sanitized addon and the sanitized real-side command, which the asan
gate, `smoke.sh` and triage use:

```sh
cd $W && . ./fuzz.env
A=$W/out/asan/Release/<name>.node
$R/init_workspace.sh W=$W ADDON_ASAN=$A \
    REAL_ASAN="env LD_PRELOAD=$($R/find_asan_rt.sh) PKG=$PKG ADDON=$A node $W/real_harness.mjs"
```

**cmake-js packages** (`build_addon.sh` is node-gyp only) and **an addon clang will not
compile** (`ADDON_CXX=g++`, linked addon objects then carry no coverage): `references/build-traps.md`.

### 3b. Library is a separate shared object, or the whole package is built by zig

Build the addon as in 3a: its own parsing (format sniffing, a BMP or EXIF reader) is
often the boundary, and where the bugs usually are. Then rebuild **one** library, the
one the bytes go straight into, as an instrumented static archive (the AFL runtime
cannot live in a `.so`) of the version the oracle loads, with the distro's ABI options:

```sh
cd $W && . ./fuzz.env
for v in plain asan; do $R/build_lib.sh VARIANT=$v SRC=$W/src-lib [BUILD=cmake] [CMAKE_ARGS=...]; done
# step 4 links it: LIB=$W/out/$v/lib/lib<x>.a ARCHIVE_LIBS=<x>
```

Which library, the source, the ABI trap, the build flags, the shared-only route
(`$R/covstub.c`), zig (`references/zig-build.md`) and `afl_shim.h`:
`references/build-traps.md`, step 3b.
The real side still loads the uninstrumented system `.so`, so its sanitized column cannot
see an overflow inside the library: say so in the write-up and the triage report
(`references/oracle-ceiling.md`, section 4).

---

## Step 4 — Write the harness

Start from `$R/harness_template.cc`. It copies the input into an exactly sized
`malloc`, reads modes (and opt-in ceilings) from the environment, prints the one-line
`in_len= status= err= out_len= out_hash= lossy= invariant=` contract, frees its init state
in the single-shot path (or ASAN's LeakSanitizer kills it before it prints), and builds
both drivers from one TU. For a **streaming** API hash the concatenated output chunks; for
a **callback-driven** (SAX) library hash the serialised event stream with every argument
the real handlers read (both templates sketch each). What you add is the mirroring of
**four layers**. The checklist; the long form with cases is
`references/four-layers.md`. The template does not compile until you have filled in each
section you must edit (headers, the mode switch, the boundary call, forcing the work):
each carries an `#error` line to delete with it. For the copy-the-method shape keep the
drivers (the template's tail) and replace sections 5 to 8 wholesale, `#error` lines too.

1. **The object the runtime owns.** Prefer a library factory. If the runtime allocates it,
   reach private fields with the explicit-instantiation trick in the reference, never a
   header patch, and never `memset` a C++ object.
2. **The option layer, and the dispatch.** Defaults live in `lib/*.js`; the addon often
   has a default-constructed descriptor that encodes them. Check whether JS also decides
   *which* native call runs and *how big a buffer* it gets. Mirror that dispatch in the
   same order and its ceiling, asking the runtime for limits rather than quoting them:
   a C harness cannot call node, so pass them in at build time,
   `EXTRA_FLAGS="-DNODE_KMAXLENGTH=$(node -p 'require(\"buffer\").kMaxLength')"`, and
   `#error` when the macro is missing rather than defaulting it.
3. **Process-global state the init block installs.** Custom allocators (they decide what
   a sanitizer can see), error handlers, and the **full handler set** of a callback-driven
   library, reading the same arguments the real handlers read and returning what they
   return. Runtime-only branches inside a mirrored hook must **trap**.
   ```sh
   cd $W && . ./fuzz.env
   grep -rn "NAN_MODULE_INIT\|NAPI_MODULE_INIT\|napi_register_module_v1\|%init" <glue dir>/
   grep -rniE "MemSetup|SetAllocator|RegisterNode|_default\(|SetErrorFunc" <glue dir>/
   ```
4. **What the exported function does after the boundary returns.** Read the whole
   function: post-processing that fills in API-visible fields is common and is never
   offered as a boundary candidate.

Also (`references/four-layers.md`): **how the bytes are delivered**: file bytes map to
the API value losslessly; several arguments, or an option string that selects code, go
in one file, split identically on both arms, the framing documented at the top of
`harness.cc`; a raw `Buffer` or a NUL-terminated, transcoded JS string. And **make the
library do the work**: an open is not a decode; reset only what is safe to reset.

**The `err` field is one token, identical on both sides**, because the corpus skill's
histograms steer by it. The real template's default takes `e.code`, else the message up
to the first `": "`, since a `<what>: <input>` message would make `err` unique per seed;
a message that embeds the input elsewhere gets a `code` in the arm, mirrored in `harness.cc`
(a trailing position: the `errToken` suffix hook; embedded digit runs: `N`). A binding that maps every
library error to one message: add the template's ungated `lib_err=` field (not in
`FIELDS`) and tell the corpus skill `validate.sh FIELD=lib_err` (`references/four-layers.md`, "The `err` token").

**Attacker-declared sizes and work get no cap by default**: mirror node's tokens
(`ERR_OUT_OF_RANGE`, `ERR_MEMORY_ALLOCATION_FAILED`) and the package's own bound. Opt-in
`ALLOC_CEIL=` / `WORK_CEIL=` apply on both arms at the declared field; an unbounded
input-controlled work factor is a finding (`references/four-layers.md`, layer 2).

Then link:

```sh
cd $W && . ./fuzz.env
$R/link_harness.sh VARIANT=plain MK=out/plain/<target>.target.mk SRCDIR=<package dir> \
    LIB="$(find out/plain/Release/obj.target/<dep> -name '*.o')" \
    [ADDON_OBJS="out/plain/Release/obj.target/<target>/src/<file>.o"]
```

`<dep>` is the library's own path under `obj.target`: a separate gyp target
(`obj.target/<dep>/`), or its vendored subtree when it is compiled into the addon's own
target (`obj.target/<target>/vendor/<dep>/`). Never the whole `obj.target/<target>/`,
which also holds the addon's own objects, and those carry binding references.

It lifts the addon's flags from the makefile (`-fno-rtti` and feature macros must match),
generates trapping stubs for every binding symbol the addon objects reference, proves
one aborts, links `harness` and `harness-fork`, and records the map size. Repeat per variant.

**If you link no addon object**, or the only one has **zero** binding references
(`link_harness.sh` prints `none: ... nothing to trap`), gate check 5 passes vacuously:
record it as N/A. Your entire fidelity claim is then the step-5 comparison, so it has to
compare the deepest artifact the API exposes, not a status code.

**A link error naming the package's own method** (`undefined reference to
<pkg>::Stream::method()`): link the object that defines it, or stub it with
`NAMESPACES="Napi v8 node <pkg>"` (`references/build-traps.md`).

---

## Step 5 — Gate it

Write `$W/real_harness.mjs` from `$R/real_harness_template.mjs`. It loads `$PKG`, swaps in a sanitized addon with `ADDON=` (refusing with
`ADDON-NOT-SWAPPED` when no load was redirected), and prints the same line. Its consumer
calls live in an `ENTRIES` object **keyed by the harness's `MODE` value** (`default` when
unset): one arm per entry point, no options (unless the mode frames them, step 2), no error listener a user would not add, each
named after the entry point it reaches (`MODE=file` → the `file` arm). That object is the
chain's contract: the campaign records each mode's `entry` as this key and triage's
`confirm.mjs` uses the object unchanged, so the calls are written once, here. Its catch branch hashes what the
arm's callbacks put in the `collected` buffer before the error, so the direct harness
hashes the same partial stream on a reject. The swap mechanics are in
`references/oracle-ceiling.md`, section 0. Then record `REAL`, write the gate corpus,
and gate (by hand, after sourcing `fuzz.env`: `$REAL <file>`). The gate corpus is
15 to 40 seeds: one valid sample per entry point and per dispatch branch, written by
hand in the framing, plus truncations and flips of them for the reject arm (`mkgate.sh`
writes seven per sample: start from a few):

```sh
cd $W && . ./fuzz.env
$R/init_workspace.sh W=$W REAL="env PKG=$PKG node $W/real_harness.mjs"
$R/mkgate.sh OUT=./corpus SAMPLES="corpus/<valid> ..."    # [TRUNC=3] [FLIPS=3] [EMPTY=1]
$R/gate.sh DIRECT=./out/plain/harness-fork CORPUS=./corpus MAP_SIZE=$(cat out/plain/map_size) JOBS=6
```

`REAL`, `FIELDS`, `SOFT_FIELD`, `SOFT_DROP` and `MODES` come from `fuzz.env`; pass one
on the command line only to override it. The whole gate runs once per `MODES` setting,
exported to both sides, and fails if any mode fails. `SOFT_DROP` must name **every field
the oracle's loss can change** (a U+FFFD substitution changes `out_len` as well as
`out_hash`; the default drops both). `JOBS` runs seeds in parallel.

The gate's five checks:

1. **Every seed reaches the library.** Exit 0 licenses nothing.
2. **Byte-exact agreement on the deepest artifact the API gives you** (the serialized document, every pixel, the hashed event stream): it proves the *option* mirroring, not just the parse.
3. **Both arms populated, plus one seed per branch of the mirrored dispatch**: truncate and bit-flip seeds for rejects; `MIN_ARMS=1` only for a target that cannot reject.
4. **Coverage discriminates**: a trivial input scoring nearly as many tuples as a real one means you are measuring init, unless the decoders are in an uninstrumented system `.so` (check `nm -D <lib.so> | grep -c sancov` is 0 first): there rejects out-score successes. A tiny decoder whose rejects all die at one point also trips the WARN: harmless when the gate passes.
5. **The stubs stayed unreachable**: the gate reads the marker from stderr per seed.

`references/oracle-ceiling.md` ("Comparison strength") has the dispatch branches check 3
needs a seed for.

**On a mismatch, read `references/oracle-ceiling.md` before touching the harness.** The
order there: symbol interposition (`references/interposition.md`), a read of out-of-bounds or **uninitialised** memory in the target (ASAN
sees only the first), then the oracle's own lossy
transformations (`lossy=1` and the soft field), and only then your mirroring. A target
bug of the first kind is a finding: have the real side mark exactly those inputs
`lossy=1` so the gate stays honest, and write it down. A seed that crashes both sides is
`CRASHES-BOTH`, also a finding; one that kills only the real side is `CRASHES-REAL-ONLY`,
a bug above the boundary or in the binding's bookkeeping. The gate files them as
`crashers/gate-both-<orig>` / `gate-real-<orig>` with a summary row for triage, counts
them apart and does not fail (`references/oracle-ceiling.md`, section 5). Re-run the gate after the corpus
skill has produced a real corpus; a gate corpus is too small to find the oracle's ceiling.

Gate the `asan` variant too, with the sanitized addon swapped in and the sanitizer
runtime preloaded **inside the real-side command**, never in front of `gate.sh`. Given
a sanitized `DIRECT`, `gate.sh` uses `REAL_ASAN` (step 3), which does exactly that:

```sh
cd $W && . ./fuzz.env
$R/gate.sh DIRECT=./out/asan/harness-fork CORPUS=./corpus
```

If **every** seed has no output, the command is broken, not the seeds:
`references/oracle-ceiling.md`, section 0, has the symptoms of a misplaced preload and
the allocation ceiling the gate's `ASAN_OPTIONS` carry.

---

## Step 6 — Smoke it, then prove it detects

### Smoke it: does the harness crash on its own account?

The gate's corpus is mostly valid input, so it never reaches the error paths where a
harness is most likely wrong; a short run finds those in seconds.

```sh
cd $W && . ./fuzz.env
$R/smoke.sh SMOKE_S=30 > smoke.log 2>&1 &     # then read smoke.log when it exits
```

Run it, and the self-test below, detached: the real-stack replay can make it take minutes.
It replays every seed and fuzzes each variant briefly per mode (`MODES` from `fuzz.env`),
then replays one crash per site on the real stack (`HOSTSAN`, default `REAL_ASAN`).
Exit 1 on `HARNESS-FRAME` (the innermost project frame is the harness's own code) or
`DIRECT-ONLY` (crashes the harness, not the real stack); exit 2 when the smoke itself
did not happen.
One representative per `REAL` or `PERSISTENT-ONLY` site lands in `crashers/` with a
summary row, for triage: copy nothing by hand. It reports `hangs=N` and files one hang
per variant and mode that still runs on replay into `hangs/`, which triage screens. The other classes and low stability are
in `references/smoke.md`. **A `PASS` means the harness is not obviously wrong, not that
it is right**: the gate and the self-test do that.

### Then prove it detects

First write `rebuild.sh` once in the workspace: the `REBUILD` the script runs twice
(fault applied, then restored), with the arguments you gave `build_addon.sh` and
`link_harness.sh`. It is a file, so it finds the workspace from its own path:

```sh
#!/bin/sh
cd "$(dirname "$0")" && . ./fuzz.env
exec $R/rebuild_asan.sh PKGDIR=<package dir> OUT=$W/out MK=$W/out/asan/<target>.target.mk SRCDIR=<package dir> HARNESS=$W/harness.cc \
    LIB="$(find $W/out/asan/Release/obj.target/<target>/<lib dir> -name '*.o' | tr '\n' ' ')" \
    [TARGET=...] [ADDON_OBJS=...] [EXTRA_FLAGS=...] [EXTRA_LDFLAGS=...] [NODE_GYP=...]
```

`LIB=` and the bracketed arguments are the ones the asan link took (for a 3b archive,
it and `ARCHIVE_LIBS=`): `references/selftest-rebuild.md`.

`PKGDIR=` is the package source (`rebuild_asan.sh` refuses one under `oracle/` or `node_modules/`). Never send the build output to `/dev/null`: `detect_selftest.sh` shows it on failure. Then:

```sh
cd $W && . ./fuzz.env && chmod +x rebuild.sh
$R/detect_selftest.sh FAULT_SRC=<lib>/src/foo.c \
    FAULT_SED='/^Decoder::parseHeader/,/^}/s|p\[n\] = 0;|p[n + 1] = 0; /* INJECTED */|' \
    REBUILD=./rebuild.sh HARNESS=./out/asan/harness-fork CORPUS=./corpus \
    [SEED=corpus/<one that takes the faulted path>] > selftest.txt 2>&1
```

`FAULT_SED` must write the word `INJECTED` (the marker the script checks; `MARKER=`
changes it). The fault must land **past an allocation boundary**, anchored to its function
(`/^Func/,/^}/`). The seed must take the **dispatch branch** the fault sits on: pass
`SEED=` rather than trusting the script's pick (a pattern that selects another engine
misses it), and export the `MODE=` that reaches it.
`references/selftest-rebuild.md` has why.

The restore relinks the asan harness, so re-run the asan gate after the self-test. When
a gyp action re-extracts the library source during configure, or a zig build,
`references/selftest-rebuild.md` has the `rebuild.sh` body to use instead.

**Keep `selftest.txt`** with its `PASS:` line: the campaign skill refuses to run
without it (no finds against a harness that detects nothing is not a result) and flags a
harness newer than it as stale, so re-run it after every rebuild.

Then hand over to the corpus skill, then run-a-fuzzing-campaign, then triage-fuzzing-findings.

---

## Traps that cost hours

Most are checks inside the scripts; the symptoms none catches are tabled at the end of
`references/build-traps.md`. afl-fuzz runtime symptoms belong to **run-a-fuzzing-campaign**.
