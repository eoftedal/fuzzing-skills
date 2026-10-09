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
#    snapshot the prebuilt and make an independent oracle install ($W/oracle)
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

Every build step overwrites `build/Release`, so next:

```sh
cd $W && . ./fuzz.env
mkdir -p out oracle
[ -d node_modules/$PKG_NAME/build/Release ] && cp -a node_modules/$PKG_NAME/build/Release out/prebuilt
(cd oracle && npm init -y >/dev/null && npm install $PKG_NAME@<version>)   # the REAL stack, at $PKG
ls oracle/node_modules/$PKG_NAME/build/Release/*.node    # or the prebuild it fetched
$R/init_workspace.sh W=$W PKG=$PKG     # again, so it reads PKG_VERSION from the install
```

Pin `@<version>` when a version is the target: `PKG_VERSION` is read back from whatever
got installed. The `ls` is the check: an oracle without a built addon is the first thing
that breaks (`references/build-traps.md`, "The oracle install").

**Build from the published tarball**, `npm pack $PKG_NAME@$PKG_VERSION` unpacked (`tar
xzf` gives `package/`): it is what the oracle compiled, and a clone can lack sources a
release step generates. Use a clone only when HEAD is the target, and state both
versions in the write-up. Either tree takes only the dependency-only install, `npm
install --no-save --omit=dev --ignore-scripts` (`references/build-traps.md`, "Building
from a clone"), never a plain `npm install`.

**Is a direct harness the right tool here?** Decide it now, not at the end. If every
call costs milliseconds *at the smallest input the API accepts* (a renderer, a
compressor at its default level), or everything interesting is inside an uninstrumented
system library, a direct harness buys less than it costs to keep faithful: say so and
stop. Two things that look like that and are not: an input-chosen cost (slow only when
the attacker says so: bound it, step 4), and a slow entry point beside a cheap parser
of the same bytes (harness the parser as a mode). The speed-up over the interpreter is
otherwise a given, not a result: do not measure or report it.

**No `binding.gyp` at HEAD** (a zig, cargo or meson build): harness that build (for zig,
`references/zig-build.md`). **A lockfile pinning an old `nan`** your node cannot compile:
retry with `--no-package-lock` first. Both in `references/build-traps.md`.

Then look in `build/Release` again, because an `install` script of `prebuild-install ||
node-gyp rebuild` may already have fetched a CI binary. Snapshot whatever appeared.
`md5sum` the snapshot against the oracle's addon: if they are the same file, that is one
piece of evidence, not two.

**Oracle for a binding over system libraries** (image codecs, a 2D renderer): install it
`--build-from-source`; the prebuilt bundles another back end (`references/build-traps.md`).

Then answer five questions. Each is one command.

1. **Which ABI, and is the glue hand-written or generated?** Find the glue by what it
   includes, not by directory (`references/build-traps.md`, "Finding the glue").
   ```sh
   cd $W && . ./fuzz.env && cd <package dir>
   GLUE=$(grep -rl --include='*.c' --include='*.cc' --include='*.cpp' --include='*.cxx' --include='*.h' --include='*.hpp' \
          --exclude-dir=node_modules --exclude-dir=deps --exclude-dir=vendor --exclude-dir=build \
          -e 'nan.h' -e 'napi.h' -e 'node_api.h' .)
   if [ -z "$GLUE" ]; then echo "no glue found: read binding.gyp's sources"; else
   SRCDIR=$(dirname $(echo "$GLUE" | head -1)); echo "$GLUE"
   grep -l 'nan\.h' $GLUE >/dev/null && echo NAN; grep -l 'napi\.h' $GLUE >/dev/null && echo node-addon-api
   grep -l 'node_api\.h' $GLUE | grep -q '\.c$' && echo 'N-API (C)'
   grep -lim1 "swig\|automatically generated\|pybind11\|DO NOT EDIT\|napi-rs" $GLUE; fi
   ```
   The glue TUs are every `.cc` or `.c` in `$SRCDIR` (write its path out in later blocks,
   the shell does not keep it), not only the hits. Generated glue (SWIG,
   pybind11, napi-rs) has no binding-free function and nothing to link: the risk is the state its init block installs
   (step 4, layer 3). Hand-written glue *may* have a boundary; step 2 settles it.
   Questions 2 and 3 read `build/`, which an `npm pack` tree lacks until the first
   `build_addon.sh` (step 2): answer them then, or question 2 on the oracle's addon.
2. **Is the library compiled into the addon, or a separate shared object?**
   ```sh
   cd $W && . ./fuzz.env && cd <package dir>
   ldd build/Release/*.node | grep -vE "libc|libstdc|libgcc|libm|linux-vdso|ld-linux"
   ```
   Empty: compiled in, link its objects (step 3a). One project-built `.so`: step 3b. Many
   system libraries with some parsing in-tree: instrument the addon, accept the system
   libraries as uninstrumented, and **state that scope** (step 5 reads differently then).
3. **Which optional features did the build detect?** A missing `-dev` package does not
   fail the build; it turns a decoder into dead code.
   ```sh
   cd $W && . ./fuzz.env && cd <package dir>
   find build -name '*.target.mk' | xargs grep -ohE 'HAVE_[A-Z0-9_]+|WITH_[A-Z0-9_]+' | sort -u
   ```
   A lone `HAVE_*_CONFIG_H` means reading the vendored config header (`references/build-traps.md`).
4. **Which binary does the package actually load?** Ask the loader, not the directory
   (`require('bindings')({bindings:'<name>',path:true})`,
   `require('node-gyp-build').path('<pkg dir>')`, or a plain
   `require('./build/Release/<name>.node')` in `lib/*.js`, which loads exactly that file; the
   real harness's `dlopen` hook covers all three), and run `file` on the result: a
   prebuild can be the wrong architecture. A prebuilt that loads is an asset: gate
   against it later. Details in `references/build-traps.md`.
5. **Does the addon build on this node?** If not (removed V8 API, `#error "C++20 or
   later required."`), install the node version the package supports. Never patch the
   package: then the real stack is no longer the published package. Check whether a
   peer range is what pinned the version before concluding you are stuck.

---

## Step 2 — Find the boundary

The deepest function the binding calls that touches no binding API itself.

**Look for an AsyncWorker first.** In node-addon-api and NAN packages the real work is
usually in `SomeWorker::Execute()` (or the callback given to `napi_create_async_work` /
`uv_queue_work`), which by construction may not touch the runtime. When it exists it is
the boundary, run on a libuv thread whose stack size matters for triage.

```sh
cd $W && . ./fuzz.env
grep -rn 'AsyncWorker\|::Execute()\|napi_create_async_work\|uv_queue_work' <glue dir>/
$R/find_boundary.sh $(find out/plain/Release/obj.target -name '*.o')   # rank EVERY object
nm -uC <candidate.o> | grep -E 'Napi::|napi_|v8::|node::'          # which functions own the refs?
```

The ranking needs objects: after a prebuilt fetch there are none, so run
`build_addon.sh VARIANT=plain` (step 3) first. A library a gyp action builds with its own
build system is not under `obj.target` but in `out/plain/lib/`, so rank its members too
(`mkdir t && cd t && ar x ../out/plain/lib/lib<dep>.a && $R/find_boundary.sh *.o`), or the
ranking shows only addon objects. Library objects at 0 and addon objects at 20-60 is the
whole picture; the lowest count is where to start reading, not the answer: the criterion
is *a function on your input path whose own body is binding-free*.

Prefer a function that already does the dispatch and the option plumbing, so the
package's format sniffing and limit checks are *its* code, not your copy. If the package
exposes several entry points over the same engine (buffer vs file, parse vs parse-html),
harness them behind an **environment variable**, never an input byte: a corpus
file stays byte-for-byte what the real API consumes, so any seed or crash replays
unchanged on the real stack. A mode is for a handful of entry points; a free-form
argument with a large value space that selects code (an encoding-name pair choosing one
of a hundred converters, a flags string) is input, framed into the file (step 4).
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
its body), every addon function emits into the runtime (mirror the library's API and the
handler registration), or the dispatch is in JavaScript (drive the C API as `lib/*.js` does).

---

## Step 3 — Build the variants

Two variants now, one at a time, each snapshotted into `out/<variant>/`: `plain`
(throughput) and `asan` (bug finding). A third, `pristine` (ASAN, no AFL
instrumentation), is the control for "did my instrumentation invent this bug?": build
it once a smoke or campaign has saved a crash, before triage (triage skill, step 2).

Every afl-clang-fast variant gets `-include undef_fuzzmode.h` (the scripts pass it),
because the wrapper defines `FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION` and libraries
compile checks **out** under it; `references/build-traps.md` has the cases and the grep.
Each also writes `out/<variant>/dict.afl`, the constants the instrumented code compares
input against (magic bytes, tokens, field values); the corpus skill merges it into the
campaign's dictionary.

### 3a. Library compiled into the addon (the common case)

```sh
cd $W && . ./fuzz.env && cd <package dir>
for v in plain asan; do
  $R/build_addon.sh VARIANT=$v OUT=$W/out [TARGET=<gyp target_name>] [NODE_GYP=...]
done
```

It checks the runtime, coverage, ASAN and that node loads the result, then snapshots
`build/Release`, vendored archives and the makefile into `out/<variant>/`; pass `TARGET=`
if it picks the wrong gyp target. The checks: `references/build-traps.md`.

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

**First choice, when the library's build system allows it: an instrumented static
archive** of the version the oracle loads, built out of tree per variant into
`out/<v>/lib/` and linked like a vendored one (`LIB=$W/out/$v/lib/lib<dep>.a`), since the
AFL runtime cannot live in a `.so`; export `AFL_LLVM_DICT2FILE=$W/out/<v>/dict2file.raw`
into that build after `build_addon.sh`; `link_harness.sh` merges it. The recipe is in `references/build-traps.md`.

The real side still loads the uninstrumented system `.so`, so its sanitized column cannot
see an overflow inside the library: the write-up and the triage report say so
(`references/oracle-ceiling.md`, section 4). A library that builds only shared: instrument the `.so` with
plain clang `-fsanitize-coverage=trace-pc-guard` and `$R/covstub.c`. Both routes, a zig
build (`references/zig-build.md`) and the `afl_shim.h` rule are in `references/build-traps.md`.

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

Three more things to check (`references/four-layers.md`, "How the bytes are delivered"
and "Make the library actually do the work"):

* **How the bytes are delivered:** choose the corpus encoding so file bytes map to the API
  value losslessly; several arguments, an option string that selects code among them, go
  in one file (NUL or newline separated), split identically on both arms, the framing
  documented at the top of `harness.cc`.
* **NUL termination:** note whether the input is a raw `Buffer` or a NUL-terminated,
  transcoded JS string.
* **Make the library actually do the work:** an open is not a decode; reset only what is
  safe to reset.

**The `err` field is one token, identical on both sides**, because the corpus skill's
histograms steer by it. The real template's default takes `e.code`, else the message up
to the first `": "`, since a `<what>: <input>` message would make `err` unique per seed;
a message that embeds the input elsewhere gets a `code` in the arm, mirrored in `harness.cc`.

**Attacker-declared sizes and work get no cap by default.** Mirror node's own tokens
(`ERR_OUT_OF_RANGE`, `ERR_MEMORY_ALLOCATION_FAILED`) and the package's own bound, and let
the fuzzer's memory limit bound the run. The opt-in `ALLOC_CEIL=` / `WORK_CEIL=` apply
identically on both arms, only at the attacker-declared field; an unbounded
input-controlled work factor is itself a finding (`references/four-layers.md`, layer 2).

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

Write `$W/real_harness.mjs` from `$R/real_harness_template.mjs`. It loads the
`oracle/` install, swaps in a sanitized addon with `ADDON=` (refusing with
`ADDON-NOT-SWAPPED` when no load was redirected), and prints the same line. Its consumer
calls live in an `ENTRIES` object **keyed by the harness's `MODE` value** (`default` when
unset): one arm per entry point, no options, no error listener a user would not add, each
named after the entry point it reaches (`MODE=file` → the `file` arm). That object is the
chain's contract: the campaign skill records each mode's `entry` as this key, and the
triage skill's `confirm.mjs` uses the same object unchanged, so the calls are written once,
here, where the gate proves they reach the native code. Its catch branch hashes what the
arm's callbacks put in the `collected` buffer before the error, so the direct harness
hashes the same partial stream on a reject. The swap mechanics are in
`references/oracle-ceiling.md`, section 0. Then record `REAL`, write the gate corpus,
and gate (by hand, after sourcing `fuzz.env`: `$REAL <file>`). The gate corpus is
15 to 40 seeds: one valid sample per entry point and per dispatch branch, written by
hand in the framing, plus truncations and flips of them for the reject arm:

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
4. **Coverage discriminates**: a trivial input scoring nearly as many tuples as a real one means you are measuring init, unless the decoders are in an uninstrumented system `.so` (check `nm -D <lib.so> | grep -c sancov` is 0 first): there rejects out-score successes.
5. **The stubs stayed unreachable**: the gate reads the marker from stderr per seed.

