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
`build/Release` (objects included), vendored archives built outside it (`out/<v>/lib/`,
which a re-run keeps, so a `build_lib.sh` archive survives) and the makefile into
`out/<variant>/`. When `binding.gyp` has several targets it prints
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

**When the package loads a prebuilt instead of building** (an `install` script of
`prebuild-install || node-gyp rebuild`, or `node-gyp-build` finding a file under
`prebuilds/`), the oracle's addon is a CI binary, not your compile: snapshot it from the
oracle (`mkdir -p out/prebuilt && cp -a <the file the loader resolves> out/prebuilt/`)
and gate against it later as a second independent build. An oracle with
`build/Release/obj.target` was compiled from source: there is no prebuilt to snapshot.
`md5sum` the snapshot against your own build's addon: the same file is one piece of
evidence, not two.

**The `npm pack` tree may already hold a `build/`**: a publisher's browser bundle, stale
binaries and `*.target.mk` from the publisher's machine. `build_addon.sh` deletes `build/`
before configuring, so read nothing from it before step 2: `ldd build/Release/*.node` on
that tree would describe someone else's binary for another platform.

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

The glue TUs are every `.cc` or `.c` in `$SRCDIR` (write its path out in later blocks, the
shell does not keep it), not only the hits.

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

For a binding over system libraries (image codecs, a 2D renderer), build the oracle from
source against the same system libraries the harness links:

```sh
cd $W && . ./fuzz.env
(cd oracle && npm init -y >/dev/null && npm_config_build_from_source=true npm install $PKG_NAME@<version>)
ls oracle/node_modules/$PKG_NAME/build/Release/obj.target    # present: it was compiled here
```

Use the environment form: npm 11 answers the `--build-from-source` flag with `npm warn
Unknown cli config "--build-from-source". This will stop working in the next major
version of npm.` (it still builds today). A prebuilt may bundle its own copies of those
libraries, a different back end from the one your harness links, which disagrees on
pixels for the decoders it does not share (not re-measured on the latest evaluation,
which built from source). npm may print `npm warn install-scripts ... not yet covered by
allowScripts` and still run the script; confirm what got built with `file` on the addon
the loader resolves ("Which binary does the package actually load?", below).

**A second `.node` that is not an addon.** Such a package's `binding.gyp` may declare a
`postbuild`-style target (`<pkg>-postbuild`) that emits a small `.node` file of its own
into `build/Release/`. It is a build step, not an addon: check what `lib/*.js` requires
(`grep -rn "require(.*\.node" <pkg dir>/lib/`); when the JS loads only the main `.node`,
the default `ADDON_MATCH` swaps exactly one file, so record none. `build_addon.sh` skips
postbuild targets by name and builds the main one.

**Its dependencies can bind to node's copies.** `check_symbols.sh` compares the addon's
own exports with node's, and also prints `DEPENDENCY-INTERPOSED` (a WARN, not a failure)
for a shared library the addon loads whose exports node also provides (a compression
library node bundles, which an image library the addon loads calls). In the real stack
those calls bind to node's copy, since the executable comes first in symbol lookup; in
the harness, to the system copy. Note it in the write-up; if the gate disagrees on inputs
that reach that library, it is the first suspect (`interposition.md`, "A dependency of
the addon").

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

### Addon, archive, or both: which code to instrument

`ldd build/Release/*.node` (step 1, question 2) lists the shared libraries the addon
loads. `build_addon.sh` instruments the addon's own objects whatever you decide; the
question is which library, if any, to rebuild as an instrumented archive.

* **The addon's own code is the boundary** when the addon parses the bytes itself before
  or instead of a library: an image loader's own format sniffing, an EXIF orientation
  reader, a BMP parser, a GIF loader that walks the decoded records. That code is in the
  addon's objects, already instrumented; link the pure-C++ ones via `ADDON_OBJS` (or copy
  the method, `boundary-shapes.md`).
* **One library is the boundary** when the bytes go straight into its decoder: rebuild
  that one as an instrumented static archive (below).
