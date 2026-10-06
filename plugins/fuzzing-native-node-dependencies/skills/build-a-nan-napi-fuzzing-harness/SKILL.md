---
name: build-a-nan-napi-fuzzing-harness
description: Build a direct AFL++ fuzzing harness for the native library behind a Node NAN, node-addon-api or N-API addon, bypassing node while executing the same machine code. Use when asked to fuzz a native Node dependency (an image, XML, compression, regex, stylesheet or parser binding), to harness a native library behind a binding, or when an interpreter-hosted fuzzer is too slow.
---

# Build a direct fuzzing harness for a NAN/N-API dependency

Goal: delete node from the loop while still executing **the same machine code** the
addon executes. A fast harness that tests something subtly different is worse than no
harness, so every step below ends in a check that it is still faithful.

`resources/` holds the scripts; every step names the one it uses. `references/` holds
the long versions of the rules with the cases that produced them. Read a reference only
when the step points you at it or a check fails. `EVIDENCE.md` says which target taught
each rule. This file is about 40 KB: read it with a file reader, not `cat` into a
terminal that truncates at 30 KB (two runs lost its last steps that way).

**Layout convention** (the scripts assume it): a fuzz workspace holding an independent
`oracle/` install for the real stack, `out/<variant>/` for each build (`plain`, `asan`,
and `pristine` when you need it) with the snapshotted `Release/` tree, vendored archives
under `lib/`, the makefile, `harness`, `harness-fork` and `map_size`, and the corpus in
`corpus/`. The package itself is a clone or `node_modules/<pkg>` elsewhere; always pass
`build_addon.sh` an **absolute** `OUT=` into the workspace, or it writes `out/` into
the package.

**The whole path, for the common case** (library compiled into a node-gyp addon):

```sh
R=/abs/path/to/this/skill/resources; W=/abs/fuzz          # W: the fuzz workspace
# 1  snapshot the prebuilt and make an independent oracle install (W/oracle)
# 2  cd <package dir>        # build_addon.sh runs FROM THE PACKAGE DIRECTORY
#    $R/build_addon.sh VARIANT=plain OUT=$W/out; then, back in $W:
#    $R/find_boundary.sh $(find out/plain/Release/obj.target -name '*.o')   -> the function to call
# 3  (cd <package dir> && $R/build_addon.sh VARIANT=asan OUT=$W/out)        -> out/asan/
# 4  harness.cc from $R/harness_template.cc, then for v in plain asan:
#    $R/link_harness.sh VARIANT=$v MK=out/$v/<target>.target.mk SRCDIR=<package dir> \
#        LIB="$(find out/$v/Release/obj.target/<dep> -name '*.o')" [ADDON_OBJS=...]
# 5  real_harness.mjs from $R/real_harness_template.mjs, then $R/gate.sh (plain, then asan),
#    MODES="MODE=..." listing every entry point the harness has besides the default
# 6  $R/smoke.sh MODES="..." HOSTSAN="env LD_PRELOAD=$($R/find_asan_rt.sh) PKG=$W/oracle/node_modules/<pkg> \
#        ADDON=$W/out/asan/Release/<name>.node node real_harness.mjs"
#    then, once smoke passes (its fixes rebuild the harness, which would stale a self-test):
#    $R/detect_selftest.sh ... | tee selftest.txt
#    then: corpus skill -> run-a-fuzzing-campaign -> triage-fuzzing-findings
```

The order is **gate -> smoke -> self-test**. Smoke failures force harness fixes, and the
self-test vouches only for the binary it ran against, so running it before the smoke
means running it twice. After any harness change, re-run the gate too.

---

## Step 1 — Triage, before building anything

Every build step overwrites `build/Release`, so first:

```sh
[ -d node_modules/<pkg>/build/Release ] && cp -a node_modules/<pkg>/build/Release out/prebuilt
mkdir -p oracle && (cd oracle && npm init -y >/dev/null && npm install <pkg>)   # the REAL stack
```

**From a git clone:** the only install you run in the package directory is the
dependency-only one, with scripts off so a `prebuild-install` or a `prepare` step does
not run (a failing `tsc` in `prepare` is otherwise the first thing you see):

```sh
git submodule update --init --recursive
npm install --no-save --omit=dev --ignore-scripts        # nan / node-addon-api / bindings only
# add --force if npm answers EBADPLATFORM "Valid cpu: arm64 / Actual cpu: arm64": a
# per-platform optionalDependency (`<pkg>-linux-arm64`) trips an npm bug
```