`references/oracle-ceiling.md` ("Comparison strength") has the dispatch branches check 3
needs a seed for.

**On a mismatch, read `references/oracle-ceiling.md` before touching the harness.** The
order there: a read of out-of-bounds or **uninitialised** memory in the target (ASAN
sees only the first), then the oracle's own lossy
transformations (`lossy=1` and the soft field), and only then your mirroring. A target
bug of the first kind is a finding: have the real side mark exactly those inputs
`lossy=1` so the gate stays honest, and write it down. A seed that crashes both sides is
`CRASHES-BOTH`, also a finding: move it to `crashers/` with a `crashers.summary.tsv` row
and out of `corpus/`; the gate skips seeds in `crashers/` as `known-crasher`, so the asan
re-gate over `corpus-min` needs no exclusions. Re-run the gate after the corpus
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

Run it, and the self-test below, detached: the real-stack replay makes a 30-second
smoke take minutes (`references/smoke.md`).

It replays every seed and fuzzes each variant briefly per mode (`MODES` from `fuzz.env`),
then replays one crash per site on the real stack (`HOSTSAN`, default `REAL_ASAN`;
without it every crash is `UNVERIFIED`). Exit 1 on `HARNESS-FRAME` (the innermost
project frame is the harness's own code) or `DIRECT-ONLY` (crashes the harness, not the
real stack, on input the API can express); exit 2 when the smoke itself did not happen.
One representative per `REAL` or `PERSISTENT-ONLY` site lands in `crashers/` with a
summary row, for triage: copy nothing by hand. The other classes and low stability are
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
    LIB="$(find $W/out/asan/Release/obj.target/<target>/vendor -name '*.o' | tr '\n' ' ')" [NODE_GYP=...]