* **Usually both.** An addon over several system libraries does some parsing itself and
  hands the rest to the libraries. Instrument the addon and archive one library. On an
  image-drawing binding over six system libraries every confirmed bug was in the addon's
  own code, none in the archived library: the addon's own code is the common result,
  so never skip it to spend the time on archives.

**Which library to archive**, when the addon links several: the one the boundary calls
directly (its functions appear in `nm -u` of the boundary's object), that parses
attacker bytes (a decoder, not a renderer or a text shaper fed by the decoder's output),
largest decoder first, and one whose build system produces a static library. A second
archive is the same recipe again, if its source is reachable. The others stay system
`.so`, uninstrumented: their edges are invisible to AFL, gate check 4 WARNs that coverage
barely discriminates, and the write-up and the triage report's Scope section say which
decoders were instrumented and which were not.

### First choice: an instrumented static archive, with `build_lib.sh`

```sh
cd $W && . ./fuzz.env
for v in plain asan; do
  $R/build_lib.sh VARIANT=$v SRC=$W/src-lib [BUILD=autotools|cmake|meson|make] \
      [CONFIGURE_ARGS="..."] [CMAKE_ARGS="..."] [TARGET=<static target>] [ARCHIVES=...] [INC=...]
done
# step 4, per variant: link_harness.sh VARIANT=$v ... LIB=$W/out/$v/lib/lib<x>.a ARCHIVE_LIBS=<x>
```

It builds out of tree with the variant compiler (`AFL_USE_ASAN=1` for asan,
`-include undef_fuzzmode.h` against the fuzzing-mode macro, "The compiler wrapper defines
a macro", above), static only, and puts the archive in `out/<v>/lib/` and the library's
installed headers in `out/<v>/lib/include/`, where the corpus skill's instrumentation
check looks too. It writes the library's compared constants to
`out/<v>/dict2file-lib.raw`, which `link_harness.sh` merges into `out/<v>/dict.afl`, and
records its arguments so `rebuild_asan.sh` can redo the asan archive for the self-test.
The script's header has the exact meaning of `TARGET=`, `ARCHIVES=` and `INC=`.

**Order.** Before or after `build_addon.sh`, either works: `build_addon.sh` keeps
`out/<v>/lib/` across re-runs, and the library's dictionary file is its own. (An earlier
version wiped the directory on every re-run, and one run lost its archive that way.)

**The source.** The version the oracle loads: the distribution's source package when
you can get it (it carries the distro's patches), else the upstream release of the same
version from the project's own release page. A download mirror may 404 (one run gave up
a second library that way); a `git clone --depth 1 --branch <release tag>` of the
project's repository is the fallback. Unpack it into `$W/src-lib` (one directory per
library when there are several). Building from an upstream tag skips the distro patches:
say so.

**The build system.** `BUILD=` is detected from the tree; pass it when the tree has
several. Static-only options differ per project:

* autotools: `--disable-shared --enable-static` (the script's default). `cp -a` a source
  you copy, or make sees `configure.ac` newer than `configure` and reruns autotools.
* CMake: many projects have their own switches rather than `BUILD_SHARED_LIBS`
  (`ENABLE_SHARED=OFF` / `ENABLE_STATIC=ON`, say): read `option(` in `CMakeLists.txt`
  and pass them in `CMAKE_ARGS`. An older release whose `cmake_minimum_required` is below
  3.5 is refused by current CMake (`Compatibility with CMake < 3.5 has been removed`):
  add `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`.
* meson: `--default-library=static`.
* plain make: `TARGET=` names the static target.

**The ABI trap.** The distribution may build the library with a non-default ABI option,
and the upstream default then has a different struct layout. Case: the system JPEG
library was built for a newer ABI level than the upstream default; the harness would
have passed the addon's structs to an archive that lays them out differently. Read the
version macro in the installed config header before configuring, and pass the option
that reproduces it:

```sh
grep -rnE '#define [A-Z_]*(VERSION|ABI)[A-Z_]* ' /usr/include/$(gcc -dumpmachine)/*config*.h /usr/include/<lib>*.h 2>/dev/null
grep -rnE '#define [A-Z_]*(VERSION|ABI)[A-Z_]* ' $W/out/plain/lib/include/ | head    # after the build: must match
```

**Compile the harness against the archive's headers**, not the system ones, or the
struct layouts can differ silently even when the ABI options match (a generated config
header is per build). `link_harness.sh ARCHIVE_LIBS=<x>` puts `out/<v>/lib/include/`
first on the include path.

**Drop the system library from the link.** `LIBS_FROM_MK=1` lifts the addon's `-l<x>`
for the very library you archived, and any hard-coded `-L` path `binding.gyp` carries
(one package names a macOS package-manager directory). Left in, the link can pick the
`.so`. `ARCHIVE_LIBS=<x>` (several, space-separated) drops the matching `-l<x>` from the
lifted and the `EXTRA_LIBS` flags; the library's own dependencies go in `EXTRA_LIBS=`
(`pkg-config --static --libs <x>`).

**Verify**, per variant (`link_harness.sh` fails on the first itself):

```sh
cd $W && . ./fuzz.env
ldd out/$v/harness | grep -c 'lib<x>\.so'                 # must be 0
nm out/$v/harness | grep -E ' T <an entry function the addon calls>$'   # defined in the binary
nm out/$v/lib/lib<x>.a | grep -c sancov                   # non-zero; for asan, __asan_report too
```

**The self-test and the pristine variant.** `rebuild.sh` stays the default
`rebuild_asan.sh` line with the asan link's arguments (`LIB=` the archive,
`ARCHIVE_LIBS=`): it redoes the asan archive from the arguments `build_lib.sh` recorded,
then relinks with `link_harness.sh VARIANT=asan`, so `FAULT_SRC=` points into
`$W/src-lib` (`selftest-rebuild.md`). For triage's control, build the archive once more
with `build_lib.sh VARIANT=pristine` (plain clang with ASAN, no AFL) and link the
pristine harness against it; triage's pristine commands otherwise look for library
objects under `obj.target`, where there are none.

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

**The package may load a copy.** A gyp `copy` or `action_after_build` target can place
the addon at `build/bindings/<name>.node` (or similar) and `index.js` requires that path,
not `build/Release/<name>.node`. Read `index.js` (or `main` in `package.json`) for the
`require`; `md5sum` the two files. The real harness's `dlopen` hook swaps whichever path
is loaded, so nothing else changes.

## Several addons in one package

`binding.gyp` can declare several real targets (a codec and a hash used by the JS frame
layer, say). `build_addon.sh` builds one, printing `targets in binding.gyp: a b ->
building <target>`, and the rest are not built in `out/`. Then:

* **Name the boundary target** and pass `TARGET=<it>` to every `build_addon.sh` and in
  `rebuild.sh`, even when the automatic pick was right, so a reordered `binding.gyp`
  cannot change it.
* **Make the swap unambiguous.** `require(PKG)` loads every addon, and the real harness's
  default match (`/\.node$/`) then refuses with `AMBIGUOUS-SWAP`. Record the match once,
  in `fuzz.env`, where the real-side commands and triage read it:
  ```sh
  cd $W && . ./fuzz.env
  $R/init_workspace.sh W=$W ADDON_MATCH='<name>\.node$'
  ```
  Single-quote it on the command line; `init_workspace.sh` escapes it, so the file reads
  `ADDON_MATCH="<name>\\.node\$"` and sources back to the regex. A `REAL_ASAN` you write
  by hand with `ADDON_MATCH=` inside it needs the same escaping (`\\.` and `\$`).
* **When the JS layer needs the second addon** (a checksum over the frame, a hash the
  decoder verifies), the harness needs that code too: compile its library source into
  the harness TU the way that addon's glue does (a header-only `#define ..._PRIVATE_API` +
  `#include`, say), or link its objects from a build of that target (`TARGET=<other>`
  into a scratch `OUT=`, then add them to `LIB=`). Its include directory goes in
  `EXTRA_FLAGS="-I<package dir>/<its dir>"` on `link_harness.sh` (and in `rebuild.sh`).
  Say in the write-up whether the second addon's own code was fuzzed: through the
  harness it is exercised only as the JS calls it.

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
