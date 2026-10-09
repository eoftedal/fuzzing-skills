# Build traps: what `build_addon.sh` guards against, and what it cannot

`resources/build_addon.sh` encodes the first section and the make-line traps. Read it
when the script fails, when you must build by hand (cmake-js, a dependency with its own
build system), or when a variant behaves wrongly. The later sections are the traps
from steps 1, 3 and 4 that no script catches.

## What `build_addon.sh` does, in order

It removes `build/`, runs `node-gyp configure` with the compiler exported, overrides
`CC.target`/`CXX.target`/`LINK.target`, and adds the AFL runtime to the target's own `LIBS`
**inside the makefile** (a command-line `LIBS=` leaks into a dependency's sub-make and
breaks its link). After the build it checks that the AFL runtime is in the `.node`, that
the **library** objects and archives carry coverage symbols, that ASAN symbols are present
when they should be, and that **node can load the result**. Only then does it copy
`build/Release` (objects included), vendored archives built outside it (`out/<v>/lib/`)
and the makefile into `out/<variant>/`. When `binding.gyp` has several targets it prints
the ones it found and skips postbuild ones; pass `TARGET=` if it guesses wrong. Each check
below is a trap that cost hours by hand.

## The oracle install (step 1)

Pin the version you mean to fuzz: `npm install $PKG_NAME@<version>`. `init_workspace.sh`
reads `PKG_VERSION` back from whatever got installed, and an unpinned install gives the
latest release, so one run fuzzed a newer version than it was asked to and only noticed
from the version it printed.

npm 11 prints `npm warn install-scripts N package(s) have install scripts not yet covered
by allowScripts: <pkg>@<version> (install: node-gyp rebuild)`. Today it still runs the
script (or the `prebuild-install` that fetches a binary), but an oracle without a built
addon is the first thing that breaks if npm stops doing so, and the failure shows up
later as every gate seed having no real-side output. So confirm the addon exists right
after the install: `ls oracle/node_modules/<pkg>/build/Release/*.node`, or the file under
`prebuilds/` the loader resolves ("Which binary does the package actually load?", below).
If it is missing, allow the package's install script (npm's `allowScripts` setting) or
run `npm rebuild <pkg>` in `oracle/`, and check again.

## Building from a clone

The only install you run in the package directory is the dependency-only one, with
scripts off so a `prebuild-install` or a `prepare` step does not run (a failing `tsc` in
`prepare` is otherwise the first thing you see). An `npm pack` tree takes the same
install, since it has no `node_modules`:

```sh
cd $W && . ./fuzz.env && cd <package dir>
git submodule update --init --recursive                  # a clone only
npm install --no-save --omit=dev --ignore-scripts        # nan / node-addon-api / bindings only
# add --force if npm answers EBADPLATFORM "Valid cpu: arm64 / Actual cpu: arm64": a
# per-platform optionalDependency (`<pkg>-linux-arm64`) trips an npm bug
```

Never a plain `npm install` there: it pulls the devDependencies and still gives no
`node-gyp` (next section).

## Which node-gyp runs

In a clone the only install is the dependency-only one (SKILL.md step 1). A plain `npm
install` pulls hundreds of devDependencies and still does not give you `node-gyp`: `npx
node-gyp` then answers `npx canceled due to missing packages and no YES option`.
`build_addon.sh` looks for it in this order, and you can pass `NODE_GYP=` explicitly: the
package's own `node_modules/.bin/node-gyp` (some packages depend on it), then the copy
**npm itself bundles**,
`NODE_GYP="node $(npm root -g)/npm/node_modules/node-gyp/bin/node-gyp.js"`, then `npx`.
Whichever one runs picks headers from the `node` on `PATH`.

## Finding the glue (step 1, question 1)

Find the glue by what it includes, not by directory: it lives in `src/`, `lib/`, or at the
package root (one `<pkg>.cc` beside `package.json`), and `lib/` often holds only
JavaScript. Headers are in the grep because a binding often includes `napi.h` from one
`.hpp` and nothing else; the glue TUs are then every `.cc` in `$SRCDIR`, not only the
hits. node-addon-api is header-only, so its objects reference plain `napi_*` symbols and
usually no mangled `Napi::` symbols.