Never a plain `npm install` there: it pulls hundreds of devDependencies and still does
not give you `node-gyp` (`npx node-gyp` then answers `npx canceled due to missing
packages and no YES option`). `build_addon.sh` looks for it in this order, and you can
pass `NODE_GYP=` explicitly: the package's own `node_modules/.bin/node-gyp` (some
packages depend on it), then the copy **npm itself bundles**,
`NODE_GYP="node $(npm root -g)/npm/node_modules/node-gyp/bin/node-gyp.js"`, then `npx`.
Whichever one runs picks headers from the `node` on `PATH`.

**Is a direct harness the right tool here?** Decide it now, not at the end. If every
call costs milliseconds *at the smallest input the API accepts* (a renderer, a
compressor at its default level), or everything interesting is inside an uninstrumented
system library, a direct harness buys less than it costs to keep faithful: say so and
stop. Two things that look like that and are not: an input-chosen cost (slow only when
the attacker says so: bound it, step 4), and a slow entry point beside a cheap parser
of the same bytes (harness the parser as a mode). The speed-up over the interpreter is
otherwise a given, not a result: do not measure or report it.

Two things that go wrong at this point:

* **No `binding.gyp` at HEAD.** Some packages have moved to a zig, cargo or meson
  build (an image-decoding binding's next major version is a zig build). Prefer to
  harness that: a package that moved to zig did it to vendor its dependencies, so every
  decoder that was an uninstrumented system `.so` under node-gyp is now in-tree. For zig, `references/zig-build.md` and
  `resources/wrapper_build.zig` replace step 3 entirely and the rest of the skill
  applies unchanged; it took one run six minutes to the first verified instrumented
  build. Only if the toolchain is unobtainable, `git show <tag>:binding.gyp` finds the
  last node-gyp release; harness that and say so.
* **The committed lockfile pins an old `nan`** that does not compile on your node
  (`'class v8::Isolate' has no member named 'IdleNotificationDeadline'`). Retry with
  `--no-package-lock` before switching node versions: the published range usually
  resolves to a current nan, which is also what the oracle install gets.

Then look in `build/Release` again, because an `install` script of `prebuild-install ||
node-gyp rebuild` may already have fetched a CI binary. Snapshot whatever appeared.
`md5sum` the snapshot against the oracle's addon: if they are the same file, that is one
piece of evidence, not two.

**Oracle for a binding over system libraries** (image codecs, a 2D renderer): install it
with `npm install <pkg> --build-from-source`. The npm prebuilt bundles its own copies of
those libraries, which is a different back end from the one your harness links, and it
will disagree on pixels for the scoped-out decoders. npm may print
`npm warn install-scripts ... not yet covered by allowScripts` and still run the script;
confirm what got built with `file` on the addon the loader resolves (question 4).

Then answer five questions. Each is one command.

1. **Which ABI, and is the glue hand-written or generated?** Find the glue by what it
   includes, not by directory: it lives in `src/`, `lib/`, or at the package root
   (one `<pkg>.cc` beside `package.json`), and `lib/` often holds only JavaScript.
   ```sh
   GLUE=$(grep -rl --include='*.cc' --include='*.cpp' --include='*.cxx' --include='*.h' --include='*.hpp' \
          --exclude-dir=node_modules --exclude-dir=deps --exclude-dir=vendor --exclude-dir=build \
          -e 'nan.h' -e 'napi.h' -e 'node_api.h' .)
   SRCDIR=$(dirname $(echo "$GLUE" | head -1)); echo "$GLUE"
   grep -l 'nan\.h' $GLUE >/dev/null && echo NAN; grep -l 'napi\.h' $GLUE >/dev/null && echo node-addon-api
   grep -lim1 "swig\|automatically generated\|pybind11\|DO NOT EDIT\|napi-rs" $GLUE
   ```
   Headers are in the grep because a binding often includes `napi.h` from one `.hpp` and
   nothing else; the glue TUs are then every `.cc` in `$SRCDIR`, not only the hits.
   node-addon-api is header-only, so its objects reference plain `napi_*` symbols and
   usually no mangled `Napi::` symbols. Generated glue (SWIG, pybind11, napi-rs) has no
   binding-free function and nothing to link: the risk there is the state the init block
   installs (step 4, layer 3). Hand-written glue *may* have one; step 2 settles it.
2. **Is the library compiled into the addon, or a separate shared object?**
   ```sh
   ldd build/Release/*.node | grep -vE "libc|libstdc|libgcc|libm|linux-vdso|ld-linux"
   ```
   Empty: compiled in, link its objects (step 3a). One project-built `.so`: step 3b. Many
   system libraries with some parsing in-tree: instrument the addon, accept the system
   libraries as uninstrumented, and **state that scope** (step 5 reads differently then).
3. **Which optional features did the build detect?** A missing `-dev` package does not
   fail the build; it turns a decoder into dead code.
   ```sh
   find build -name '*.target.mk' | xargs grep -ohE 'HAVE_[A-Z0-9_]+|WITH_[A-Z0-9_]+' | sort -u
   ```
   A lone `HAVE_*_CONFIG_H` means the feature list is in a vendored config header; read
   its `#define`s. Details in `references/build-traps.md`.
4. **Which binary does the package actually load?** Ask the loader, not the directory
   (`require('bindings')({bindings:'<name>',path:true})`,
   `require('node-gyp-build').path('<pkg dir>')`), and run `file` on the result: a
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
the boundary, and it tells you the work runs on a libuv thread with its own stack size,
which matters for triage.

```sh
grep -rn 'AsyncWorker\|::Execute()\|napi_create_async_work\|uv_queue_work' $SRCDIR/
resources/find_boundary.sh $(find out/plain/Release/obj.target -name '*.o')   # rank EVERY object
nm -uC <candidate.o> | grep -E 'Napi::|napi_|v8::|node::'          # which functions own the refs?
```

The ranking needs objects. If the install fetched a prebuilt there are none, so run
`build_addon.sh VARIANT=plain` (step 3) first and come back; the two steps are not
strictly ordered. A library a gyp action builds with its own build system is not under
`obj.target` at all: it is the archive `build_addon.sh` copied to `out/plain/lib/`, so
rank its members too (`mkdir t && cd t && ar x ../out/plain/lib/lib<dep>.a && find_boundary.sh *.o`),
or the ranking shows only addon objects.

The library's own objects showing 0 and the addon's showing 20-60 is the whole picture
in one view. The lowest count is where to start reading, not the answer: the criterion
is *a function on your input path whose own body is binding-free*.

Prefer a function that already does the dispatch and the option plumbing, so the
package's format sniffing and limit checks are *its* code, not your copy. If the package
exposes several entry points over the same engine (buffer vs file, parse vs parse-html),
harness them behind an **environment variable**, never an input byte: a corpus
file stays byte-for-byte what the real API consumes, so any seed or crash replays
unchanged on the real stack. **Budget the modes, and decide them now**, before the first
gate: a mode added after the gate rebuilds the harness, and gate, smoke and self-test all
run again (one run spent 5 of its 10 harness minutes on exactly that). Keep a mode only if
it reaches library code the default does not (a different decoder, the compressor behind
a decompressor, a different parser state machine), and stop at two or three. Six modes
gated and smoked on two variants cost one run an hour, and entry points that are thin
wrappers over the same call (exec vs test vs match) are one mode with different
post-processing: fuzz the richest one and say so. Each extra mode multiplies every later
step (gate, smoke, measure, re-gate, crasher pass). A mode that cannot reject its input
(a compressor) gets `:min_arms=1` in the gate's `MODES=` spec, so check 3 stays strict
for the default mode.

For a generated binding, skip the ranking: `grep -n '<libraryEntryPoint>(' $SRCDIR/<generated>.cc`.

**Three shapes where there is no single binding-free function, and what the boundary
is then.** All three occurred on the first five targets this skill was tried on, so
expect one of them more often than not.

* **The work is a method of an `ObjectWrap` / `Nan::ObjectWrap` subclass** (`Decoder::decodeBuffer`,
  `Stream::pump`). The object cannot be constructed without the runtime.
  Do not try: **copy the method body into the harness** minus its runtime calls, with a
  comment naming the file and lines, and copy any `static inline` helpers from the same
  TU verbatim. Link no addon object unless a binding-free helper (a translator, a
  parser) lives in one. Note the drift risk in the write-up: the copy must be re-checked
  when the package updates. Private fields you still need are reached with the trick in
  `references/four-layers.md`.
* **Every addon function is an emitter into the runtime** (a SAX binding whose handlers
  all call `Emit`). The boundary is the library's public API plus the addon's
  constructor and handler registration, mirrored. Link no addon object.
* **The dispatch is in JavaScript** and the addon's C++ methods are one-line wrappers
  (a streaming compression binding with a shared decoder context walks frames in JS, sums
  declared sizes and picks a fast or a streaming path in `lib/`). `find_boundary.sh`
  shows every library object at 0 and every addon object at 20+, and cannot tell you the logic is in `lib/*.js`. The
  boundary is the library's C API driven exactly the way the JS drives it: mirror that
  state machine in the same order, including how it re-chunks the input.

---

## Step 3 — Build the variants

Two variants now, one at a time, each snapshotted into `out/<variant>/`: `plain`
(throughput) and `asan` (bug finding). A third, `pristine` (ASAN, no AFL
instrumentation), is the control for "did my instrumentation invent this bug?": build
it when you have a crash to cross-check, not before. On five evaluation targets it was
built every time and used on none.

Every variant built with afl-clang-fast gets `-include undef_fuzzmode.h`, because the
compiler wrapper defines `FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION` and libraries
compile checks **out** under it (a compression library's dictionary-id check, a regex
engine's parser limits). An
instrumented library then accepts what the shipped addon rejects, and the gate corpus
is usually too small to notice. `grep -rl FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION
<library src>` tells you whether this target cares; the flag costs nothing either way.

### 3a. Library compiled into the addon (the common case)

```sh
cd <package dir>
for v in plain asan; do
  resources/build_addon.sh VARIANT=$v OUT=/abs/fuzz/out [TARGET=<gyp target_name>] [NODE_GYP=...]
done
```

The script removes `build/`, runs `node-gyp configure` with the compiler exported,
overrides `CC.target`/`CXX.target`/`LINK.target`, adds the AFL runtime to the target's
own `LIBS` **inside the makefile** (a command-line `LIBS=` leaks into a dependency's
sub-make and breaks its link), then checks that the AFL runtime is in the `.node`, that
the **library** objects and archives carry coverage symbols, that ASAN symbols are
present when they should be, and that **node can load the result**, before copying
`build/Release` (objects included), vendored archives built outside it (`out/<v>/lib/`)
and the makefile into `out/<variant>/`. It prints the targets it found when
`binding.gyp` has several and skips postbuild ones; pass `TARGET=` if it guesses wrong.
Each check is a trap that cost hours by hand; `references/build-traps.md` has them if
the script fails or you must build manually.

**cmake-js packages:** `build_addon.sh` is node-gyp only. Pass the compilers with
`cmake-js compile --CDCMAKE_C_COMPILER=afl-clang-fast --CDCMAKE_CXX_COMPILER=afl-clang-fast++`
and link with the runtime from `resources/find_afl_rt.sh`; apply the same two checks.

**The addon will not compile under clang** (node-addon-api 3.x:
`napi.h: in-class initializer for static data member is not a constant expression`):
pass `ADDON_CXX=g++` to `build_addon.sh`. The addon's own TUs are then compiled with
g++ while the vendored library keeps the variant compiler, which is where coverage
comes from. If the harness TU includes the same headers, compile it with
`link_harness.sh HARNESS_CXX=g++` too. The consequence to state: an addon object you
link (a binding-free helper, a parser in the addon) then carries **no coverage**, so an
entry point whose logic lives in the addon is measured on the library's edges only.

### 3b. Library is a separate shared object, or the whole package is built by zig

The runtime cannot live in the library. Instrument the library with plain clang
`-fsanitize-coverage=trace-pc-guard` and link `resources/covstub.c` into its targets so
its own executables still link; the AFL runtime lives in the harness. The meson
invocation is in the header of `covstub.c`; the attempts that do not work are in
`references/build-traps.md`. A zig-built package is the same route through zig's own
build graph: `resources/wrapper_build.zig` appends the coverage flag to every source
set without editing the package, and `references/zig-build.md` is the recipe.

Whenever the harness TU is compiled by something other than afl-clang-fast (zig cc,
`HARNESS_CXX=g++`), it needs `-include resources/afl_shim.h` for the persistent-mode
macros, and `strings harness | grep -c SIG_AFL_PERSISTENT` must be non-zero afterwards.

---

## Step 4 — Write the harness

Start from `resources/harness_template.cc`. It already copies the input into an exactly
sized `malloc`, reads modes (and an opt-in allocation ceiling) from the environment, prints the
one-line `in_len= status= err= out_len= out_hash= lossy= invariant=` contract, frees its
init state in the single-shot path (or the ASAN variant dies in LeakSanitizer before
printing), and builds both drivers from one TU. The template is written for a
synchronous one-shot call; for a **streaming** API fed in chunks, concatenate every
output chunk and hash that, and for a **callback-driven** (SAX) library serialise every
event with every argument the real handlers read and hash the stream. Both templates
carry a sketch of each. What you add is the mirroring of **four layers**, which live in
different files. The checklist; the long form with cases is `references/four-layers.md`.

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
   grep -rn "NAN_MODULE_INIT\|NAPI_MODULE_INIT\|napi_register_module_v1\|%init" $SRCDIR/
   grep -rniE "MemSetup|SetAllocator|RegisterNode|_default\(|SetErrorFunc" $SRCDIR/
   ```
4. **What the exported function does after the boundary returns.** Read the whole
   function: post-processing that fills in API-visible fields is common and is never
   offered as a boundary candidate.

Three more things to check, each a one-line grep in the reference:

* **How the bytes are delivered.** A callback-taking entry point, a code-unit offset, a
  fixed staging buffer: grep the addon for `encoding`, a `read` member in a callback
  struct, and `/ 2` or `* 2` on offsets. Choose the corpus encoding so file bytes map to
  the API value losslessly. **Several byte arguments** (a salt and a password, a pattern
  and a subject) go in one file, framed with a separator the API's values cannot carry
  (NUL for a JS-string argument; a length prefix for a Buffer one), split identically on
  both arms and documented at the top of `harness.cc`; the corpus skill's seeds then use
  the same framing, and the gate still compares what the real API consumed after the
  split.
* **NUL termination.** `node::Buffer::Data()` is raw and unterminated; a JS string via
  `Nan::Utf8String` / `napi_get_value_string_utf8` is NUL-terminated and transcoded, and
  so cannot carry invalid UTF-8 or anything past a NUL. Note which you have.
* **Make the library actually do the work.** An open is not a decode. Force evaluation
  and record something only real work could produce. Reset only what is safe to reset.

**The `err` field is one token, identical on both sides**: the library's numeric code
when the package exposes one, otherwise its error name or message with spaces replaced
by `_`. Never a hash of a message that embeds the input, which makes `err` unique per
seed and useless for the corpus skill's histograms, which steer by that field.

**Attacker-declared allocations** (a decompressor's declared content size, an image
header's dimensions) get **no cap by default**. Mirror what node does instead, with
node's own tokens: `ERR_OUT_OF_RANGE` above `buffer.kMaxLength` (ask the runtime, do not
quote it: `-DNODE_KMAXLENGTH=$(node -p ...)`), `ERR_MEMORY_ALLOCATION_FAILED` when the
allocator refuses a legal length (`Buffer.allocUnsafe` under the sanitizer's
`max_allocation_size_mb`; only the asan gate exercises this path), and the package's own
error path, and let the fuzzer's memory limit bound the run
(`afl-fuzz -m`, or `max_allocation_size_mb` under ASAN, both from `ALLOC_CAP_MB` in
the campaign). An invented cap was measured to reject inputs the real package accepts.
Both templates carry an **opt-in** `ALLOC_CEIL=<bytes>`, off unless set, applied only
at the attacker-declared site and reported as `err=alloc-ceiling`; set it identically on
both arms, never wrap `malloc` or `Buffer.alloc*` globally. `references/four-layers.md`
(layer 2) has the case.

**Attacker-chosen work** is the same problem in time: an input field that sets an
iteration count, a cost or rounds exponent, a dimension of a loop (a password hash's
cost field is `2^n` rounds, so one byte decides milliseconds or hours). The rule is the
same: mirror the package's own bound if it has one (read the JS validation and the
native parser), and otherwise add an **opt-in** `WORK_CEIL=<units>` applied identically
on both arms at that field and reported as `err=work-ceiling`, so the gate can compare
the parse of a huge cost without paying for it. Set it for the campaign (the smoke's
hangs are otherwise all that field), and keep high-cost seeds out of `corpus-final/` as
hangs. It is also a finding to record for triage when the package does **not** bound it:
an input-controlled work factor is a denial of service by itself, like declared-size
memory amplification; quote the field and the time at its minimum and maximum.

Then link:

```sh
resources/link_harness.sh VARIANT=plain MK=out/plain/<target>.target.mk SRCDIR=$PWD \
    LIB="$(find out/plain/Release/obj.target/<dep> -name '*.o')" \
    [ADDON_OBJS="out/plain/Release/obj.target/<target>/src/<file>.o"]
```

`<dep>` is the library's own path under `obj.target`: a separate gyp target
(`obj.target/<dep>/`), or, when the library is compiled into the addon's own target, its
vendored subtree (`obj.target/<target>/vendor/<dep>/`). Never the whole
`obj.target/<target>/`, which also holds the addon's own objects (its `src/` or `lib/`),
and those carry binding references.

It lifts the addon's own `-D`/`-I`/C++ flags from the makefile (`-fno-rtti` and feature
macros must match the object you link), generates trapping stubs for every binding
symbol the addon objects reference (`gen_stubs.sh`), proves one stub aborts with the
`AFL-HARNESS-STUB` marker, links `harness` and `harness-fork`, and records the map size.
Repeat per variant.

**If you link no addon object** there are no stubs and gate check 5 is not applicable:
record it that way. The same holds when the only addon object you link has **zero**
binding references (a translator, a parser helper): `link_harness.sh` prints `none: ...
nothing to trap`, the gate's check 5 passes vacuously, record it as N/A. Your entire
fidelity claim is then the step-5 comparison, so it has to compare the deepest artifact
the API exposes, not a status code.

**A link error naming the package's own method** (`undefined reference to
<pkg>::Stream::method()`) means a linked addon object pulls a package method in through
an inline helper in a shared header. Either link the object that defines it, or give it a
trapping stub with `NAMESPACES="Napi v8 node <pkg>"` (`link_harness.sh` passes it to
`gen_stubs.sh`): the stub is right when the harness never reaches it, and check 5 proves
that. The link failure prints the undefined names and these two options.

---

## Step 5 — Gate it

Write the real-stack side from `resources/real_harness_template.mjs`. It loads the
`oracle/` install, swaps in a sanitized addon with `ADDON=` when asked (through a
`process.dlopen` hook, so it works however the package computes its binary's path, and
it refuses to print a result with `ADDON-NOT-SWAPPED` if no load was redirected),
re-homes the input into an unpooled buffer, and prints the same line. Its consumer calls
live in an `ENTRIES` object **keyed by the harness's `MODE` value** (`default` when unset):
one arm per entry point, no options, no error listener a user would not add. Name each
mode after the entry point it reaches (`MODE=file` → the `file` arm). That object is the
chain's contract: the campaign skill records each mode's `entry` as this key, and the
triage skill's `confirm.mjs` uses the same object unchanged, so the calls are written once,
here, where the gate proves they reach the native code. Then:

```sh
resources/gate.sh DIRECT=./out/plain/harness-fork REAL="env PKG=$W/oracle/node_modules/<pkg> node real_harness.mjs" \
    CORPUS=./corpus FIELDS="status err out_len out_hash" SOFT_FIELD=lossy SOFT_DROP="out_len out_hash" \
    MAP_SIZE=$(cat out/plain/map_size) MODES="MODE=file" JOBS=6
```

`MODES=` lists every entry point the harness has besides the default, in `campaign.sh`'s
spelling; the whole gate runs once per setting, exported to both sides, and fails if any
mode fails. `SOFT_DROP` must name **every field the oracle's loss can change**: a U+FFFD
substitution changes `out_len` as well as `out_hash`, so `out_hash` alone reports a
MISMATCH that is really the ceiling. `JOBS` runs seeds in parallel; node startup
dominates, so the re-gate of a thousand-seed final corpus takes a minute, not five.

The gate's five checks, and what each one is for:

1. **Every seed reaches the library.** Exit 0 licenses nothing.
2. **Byte-exact agreement on the deepest artifact the API gives you**: the serialized
   document, every pixel, or for a callback-driven library the hashed event stream. This
   is what proves the *option* mirroring, not just the parse.
3. **Both arms populated.** The corpus must contain inputs the library rejects; truncate
   and bit-flip a few seeds. `MIN_ARMS=1` only for a target that cannot reject. Both
   status arms are the minimum: the gate corpus also needs **one seed per branch of the
   mirrored dispatch** (an unsized frame for a streaming fallback, a declared size over
   the ceiling, each entry point behind `MODE=`), or the gate proves nothing about the
   branches the corpus skill will later exercise.
4. **Coverage discriminates.** If a trivial input scores nearly as many tuples as a real
   one you are measuring init. **Unless** the decoders are in an uninstrumented system
   `.so` (`nm -D <lib.so> | grep -c sancov` is 0): then rejects out-score successes and
   the rule inverts. Check that before interpreting the numbers.
5. **The stubs stayed unreachable.** The gate reads the marker from stderr per seed.

**On a mismatch, read `references/oracle-ceiling.md` before touching the harness.** The
order there: a read of out-of-bounds or **uninitialised** memory in the target (run the
seed through the ASAN variant for the first; ASAN cannot see the second, which wants a
one-off MSan build of the library objects and the harness), then the oracle's own lossy
transformations (`lossy=1` and the soft field), and only then your mirroring. A target
bug of the first kind is a finding: have the real side mark exactly those inputs
`lossy=1` so the gate stays honest, and write it down. Re-run the gate after the corpus skill has produced
a real corpus; a gate corpus is too small to find the oracle's ceiling.

Gate the `asan` variant too, with the sanitized addon swapped in and the sanitizer
runtime preloaded **inside `REAL=`**, never in front of `gate.sh`:

```sh
resources/gate.sh DIRECT=./out/asan/harness-fork CORPUS=./corpus FIELDS=... MODES=... \
    REAL="env LD_PRELOAD=$(resources/find_asan_rt.sh) PKG=$W/oracle/node_modules/<pkg> \
         ADDON=/abs/fuzz/out/asan/Release/<name>.node node real_harness.mjs"
```

In front of `gate.sh` the runtime is preloaded into afl-showmap and the direct harness as
well: every seed is `NO-OUTPUT ... rc=86` with an empty message and check 4 says
`afl-showmap produced nothing`; the gate now names that cause. Its default
`ASAN_OPTIONS` carry the campaign's allocation ceiling (`allocator_may_return_null=1`,
`max_allocation_size_mb=$ALLOC_CAP_MB`), so a seed declaring a huge allocation is
refused the same way on both sides instead of aborting with
`allocation-size-too-big` and no result line on one. The gate prints the first error
line of whichever side produced no output, so a wrong `ADDON=` path or a sanitizer
abort on one side is named rather than counted; if **every** seed has no output, the
command is broken, not the seeds.

---

## Step 6 — Smoke it, then prove it detects

Smoke first, self-test second. A smoke failure means fixing and rebuilding the harness,
and the self-test vouches only for the binary it ran against (the campaign skill flags a
harness newer than `selftest.txt` as stale), so a self-test run before the smoke would
have to be repeated. `smoke.sh` passes `SELFTEST=skip` to `campaign.sh` for its own short
run, because it judges the harness, not the detection.

### Smoke it: does the harness crash on its own account?

The gate compares the harness with the real stack on the gate corpus, which is mostly valid
input, so it never reaches the error paths where a harness is most likely wrong. On an image-decoding
binding, the harness `memset` a C++ object to zero; every decode **error** crashed inside `std::string` —
43 phantom SIGSEGVs in 15 seconds of fuzzing — while valid inputs worked perfectly, which is
why it survived the gate. A short run finds that in seconds; finding it after a campaign, in
a pile of crashes, costs the whole campaign.

```sh
resources/smoke.sh SMOKE_S=30 MODES="MODE=file" \
    HOSTSAN="env LD_PRELOAD=$(resources/find_asan_rt.sh) PKG=<oracle>/node_modules/<pkg> ADDON=/abs/fuzz/out/asan/Release/<name>.node node real_harness.mjs"
```

It runs every seed through every sanitized fork harness, fuzzes each variant briefly (it
drives `campaign.sh` into `smoke/`, so the afl-fuzz setup is the campaign skill's, not
repeated here), and classifies each crash it saves. `MODES=` is the same list you gave
the gate: one short campaign per variant per mode, each recorded with its `mode_env` in
the manifest, and every seed and crash replayed under that mode on both sides.

It runs `HOSTSAN` once on a seed first and stops (exit 2) if it prints no result line:
a broken real-side command would otherwise make every crash `DIRECT-ONLY`. With
`HOSTSAN`, every crash is tried on the **real stack first**, because the harness carries
copies of package method bodies and `static inline` helpers (step 2) and a frame in
`harness.cc` can be a real bug in that copied code:

The classes (`REAL`, `HARNESS-FRAME`, `DIRECT-ONLY`, `OUT-OF-SCOPE`, `UNVERIFIED`, `STATE`,
`PERSISTENT-ONLY`) and what to do about each are in `smoke.sh`'s header. Two fail the run:
`HARNESS-FRAME` (the innermost project frame is in the harness's own code) and
`DIRECT-ONLY` (crashes the harness, not the real stack, on input the API can express).

It exits 1 on `HARNESS-FRAME` or `DIRECT-ONLY`, and 2 when the smoke test itself did not
happen: no campaign `completed` or `walled`, any campaign `aborted` or `failed`, a variant
with no finished run, or a broken `HOSTSAN`. It also warns on execs/s below 100 (measured
over the time afl-fuzz actually ran; a harness that initialises on every call) and on
stability below 90 %. **A `PASS` means the harness is not obviously wrong; it does not
mean it is right** — the gate and the self-test do that.

Without `HOSTSAN` a crash can only be called `UNVERIFIED`, so give it. The comparison is the
reason: "crashes only in your harness, so your harness is wrong" is **false** under a
sanitizer, because a 1-byte over-read is invisible to a non-sanitized host, so the real side
must run the same sanitizer. A variant built without the sanitizer has no stack of its own;
its crashes are re-run on a sanitized variant to get one.

Low stability has two known causes: a harness that mirrors a **context shared across calls**
(a streaming compression binding's one decoder context, reset per call) carries state
between iterations by design and wants the fork driver, and a library that seeds its hash
tables from the **clock or pid** (an XML parser's `gettimeofday ^ getpid` hash salt) jitters
a few edges per run, which is the noise floor the corpus skill measures. The campaign skill switches drivers on stability by itself.

### Then prove it detects

```sh
resources/detect_selftest.sh FAULT_SRC=<lib>/src/foo.c \
    FAULT_SED='/^Decoder::parseHeader/,/^}/s|p\[n\] = 0;|p[n + 1] = 0; /* INJECTED */|' \
    REBUILD="resources/rebuild_asan.sh PKG=<package dir> OUT=/abs/fuzz/out MK=... SRCDIR=... HARNESS=... LIB=..." \
    HARNESS=./out/asan/harness-fork CORPUS=./corpus [SEED=corpus/<one that takes the faulted path>] \
    | tee selftest.txt
```

Without this, "no crashes found" is indistinguishable from "detects nothing". The fault
must land **past an allocation boundary** (a 1-byte over-*read* into a larger buffer
fires nothing), and the seed must **reach** it: the script picks the largest non-empty
seed that reports `status=0` with `out_len>0`, which is often the wrong one (a
compressed-block seed for a raw-block fault), so pass `SEED=`. Anchor `FAULT_SED` to the function (`/^Func/,/^}/`), because the same line
exists in other functions and the script prints where the fault landed for exactly that
reason. Reaching the function is not enough either: the seed must take the **dispatch
branch** the fault sits on (an unsized frame goes down a streaming path whose oversized
buffer hides a 1-byte over-write; UTF-8 input never touches a transcoding buffer), so
read the branch around the faulted line before picking `SEED=`.

`REBUILD` is run with `eval`, twice (fault applied, then restore). Expand any list
**before** building the string and single-quote the result; a `$(find ...)` left inside
single quotes reaches `eval` as a literal and the relink fails with an empty log:

```sh
L=$(find out/asan/Release/obj.target/<target>/vendor -name '*.o' | tr '\n' ' ')
REBUILD="resources/rebuild_asan.sh PKG=$PWD OUT=$W/out MK=$W/out/asan/<target>.target.mk SRCDIR=$PWD HARNESS=$W/harness.cc LIB='$L' NODE_GYP='$NODE_GYP'"
```
`rebuild_asan.sh` takes the arguments you gave `build_addon.sh` and `link_harness.sh`;
it cannot be used when a gyp action re-extracts the library source during configure
(a tarball-vendored compression binding), where REBUILD has to be an out-of-tree build
of the library plus a relink: configure the library once outside the package with the
line `build/<dep>/config.log` records (prefix it with `CC=afl-clang-fast
AFL_USE_ASAN=1`), then `REBUILD="make -C <that tree> && resources/link_harness.sh
VARIANT=asan ... LIB=<that tree>/.libs/lib<dep>.a"`. Note that this relinks the asan
harness against a different archive than the one the gate and smoke vouched for, so
re-run the asan gate on that harness afterwards. The same holds for every REBUILD: the
restore step relinks the asan harness, which counts as a harness change, so the asan
gate runs once more after the self-test (ten seconds; the map size may move by a few
entries, which is expected). For a zig build it is the two asan
`zig build` invocations plus a copy of the drivers. The script removes its
`<src>.injected` copy before the restore rebuild, so a REBUILD that greps the tree for
`INJECTED` sees a clean tree then.

**Keep the self-test's output** (`resources/detect_selftest.sh ... | tee selftest.txt`, with
its `PASS:` line): the campaign skill refuses to run without it, because a campaign that finds
nothing against a harness that detects nothing is not a result. Re-run it whenever the
harness is rebuilt afterwards.

