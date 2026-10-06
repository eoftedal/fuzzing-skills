# Build traps: what `build_addon.sh` guards against, and what it cannot

`resources/build_addon.sh` encodes everything in the first section. Read it when the
script fails, when you must build by hand (cmake-js, a dependency with its own build
system), or when a variant behaves wrongly.

## The make line, and five ways it goes wrong

```sh
# add the AFL runtime to the TARGET-SPECIFIC LIBS line gyp emits right after the LIBS block
sed -i "s#^\(.*\.node: LIBS := \$(LIBS)\)\$#\1 $(resources/find_afl_rt.sh)#" build/<target>.target.mk
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
inputs the shipped addon rejects. Case: a 15-seed gate passed clean; the 630-seed corpus
reported `mismatched=50`, every one a frame with a non-zero dictionary id that the real
stack rejects with `Dictionary mismatch`. `-U` on the command line does not help (the
wrapper re-adds the define); `-include resources/undef_fuzzmode.h` does, and
`build_addon.sh` and `link_harness.sh` pass it for the AFL variants. Check with
`echo | afl-clang-fast -dM -E -x c - | grep FUZZING` and
`grep -rl FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION <library src>`.

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

## The library is a separate shared object (step 3b)

The runtime cannot live in the library. Verified order of attempts:

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

## Which binary does the package actually load?

Never assume `build/Release`:

```sh
node -e "console.log(require('bindings')({bindings:'<name>',path:true}))"   # bindings
node -e "console.log(require('node-gyp-build').path('<pkg dir>'))"          # node-gyp-build
file "$(node -e "console.log(require('node-gyp-build').path('<pkg dir>'))")"
```

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
zig route is written up in `zig-build.md` with `resources/wrapper_build.zig`. Falling
back to `git show <tag>:binding.gyp` for the last node-gyp release is the choice when
the toolchain cannot be installed, and it measures a weaker surface: on an image-decoding binding
the node-gyp release's harness saw only the in-tree glue, the zig build's harness saw every
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
--no-package-lock` resolves the published range instead. A peer range can pin it too. A grammar package declaring `peerOptional <runtime>@^<older minor>`
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