**C glue.** A plain N-API addon written in C (`binding.c` including `node_api.h`, no
`nan.h`, no C++) is why the grep includes `*.c`: without it both evaluation runs on that
shape got an empty `GLUE`, and the next `grep -l ... $GLUE` then read stdin and hung in
an interactive shell. The block prints `N-API (C)` for it. Nothing else changes: the
harness TU stays C++ and includes the library's C header inside `extern "C"` when the
header does not do so itself. When the grep finds nothing at all, read the `sources` of
`binding.gyp`'s target instead.

## The oracle for a binding over system libraries

For a binding over system libraries (image codecs, a 2D renderer), install the oracle with
`npm install <pkg> --build-from-source`. The npm prebuilt bundles its own copies of those
libraries, which is a different back end from the one your harness links, and it will
disagree on pixels for the scoped-out decoders. npm may print `npm warn install-scripts
... not yet covered by allowScripts` and still run the script; confirm what got built with
`file` on the addon the loader resolves ("Which binary does the package actually load?",
below).

## The make line, and five ways it goes wrong

```sh
cd $W && . ./fuzz.env && cd <package dir>
# add the AFL runtime to the TARGET-SPECIFIC LIBS line gyp emits right after the LIBS block
sed -i "s#^\(.*\.node: LIBS := \$(LIBS)\)\$#\1 $($R/find_afl_rt.sh)#" build/<target>.target.mk
make -C build -j$(nproc) <target> CC.target=afl-clang-fast CXX.target=afl-clang-fast++ LINK.target=clang++
```

* **`LIBS=` on the make command line REPLACES the target's own libraries**, and a
  vendored static library (`LIBS := .../lib<dep>.a`) is lost, so the addon fails to load
  with `undefined symbol`. Case: 4 `DT_NEEDED` entries instead of 18, 113 unresolved
  symbols, while the "AFL runtime present" check passed.
