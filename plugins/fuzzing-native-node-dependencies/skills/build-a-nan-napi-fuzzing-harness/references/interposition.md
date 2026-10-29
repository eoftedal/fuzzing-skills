# Symbol interposition: when the installed package runs the runtime's copy of its library

Read this when `$R/check_symbols.sh` prints `INTERPOSED: ...` or `DEPENDENCY-INTERPOSED`
(step 1 of SKILL.md), or when
the gate mismatches on a subset of valid seeds whose outputs differ by a few bytes and
nothing in `oracle-ceiling.md` sections 1 to 3 explains it.

## What happens

The node executable exports its own copy of some libraries (compression codecs, crypto,
a few parsers) from its dynamic symbol table. An addon that **vendors the same library**,
compiles it with default visibility and links without `-Bsymbolic` leaves its calls to
that library's public functions open to the dynamic linker, which resolves them to the
first definition in load order: the executable's. So the package as installed runs the
**runtime's** version of the library, and the vendored copy compiled into the `.node`
file is dead code on that platform.

Three consequences, all silent:

* **The gate's premise is false.** The direct harness links the vendored objects; the
  real stack runs the runtime's build of a different version. "Same machine code" no
  longer holds, whatever the gate says.
* **The gate can pass by luck.** Two versions of a codec agree on most inputs (a decoder
  for a stable format, most compression levels), so a small gate corpus agrees on every
  seed. The disagreement shows up later, on the corpus skill's bigger corpus, as a
  handful of `MISMATCH` seeds with the same `out_len` (or within a byte or two) and a
  different `out_hash`, which looks like uninitialised memory and is not: MSan and
  `MALLOC_PERTURB_` find nothing, and your own plain addon swapped in gives the oracle's
  hash, because it is interposed too.
* **Scope splits in two.** A bug in the vendored library is unreachable through the
  installed package on that platform (report it, but say it is reachable only where the
  addon binds its own copy), and a bug in the runtime's copy is the runtime's, out of scope.

## The check

```sh
cd $W && . ./fuzz.env
$R/check_symbols.sh            # ADDON=<path> to check another .node than the oracle's
```

For each addon `require(PKG)` loads, it compares the addon's default-visibility
functions with the ones the node executable exports and prints `INTERPOSED: <n> symbols
of <addon> are also exported by node (e.g. ...)`, or `OK: no shared exports` (`OK: ...
linked -Bsymbolic` for a symbolic build); exit 1 on any `INTERPOSED`. `init_workspace.sh`
also runs it once `PKG` exists. Run it right after the oracle install, before any build, because the remedy
changes which oracle every later step uses. One call proves the binding:

```sh
cd $W && . ./fuzz.env
LD_DEBUG=bindings node -e "require('$PKG').<one call>(<small input>)" 2>&1 | grep 'to node'
```

A line `binding file .../<name>.node [0] to node [0]: normal symbol '<LibFunction>'` is
the proof; no such line for the library's functions means the addon binds its own copy.

## The remedy: a second, symbolic oracle

Fuzz the vendored library, as the harness does, against a real stack that runs it:

```sh
cd $W && . ./fuzz.env
mkdir -p oracle-sym && cd oracle-sym && npm init -y >/dev/null
LDFLAGS=-Wl,-Bsymbolic npm_config_build_from_source=true npm install $PKG_NAME@$PKG_VERSION
cd $W && $R/check_symbols.sh ADDON=$(ls oracle-sym/node_modules/$PKG_NAME/build/Release/*.node | head -1)
$R/init_workspace.sh W=$W PKG=$W/oracle-sym/node_modules/$PKG_NAME \
    REAL="env PKG=$W/oracle-sym/node_modules/$PKG_NAME node $W/real_harness.mjs"
```

* `-Bsymbolic` makes the addon bind its own definitions first; the build from source is
  needed because a prebuilt was linked without it. The `LD_DEBUG` probe on the new
  oracle should print no `to node` line for the library's functions.
* Build the sanitized and plain addons the same way:
  `build_addon.sh VARIANT=$v OUT=$W/out EXTRA_LDFLAGS=-Wl,-Bsymbolic`. An exported
  `LDFLAGS` is ignored, since `build_addon.sh` sets its own. `rebuild_asan.sh` passes
  `EXTRA_LDFLAGS` through, so put it in `rebuild.sh` too, or the self-test's restore
  leaves a non-symbolic asan addon behind and the next asan gate mismatches again.
* Re-run `init_workspace.sh` with `REAL_ASAN=` pointing at the symbolic oracle (`PKG=`
  inside the command) once the asan addon is built.
* **Keep `oracle/`.** It is the package as a user has it: triage's as-installed
  reproducer check runs against it, and a finding in the vendored library has to say
  whether that install reaches it.
* **Say it in the write-up and the triage report's Scope section**: which library the
  installed package really runs on this platform (the runtime's copy, by version), that
  the fuzzed real stack is a symbolic rebuild, and that findings in the vendored code
  reach users only where the addon binds its own copy (another runtime build, a static
  node, another OS).

## A dependency of the addon

`check_symbols.sh` also looks at the shared libraries the addon loads (`ldd`), and prints
a `DEPENDENCY-INTERPOSED` WARN for each one that exports functions node also exports.
The usual case is a binding over system libraries: an image library the addon needs
calls a compression library, and node bundles its own copy of that compression library.
In the real stack those calls bind to **node's** copy (the executable is first in lookup
order); the direct harness has no node, so they bind to the **system** copy. The addon's
own code is unaffected, and nothing is dead code, so this is a warning, not the remedy
above:

* note it in the write-up and the triage report's Scope section (which library, and that
  the real stack runs node's build of it under that dependency);
* if the gate disagrees on inputs that reach that library (a compressed chunk inside an
  image, say), suspect this first, before `oracle-ceiling.md`. The `LD_DEBUG=bindings`
  probe above, with `grep 'to node'` on the dependency's file name, shows the binding.

On the evaluation that first met it, the gates agreed on every seed: the two copies
decode the same bytes the same way.

## Where it sits in the mismatch order

`oracle-ceiling.md` works through uninitialised or out-of-bounds reads, then the oracle's
lossy transformations, then your mirroring. Interposition comes **before all three**: it
changes which library one side runs, so every later diagnosis is about the wrong code.