Then hand over: the **corpus skill** builds the seeds, **run-a-fuzzing-campaign** runs the
real campaigns and records how, and **triage-fuzzing-findings** classifies what they find
(its confirm step is the same real-stack comparison, per entry point).

---

## Traps that cost hours

Most build traps are now checks inside `build_addon.sh`, `link_harness.sh` and the
templates, and are explained where they apply (`references/build-traps.md` has the long
form if a script fails). afl-fuzz runtime symptoms (map size, `ASAN_OPTIONS`, `-m`,
persistent mode not engaging, `@@`, shared output directories, fuzzing node itself)
belong to **run-a-fuzzing-campaign**, whose `campaign.sh` handles them; look there. What is
left:

| Symptom | Cause | Fix |
|---|---|---|
| Gate suddenly fails on every seed | a variant build overwrote `build/Release` | one variant at a time; point everything at `out/<variant>/` |
| showmap says nondeterministic, AFL says stability 100 % | showmap prints exact counts, AFL buckets them | both are right; showmap locates, stability decides |
| Self-test: `REBUILD failed with the fault applied` | `FAULT_SED` mangled the code (`\&` inside single quotes is a literal `&`) or the injected statement does not compile | the script keeps the compiler log and the patched source; read them |
| `#error "<lib> version X+ is required"` | the build appends your `PKG_CONFIG_PATH` after the system paths | remove the system `-dev` package |