```

`PKGDIR=` is the package source directory; `fuzz.env`'s `PKG` is the oracle, and `rebuild_asan.sh` refuses one under `oracle/` or `node_modules/`. Never send the build output to `/dev/null`: `detect_selftest.sh` shows it when a rebuild fails. Then:

```sh
cd $W && . ./fuzz.env && chmod +x rebuild.sh
$R/detect_selftest.sh FAULT_SRC=<lib>/src/foo.c \
    FAULT_SED='/^Decoder::parseHeader/,/^}/s|p\[n\] = 0;|p[n + 1] = 0; /* INJECTED */|' \
    REBUILD=./rebuild.sh HARNESS=./out/asan/harness-fork CORPUS=./corpus \
    [SEED=corpus/<one that takes the faulted path>] > selftest.txt 2>&1
```

The fault must land **past an allocation boundary**, anchored to its function
(`/^Func/,/^}/`). The seed must take the **dispatch branch** the fault sits on: pass
`SEED=` rather than trusting the script's pick (a pattern that selects another engine
misses it), and export the `MODE=` that reaches it.
`references/selftest-rebuild.md` has why.

The restore relinks the asan harness, so re-run the asan gate after the self-test. When
a gyp action re-extracts the library source during configure, the library is a 3b
archive, or a zig build, `references/selftest-rebuild.md` has the `rebuild.sh` body to use instead.

**Keep `selftest.txt`** with its `PASS:` line: the campaign skill refuses to run
without it (no finds against a harness that detects nothing is not a result) and flags a
harness newer than it as stale, so re-run it after every rebuild.

Then hand over to the corpus skill, then run-a-fuzzing-campaign, then triage-fuzzing-findings.

---

## Traps that cost hours

Most are checks inside the scripts; the symptoms none catches are tabled at the end of
`references/build-traps.md`. afl-fuzz runtime symptoms belong to **run-a-fuzzing-campaign**.