* **`LIBS=` on the command line also LEAKS into sub-makes.** make exports command-line
  variables, so a dependency that runs its own `make` from a gyp action (a tarball-vendored compression
  binding's library, built by autotools during configure) receives `LIBS=...afl-compiler-rt.o`
  and dies with `ar: .../lib<dep>.a: No such file or directory` while linking its own
  `.la`. And a `LIBS +=` appended to the end of the makefile never reaches the link,
  because gyp snapshots `LIBS` into a target-specific variable right after the block
  (`$(obj).target/x.node: LIBS := $(LIBS)`). Extend that line, as above.
* **Deleting only `*.o` between variants is not a clean.** A libtool-built dependency
  keeps its `.lo` markers, make skips recompiling, and the next variant archives objects
  that no longer exist (`ar: lib<dep>_la-<member>.o: No such file or directory`).
  Remove `build/` entirely before configure.
* **`node-gyp configure` bakes the compiler into the Makefile.** The generated rule is
  `CC.target ?= $(CC)`, so a plain `make CC=afl-clang-fast` *does* take effect when
  nothing was exported at configure time. But whatever `CC`/`CXX` was exported when you
  ran `configure` is written in as the `?=` default, and then a later `make CC=gcc` is
  silently ignored. Override `CC.target`/`CXX.target`/`LINK.target` explicitly and the
  question never arises. To see what is baked:
  `grep -nE '^(CC|CXX|LINK)\.target' build/Makefile build/*.target.mk`
* **`afl-clang-fast` silently drops the AFL runtime from a `-shared` link**, so the addon
  ends up with `__afl_area_ptr` undefined and node refuses it with `ERR_DLOPEN_FAILED`.
  Hence `LINK.target=clang++` plus the runtime object by name. Under plain node the
  runtime is inert (no `__AFL_SHM_ID`, dummy map, no forkserver).
* **A dependency with its own build system never sees node-gyp's compiler.** If
  `binding.gyp` shells out to a configure script (one package untars its dependency and
  runs autotools *during* `node-gyp configure`), export the compiler into the ENVIRONMENT
  before `node-gyp configure`, and delete the dependency's build tree first or the stale
  uninstrumented archive is silently reused. Verify both:
  ```sh
  grep -c 'checking for gcc\.\.\. afl-clang-fast' build/<dep>/config.log
  nm build/<dep>/.../libfoo.a | grep -c sancov          # must be non-zero
  ```

## The compiler wrapper defines a macro the library may honour

`afl-clang-fast` and `afl-cc` inject `-DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION=1`.
Libraries use it to compile checks **out** for fuzzing convenience: a compression library skips
its dictionary-id check, a regex engine's parser relaxes limits. The instrumented library then accepts
inputs the shipped addon rejects, and the gate corpus is usually too small to notice.
Case: a 15-seed gate passed clean; the 630-seed corpus
reported `mismatched=50`, every one a frame with a non-zero dictionary id that the real
stack rejects with `Dictionary mismatch`. `-U` on the command line does not help (the
wrapper re-adds the define); `-include $R/undef_fuzzmode.h` does, and
`build_addon.sh` and `link_harness.sh` pass it for the AFL variants. Check with
`echo | afl-clang-fast -dM -E -x c - | grep FUZZING` and
`grep -rl FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION <library src>`, which tells you whether
this target cares; the flag costs nothing either way.

## Two checks after every build, and why the first alone is not enough

```sh
[ "$(nm build/Release/*.node | grep -c ' D __afl_area_ptr')" != 0 ] || echo "FAIL: no AFL runtime"
node -e "require('./build/Release/<name>.node')"        || echo "FAIL: builds but will not load"
```

Use the counting form in a script: `nm ... | grep -q x ||` inverts under
`set -o pipefail` (grep closes the pipe, nm takes SIGPIPE) and reports the symbol missing
when it is right there.

`nm -u | grep <lib>_` is **not** a substitute for the load check: a shared object
legitimately leaves its `DT_NEEDED` symbols undefined. Nor is counting `DT_NEEDED`
entries: the correct count is 4 on one target and 18 on another, and comparing against
the oracle raises a false alarm whenever the oracle is a CI prebuilt from a different
toolchain. The `node -e require()` line answers the actual question.

A cmake-js package (step 3a of SKILL.md) is built by hand, since `build_addon.sh` is
node-gyp only: pass the compilers with
`cmake-js compile --CDCMAKE_C_COMPILER=afl-clang-fast --CDCMAKE_CXX_COMPILER=afl-clang-fast++`,
link with the runtime from `$R/find_afl_rt.sh`, and apply both checks by hand.

## Variants: clear the objects, not just the products

Otherwise `make` re-archives the previous variant's objects and the only symptom is a
silently wrong variant: an ASAN build whose archive contains no ASAN symbols at all. For
a vendored gyp dependency the objects and the archive are at *different* paths (objects
under `build/Release/obj.target/<target_name>/...`, archive at
`build/Release/obj.target/<path/to/dep>/lib<dep>.a`). `build_addon.sh` does
`find build -name '*.o' -delete` before each variant and checks the result for ASAN
symbols.

node-gyp uses one `build/Release`, so build variants sequentially and treat
`out/<variant>/` as the artifacts. Overwriting the tree mid-gate silently makes the "real
stack" unloadable and every seed a mismatch.

The `pristine` variant (ASAN, no AFL instrumentation) is the control for "did my
instrumentation invent this bug?", so build it once a smoke run or campaign has saved a
crash, before triage: the triage skill's pristine confirm column is the only one that
earns "reproduces without the coverage instrumentation", and without the build it reads
`(no PRISTINE)`.

## The makefile may not be yours

Some packages ship their CI's `build/Makefile` and `build/*.target.mk` inside the
prebuild tarball, carrying another machine's include paths and another node major
(`-I/github/home/.cache/node-gyp/21.7.3/include/node`). A `prebuild-install` after your
`node-gyp configure` silently replaces it again. Check:
`grep -m1 'node-gyp' build/<target>.target.mk` must show YOUR node version and home.

## The package may not compile with clang at all

node-addon-api 3.x trips clang on `static_cast<napi_typedarray_type>(-1)` as a
non-constant expression at any `-std=`, and AFL's gcc plugin may not load into a recent
gcc, so `afl-g++-fast` is no escape. Split it: instrument only the LIBRARY with
afl-clang-fast, build the addon with the toolchain the package expects (more faithful,
not less), and compile the harness TU with `g++` (`link_harness.sh HARNESS_CXX=g++`,
which adds `afl_shim.h` for the persistent-mode macros). The AFL runtime still arrives
via the `afl-clang-fast++` link, and coverage comes from the library, which is the target
anyway. Say so.

`build_addon.sh ADDON_CXX=g++` does the split: the addon's own TUs are compiled with g++
while the vendored library keeps the variant compiler, which is where coverage comes from.
If the harness TU includes the same headers, compile it with `link_harness.sh
HARNESS_CXX=g++` too. The consequence to state: an addon object you link (a binding-free
helper, a parser in the addon) then carries **no coverage**, so an entry point whose logic
lives in the addon is measured on the library's edges only.

## A link error naming the package's own method

`undefined reference to <pkg>::Stream::method()` means a linked addon object pulls a
package method in through an inline helper in a shared header. Either link the object
that defines it, or give it a trapping stub with `NAMESPACES="Napi v8 node <pkg>"`
(`link_harness.sh` passes it to `gen_stubs.sh`): the stub is right when the harness never
reaches it, and gate check 5 proves that. The link failure prints the undefined names and
these two options.

## The library is a separate shared object (step 3b)

### First choice: an instrumented static archive

When the library's build system can produce a static archive, build one with the variant
compiler and link it into the harness like a vendored library. It needs no interposition
at load time, and the harness carries the AFL runtime as in step 3a. The recipe:

```sh
cd $W && . ./fuzz.env && cp -a <library source> $W/src-lib   # -a: make does not rerun autotools
for v in plain asan; do
  mkdir -p $W/build-$v $W/out/$v/lib && cd $W/build-$v
  [ $v = asan ] && export AFL_USE_ASAN=1 || unset AFL_USE_ASAN
  export AFL_LLVM_DICT2FILE=$W/out/$v/dict2file.raw    # the library's compared constants
  CC=afl-clang-fast CFLAGS="-g -O1 -include $R/undef_fuzzmode.h" \
      $W/src-lib/configure --disable-shared --enable-static && make -j
  cp $(find . -name 'lib<dep>.a') $W/out/$v/lib/
done            # step 4: link_harness.sh VARIANT=$v ... LIB=$W/out/$v/lib/lib<dep>.a
# no merge step: link_harness.sh rebuilds out/$v/dict.afl from dict2file.raw plus the harness's own constants
```

Clause by clause:

* **The source of the version the oracle loads** (the distribution's source package, or
  the upstream tag matching the system `.so`), so the harness runs the same library code
  the real stack does.
* **`cp -a` the source** into the workspace: plain `cp` resets timestamps, and make then
  sees `configure.ac` newer than `configure` and tries to rerun autotools, which fails
  when your automake is not the release's.
* **Out of tree** (`configure` run from `build-<variant>/`), so the plain and asan builds
  never share objects (the "clear the objects" trap above, avoided by construction).
* **`--disable-shared --enable-static`**, so the build leaves no `.so` that a later `-l`
  could pick instead. For cmake, `-DBUILD_SHARED_LIBS=OFF`; for meson,
  `--default-library=static`.
* **`-include $R/undef_fuzzmode.h`** in `CFLAGS`, because afl-clang-fast defines
  `FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION` and the library may compile checks out
  under it ("The compiler wrapper defines a macro", above).
* **`AFL_USE_ASAN=1`** in the environment for the asan variant, as `build_addon.sh`
  does for the addon: the wrapper adds the sanitizer itself. A self-test `REBUILD` of
  this archive must re-export it (`detect_selftest.sh`'s header).
* **`AFL_LLVM_DICT2FILE`** in the environment of the library's build, as an ABSOLUTE path
  (afl-cc aborts on a relative one), pointing at `$W/out/<v>/dict2file.raw`: `build_addon.sh`
  and `link_harness.sh` set it only for what they compile, so without it `out/<v>/dict.afl`
  lacks the library's own magic bytes and tokens. Build the library AFTER `build_addon.sh`,
  which starts that raw file afresh; the pass appends one line per compared constant per
  function, and `link_harness.sh` deduplicates the raw file together with the harness's
  constants into `dict.afl`. The corpus skill's `dict.sh` merges that into the campaign's
  dictionary.
* The archive goes to `out/<variant>/lib/`, where the corpus skill's instrumentation
  check looks for it, and `link_harness.sh LIB=out/<variant>/lib/lib<dep>.a` links it;
  add the library's own dependencies with `EXTRA_LIBS=` (`pkg-config --static --libs`).

Check: `nm out/<variant>/lib/lib<dep>.a | grep -c sancov` is non-zero, and for asan,
`nm ... | grep -c __asan_report` is too.

**The consequence to state.** The real side still loads the package as a user has it:
the addon over the **uninstrumented system `.so`**. Its sanitized column (`REAL_ASAN`)
swaps in the sanitized addon only, so a heap overflow inside the library is invisible
there; the gate and the confirm table can show a crash the direct harness finds as CLEAN
on that column. Say so in the write-up and in the triage report's scope
(`oracle-ceiling.md`, section 4).

### Second choice: instrument the shared object itself

When the library will only build shared. The runtime cannot live in the library.
Verified order of attempts:

| attempt | result |
|---|---|
| runtime inside the `.so` | needs `AFL_SKIP_BIN_CHECK=1`, which **also disables persistent-mode detection**: every input reported as a crash/timeout |
| compile harness with afl-clang-fast, link with plain clang | `No instrumentation detected`: `check_binary()` wants the runtime's own markers in the target file |
| **library instrumented, runtime in the harness** | `Persistent mode binary detected`, full coverage |

So instrument the library with **plain clang** `-fsanitize-coverage=trace-pc-guard`,
leaving the runtime out, and link the **harness** with `afl-clang-fast++`. The library's
own executables then fail to link on the undefined coverage symbols, which
`resources/covstub.c` (weak no-op definitions) fixes; the real runtime in the harness
interposes on them at load time. See the header of `covstub.c` for the meson invocation.
Verify by comparing map size against a build that left the symbols undefined.

A zig-built package is the same route through zig's own build graph:
`$R/wrapper_build.zig` appends the coverage flag to every source set without editing the
package (`zig-build.md`).

### A harness TU not compiled by afl-clang-fast

Whenever the harness TU is compiled by something other than afl-clang-fast (zig cc,
`HARNESS_CXX=g++`), it needs `-include $R/afl_shim.h` for the persistent-mode macros,
and `link_harness.sh` fails if the persistent magic string is missing afterwards. On the
zig route `link_harness.sh` does not run and `smoke.sh` does the check (by hand:
`strings harness | grep -c SIG_AFL_PERSISTENT` must be non-zero).

## Which binary does the package actually load?

Never assume `build/Release`:

```sh
node -e "console.log(require('bindings')({bindings:'<name>',path:true}))"   # bindings
node -e "console.log(require('node-gyp-build').path('<pkg dir>'))"          # node-gyp-build
grep -rn "require(.*\.node['\"]" <pkg dir>/*.js <pkg dir>/lib/                # a plain require
file "$(node -e "console.log(require('node-gyp-build').path('<pkg dir>'))")"
```

A package that loads its addon with a plain `require('./build/Release/<name>.node')`
loads exactly that path, and the `bindings` line above throws for it (it is not that
package's loader). `real_harness.mjs` needs nothing extra: its `process.dlopen` hook
redirects any of the three.

Three distinct things go wrong here, all seen on one target:

* **`prebuilds/` exists but not for your platform**: it falls through to a source build,
  so the directory listing told you nothing.
* **The prebuild for your platform is the wrong architecture.** One published grammar
  package ships a `linux-arm64` file that is byte-identical to its `linux-x64` one and is
  an x86-64 ELF, so `require()` fails with `ERR_DLOPEN_FAILED: cannot open shared object
  file`. `file` on the resolved path catches it; it is a bug in the package.
* **`build/Release` wins over `prebuilds/`.** Useful when you want your build loaded,
  and the reason a stale local build can silently shadow a correct prebuilt.

## No `binding.gyp` at HEAD

Some packages have moved to another build system (the image-decoding binding's next major version (a zig build) vendors its image codecs,
2D renderer and text shaper under `pkg/`). That
tree is the better target, because everything is in-tree and instrumentable, and the
zig route is written up in `zig-build.md` with `resources/wrapper_build.zig`. A package
that moved to zig did it to vendor its dependencies, so every decoder that was an
uninstrumented system `.so` under node-gyp is now in-tree. Those two files replace step 3
entirely and the rest of the skill applies unchanged; it took one run six minutes to the
first verified instrumented build. Falling back to `git show <tag>:binding.gyp` for the
last node-gyp release is the choice only when the toolchain cannot be installed: harness
that and say so. It measures a weaker surface: on an image-decoding binding the
node-gyp release's harness saw only the in-tree glue, the zig build's harness saw every
decoder.

## The node version

If you hit removed V8 API (`FunctionCallbackInfo::Holder()` is gone in node 24), or a
C++ standard conflict (a package pinning `-std=c++17` against node 24's V8 headers,
which answer `#error "C++20 or later required."`), install the node version the package
supports instead of patching the package. Patch it and "the real stack" is no longer the
published package.

Before concluding you are stuck on an old version, check **why** npm gave you one. A
committed `package-lock.json` can pin a `nan` that predates your node (`'class
v8::Isolate' has no member named 'IdleNotificationDeadline'`); `npm install
--no-package-lock` resolves the published range instead. Retry that before switching node
versions: the published range usually resolves to a current nan, which is also what the
oracle install gets. A peer range can pin it too. A grammar package declaring `peerOptional <runtime>@^<older minor>`
makes npm *refuse* the current `<runtime>` with `ERESOLVE`, so the only installable pair
needs an older node. Forcing past it with `--force` produces a combination no user has.

## Feature detection: a missing `-dev` package removes a decoder silently

`binding.gyp` probes for optional libraries and defines a macro per hit. Check the
macros, not the documentation, and grep **every** generated makefile because a vendored
dependency gets its own `build/deps/<dep>/<dep>.target.mk`:

```sh
find build -name '*.target.mk' | xargs grep -ohE 'HAVE_[A-Z0-9_]+|WITH_[A-Z0-9_]+' | sort -u
```

If all you find is a lone `HAVE_*_CONFIG_H`, the real feature set is in a vendored
config header that no makefile grep can see. Find it and read the `#define`s:

```sh
find . -name '*config*.h' -path '*<dep>*' | head
grep -nE '^#define [A-Z_]+ *[0-9]' <that header>
```

Case: one target silently built without GIF support because the GIF library's `-dev` package was absent; a
harness built from it would have fuzzed four formats while claiming five. Install the
package, re-run `node-gyp configure`, confirm the macro appears.

Related: `#error "<lib> version X+ is required"` means the build appends *your*
`PKG_CONFIG_PATH` after the system paths. Remove the system `-dev` package and verify
with the package's own helper, not your `pkg-config`.

## Symptoms no script catches (moved from SKILL.md)

afl-fuzz runtime symptoms (map size, `ASAN_OPTIONS`, `-m`, persistent mode not engaging,
`@@`, shared output directories, fuzzing node itself) belong to run-a-fuzzing-campaign.

| Symptom | Cause | Fix |
|---|---|---|
| Gate suddenly fails on every seed | a variant build overwrote `build/Release` | one variant at a time; point everything at `out/<variant>/` |
| showmap says nondeterministic, AFL says stability 100 % | showmap prints exact counts, AFL buckets them | both are right; showmap locates, stability decides |
| Self-test: `REBUILD failed with the fault applied` | `FAULT_SED` mangled the code (`\&` inside single quotes is a literal `&`) or the injected statement does not compile | the script keeps the compiler log and the patched source; read them |
| `#error "<lib> version X+ is required"` | the build appends your `PKG_CONFIG_PATH` after the system paths | remove the system `-dev` package |
