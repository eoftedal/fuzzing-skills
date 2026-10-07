---
name: build-a-ruby-c-extension-fuzzing-harness
description: Build a direct AFL++ fuzzing harness for the C library behind a Ruby gem's C extension (a native gem built with mkmf / extconf.rb), bypassing ruby while executing the same machine code, and prove it is faithful (fidelity gate against an independently installed gem), detects injected faults, and does not crash on its own account. Use when asked to fuzz a Ruby gem's C extension, a native gem (a parser, image, compression or regex binding), or the C library a gem vendors or links; to harness the library behind a Ruby binding; or when fuzzing through the interpreter is too slow. The first of four skills - then derive-a-fuzzing-corpus-from-source, run-a-fuzzing-campaign, triage-fuzzing-findings.
---

# Build a direct fuzzing harness for a Ruby C extension

Goal: delete ruby from the loop while still executing **the same machine code** the
extension executes. A fast harness that tests something subtly different is worse than no
harness, so every step below ends in a check that it is still faithful.

`resources/` holds the scripts; every step names the one it uses, and every script's
header documents its knobs. `references/` holds the long versions of the rules with the
cases that produced them; read one only when a step points you at it or a check fails.
`references/build-traps.md` has the mkmf and vendored-build traps. Read this file with a
file reader, not `cat` into a terminal that truncates.

**Status.** A port of the Node sibling plugin's `build-a-nan-napi-fuzzing-harness`,
tested on Ruby 3.3.8 / clang 21 / AFL++ 4.33c / aarch64 Linux against three shapes: a gem
over a system library, a gem with vendored libraries (mini_portile2), and a gem whose
parser is the extension's own C. Facts marked *measured* come from those runs; `EVIDENCE.md` lists the runs and
what each produced. Rules attributed to the Node sibling were learned on Node bindings and
kept because they are about the C library or the method, not the runtime. This file says
what to do and why; it deliberately does not quote what earlier runs found -- your target's
stub count, gate tallies and findings are yours to measure.

**Layout convention** (the scripts assume it): a fuzz workspace `W` holding an independent
`oracle/` install of the published gem, `out/<variant>/` for each build (`plain`, `asan`,
and `pristine` when you need it) with the snapshot `build_ext.sh` makes (`<name>.so`,
`Makefile`, `extconf.h`, `mkmf.log`, `obj/*.o`, vendored archives under `lib/`) plus
`harness`, `harness-fork` and `map_size`, and the gate corpus in `corpus/`. The gem
source you build lives elsewhere (`$W/src/<gem>-<ver>`, below); always pass `build_ext.sh`
an **absolute** `OUT=` into the workspace, because it runs from the extension directory.

**The whole path, for the common case** (library compiled into, or vendored by, the extension):

```sh
R=/abs/path/to/this/skill/resources; W=/abs/fuzz; X=$W/src/<gem>-<ver>/ext/<name>
# 1  gem install --install-dir $W/oracle --platform ruby <gem> -v <ver>     (the REAL stack)
#    gem fetch <gem> -v <ver> --platform ruby && gem unpack <gem>-<ver>.gem --target=$W/src
#    B="OUT=$W/out ORACLE=$W/oracle/gems/<gem>-<ver> GEM_PATH=$W/oracle"   (every build_ext.sh run)
# 2  (cd $X && $R/build_ext.sh VARIANT=plain $B); then, in $W:
#    $R/find_boundary.sh out/plain/obj/*.o out/plain/lib/*.a                -> the function to call
# 3  (cd $X && $R/build_ext.sh VARIANT=asan $B)                             -> out/asan/
# 4  harness.cc from $R/harness_template.cc, then for v in plain asan:
#    $R/link_harness.sh VARIANT=$v MK=out/$v/Makefile SRCDIR=$X OUT=$W/out \
#        LIB="out/$v/lib/lib<dep>.a" [EXT_OBJS="out/$v/obj/<file>.o"] [LIBS_FROM_MK=1]
# 5  real_harness.rb from $R/real_harness_template.rb, then $R/gate.sh (plain, then asan),
#    MODES="MODE=..." listing every entry point the harness has besides the default
# 6  $R/smoke.sh MODES="..." HOSTSAN="env LD_PRELOAD=$($R/find_asan_rt.sh) \
#        PKG=$W/oracle/gems/<gem>-<ver> EXT=$W/out/asan/<name>.so ruby real_harness.rb"
#    then, once smoke passes (its fixes rebuild the harness, which would stale a self-test):
#    $R/detect_selftest.sh ... | tee selftest.txt
#    then: corpus skill -> run-a-fuzzing-campaign -> triage-fuzzing-findings
```

The order is **gate -> smoke -> self-test**. Smoke failures force harness fixes, and the
self-test vouches only for the binary it ran against, so running it before the smoke
means running it twice. After any harness change, re-run the gate too.

---

## Step 1 — Triage, before building anything

**The oracle**, an independent install of the published gem, built from source, with its
dependencies:

```sh
gem install --install-dir $W/oracle --platform ruby <gem> -v <ver> [-- <extconf args>]
```

`--platform ruby` matters: a precompiled platform gem (`<gem>-<ver>-aarch64-linux-gnu`,
`-x86_64-linux`) ships someone else's build of the extension and of every vendored
library, a different back end from the one your harness links. Anything after `--` goes to
`extconf.rb` (`--use-system-libraries`, `--with-<lib>-dir=`); whatever you pass here, pass
the **same** string as `EXTCONF_ARGS=` to every `build_ext.sh` run, or the oracle and the
harness are different programs. `real_harness.rb` later activates that gem's spec by path
(`PKG=$W/oracle/gems/<gem>-<ver>`) and points the gem path at `oracle/` unless `GEM_PATH`
is set, so its runtime dependencies must resolve there; that is why they are installed
with it (measured on a gem that also ships as a Ruby default gem: the oracle copy is the
one activated).

**The source you build** is a separate copy, never the oracle's directory: `build_ext.sh`
writes a Makefile and objects into the extension directory and deletes cached vendored
builds under the gem root. Unpack the **published** `.gem` rather than a git clone: it is
exactly what the oracle compiled, and a clone often lacks generated sources the release
ships (a parser generated at `rake` time).

```sh
mkdir -p $W/src && cd $W/src
gem fetch <gem> -v <ver> --platform ruby && gem unpack <gem>-<ver>.gem --target=$W/src
ls $W/src/<gem>-<ver>/ext/*/extconf.rb      # one directory per extension; X is the one you fuzz
```

`extconf.rb` may need build-time gems: a gem that vendors its libraries via mini_portile2
does `gem "mini_portile2"`, and from the unpacked tree it failed with `Could not find 'mini_portile2' (~> 2.8.2)` (measured). They
are runtime dependencies, so the oracle install has them: run `build_ext.sh` with
`GEM_PATH=$W/oracle`, and with `ORACLE=$W/oracle/gems/<gem>-<ver>` so every configure
probe is compared with the oracle's (step 3a).

**Is a direct harness the right tool here?** Decide it now, not at the end. If every
call costs milliseconds *at the smallest input the API accepts* (a renderer, a
compressor at its default level), or everything interesting is inside an uninstrumented
system library, a direct harness buys less than it costs to keep faithful: say so and
stop. Two things that look like that and are not: an input-chosen cost (slow only when
the attacker says so: bound it, step 4), and a slow entry point beside a cheap parser
of the same bytes (harness the parser as a mode). The speed-up over the interpreter is
otherwise a given, not a result: do not measure or report it.

Three things that end this skill's build route early, and what to do:

* **No `ext/` and no `extconf.rb`.** An FFI gem (`ffi_lib`, `attach_function` in `lib/`)
  calls a system or bundled `.so` through libffi; there is no extension to build. The
  library's C API is then the boundary and the Ruby `attach_function` signatures are the
  dispatch, but `build_ext.sh` and `link_harness.sh` (which read an mkmf Makefile) do not
  apply; say so before improvising.
* **A Rust extension** (`create_rust_makefile`, `rb_sys` in `extconf.rb`): the mkmf
  Makefile drives cargo, the compiler override does not reach it, and this skill does not
  cover it.
* **The extension does not build on this Ruby** (a removed C API, `required_ruby_version`
  in the gemspec excludes it): install the Ruby the gem supports. Never patch the gem: then
  the real stack is no longer the published package.

Then answer four questions. Each is one command.

1. **Where is the glue, and is it hand-written or generated?**
   ```sh
   grep -rln --include='*.c' --include='*.cc' --include='*.cpp' --include='*.h' \
        -e 'ruby\.h' -e 'Init_' $X
   grep -rlim1 "swig\|automatically generated\|DO NOT EDIT" $X
   ```
   Generated glue (SWIG: `SWIGEXPORT`, `_wrap_` functions) has no binding-free function
   and nothing to link from the extension: the boundary is the library call each wrapper
   makes, and the risk is the state `Init_<name>` installs (step 4, layer 3).
   Hand-written glue *may* have one; step 2 settles it.
2. **Is the library compiled into the extension, vendored as an archive, or a system
   `.so`?**
   ```sh
   grep -nE 'mini_portile|MiniPortile|pkg_config|have_library|find_library|dir_config|use-system-libraries' $X/extconf.rb
   ldd $(find $W/oracle -name '<name>.so' | head -1) | grep -vE 'libc|libm|libruby|libgcc|linux-vdso|ld-linux|libpthread'
   ```
   Library `.c` files beside the glue in `ext/<name>/`: compiled in, its objects land in
   `out/<v>/obj/`. A mini_portile2 recipe or a configure step
   that builds a static library: a vendored archive, which `build_ext.sh` copies to
   `out/<v>/lib/`. A `-l<dep>` against a system library: instrument the extension, accept
   the system library as uninstrumented or rebuild it (step 3b), and **state that scope**
   (step 5 reads differently then).
3. **Which optional features did the build detect?** A missing `-dev` package does not
   fail `extconf.rb`; it turns a decoder into dead code. After the plain build (step 3):
   ```sh
   grep -E '^#define (HAVE|USE|WITH)_' out/plain/extconf.h
   grep -- '-------------------- no' out/plain/mkmf.log      # every have_* that said no
   ```
   Some extconf scripts put their macros in `$defs`/`$CPPFLAGS` instead of `extconf.h`;
   `$R/lift_flags.sh out/plain/Makefile SRCDIR=$X` prints them all.
4. **Which binary does the gem actually load?** Ask the process, not the directory:
   ```sh
   GEM_HOME=$W/oracle GEM_PATH=$W/oracle ruby -e 'require "<feature>"
     puts File.readlines("/proc/self/maps").map { _1.split(" ", 6)[5].to_s.strip }.grep(/oracle.*\.so\z/).uniq'
   file <that .so>
   ```
   A path under `gems/<gem>-<ver>-<platform>/` means the platform gem won over
   `--platform ruby`; reinstall. A precompiled gem that loads is still an asset for a second
   comparison: install it into another directory and gate against it later.

---

## Step 2 — Find the boundary

The deepest function the extension calls that touches no Ruby API itself.

**Look for GVL-released work first.** A function passed to `rb_thread_call_without_gvl`
(or `rb_nogvl`) may not touch Ruby objects by construction; when it exists it is the
boundary, and it tells you the work runs without the GVL, which matters for triage.

```sh
grep -rn 'rb_thread_call_without_gvl\|rb_nogvl' $X/
$R/find_boundary.sh out/plain/obj/*.o out/plain/lib/*.a           # rank EVERY object
objdump -dr <candidate.o> | awk '/>:$/{f=$2} /R_.*(rb_|ruby_)/{print f}' | sort | uniq -c   # which functions own the refs?
```

The ranking needs objects, so run `build_ext.sh VARIANT=plain` (step 3) first and come
back; the two steps are not strictly ordered. An installed gem has only the `.so`. An
archive is counted as a whole; to rank its members,
`mkdir t && cd t && ar x ../out/plain/lib/lib<dep>.a && $R/find_boundary.sh *.o`.

The library's own objects showing 0 and the extension's showing dozens is the whole
picture in one view (measured: the system library's archive at 0 runtime references, the
gem's parser glue in the dozens). The lowest count is where to start reading, not the answer: the
criterion is *a function on your input path whose own body is Ruby-free*. On the Node
sibling every object of one binding referenced the runtime 26-55 times and the
lowest-count object was the wrong one.

Prefer a function that already does the dispatch and the option plumbing, so the gem's
format sniffing and limit checks are *its* code, not your copy. If the gem exposes several
entry points over the same engine (string vs IO vs file, parse vs parse_stream), harness
them behind an **environment variable**, never an input byte: a corpus file stays
byte-for-byte what the real API consumes, so any seed or crash replays unchanged on the
real stack. **Budget the modes, and decide them now**, before the first gate: a mode added
after the gate rebuilds the harness, and gate, smoke and self-test all run again (on the
Node sibling one run spent 5 of its 10 harness minutes on exactly that). Keep a mode only
if it reaches library code the default does not (a different decoder, the compressor
behind a decompressor, a different parser state machine), and stop at two or three; six
modes gated and smoked on two variants cost one Node run an hour. Entry points that are
thin wrappers over the same call are one mode with different post-processing: fuzz the
richest one and say so. A mode that cannot reject its input (a compressor) gets
`:min_arms=1` in the gate's `MODES=` spec, so check 3 stays strict for the default mode.

For generated glue, skip the ranking: `grep -n '<libraryEntryPoint>(' $X/<generated>.c`.

**Shapes where there is no single Ruby-free function, and what the boundary is then.**
Ruby extensions interleave `rb_*` calls with parsing far more than thin N-API glue does, so
expect one of these more often than not.

* **The parser builds Ruby objects as it goes** (an `rb_hash_aset` per key, an
  `rb_str_new` per token, an `rb_funcall` into a handler per event). Typical of a gem
  over a system library: its glue builds Ruby objects per library event, so the boundary
  is **the library's C API driven the way the gem drives it** (measured). Mirror the setup calls, the input and
  encoding settings and the event loop in the same order, and serialise every event with
  every argument the extension reads from it. Link no extension object.
* **The parser IS the extension's own C** (the parser entry function in the parser
  source, no library underneath). Link the parser's objects (`EXT_OBJS="out/<v>/obj/<parser>.o
  out/<v>/obj/<error helper>.o ..."`) and give the runtime calls on its path real definitions in a **shim**
  (`resources/ruby_shim_template.c`, passed as `link_harness.sh ... SHIM=shim.c`, which
  compiles it per variant, links it, excludes it from stubbing and rebuilds it in the
  self-test). One such parser called `rb_ensure`, `rb_block_given_p` and `TypedData_Wrap_Struct`
  unconditionally, so with stubs alone it traps on the first input. Find the set by
  linking without the shim and reading which stub the gate trips; define only those, each
  mirroring what libruby does *for this caller*, and leave the rest as stubs so check 5
  still proves the path stayed off the runtime. How many stubs remain depends on which
  objects you link (an extension's name caches pull in `rb_intern*`, `rb_sym2id`, ...).
  The template covers `rb_ensure`/`rb_protect` (`setjmp`, propagation outward), the xmalloc
  family, `ruby_vsnprintf`, the `ruby.h` macros you must `#undef` to define functions such
  as `rb_str_new` or `rb_intern`, and `rb_enc_find` over a table generated from the runtime
  (`resources/gen_enc_table.rb`; an unknown name is ASCII-8BIT, not NULL -- measured). When
  the parser's callbacks BUILD Ruby objects (the builder callbacks behind a load method),
  make VALUE a small
  tagged node (string, symbol, array, hash, object) that the shim fills, serialise the
  tree into the artifact, and have `real_harness.rb` walk the real objects into the same
  format -- iteratively on both sides. Mirror Ruby's encoding rules from experiments:
  `rb_intern` raises EncodingError for any byte >= 0x80, valid UTF-8 included, while Ruby's
  `to_sym` does not (measured). Say which shape you chose, and mirror what the callbacks
  return (`references/four-layers.md`, layer 4).
* **The work is a method on a `TypedData`-wrapped object** (`rb_define_method` taking
  `VALUE self`, `TypedData_Get_Struct` inside). The object cannot exist without the
  interpreter. Do not try: **copy the method body into the harness** minus its `rb_*`
  calls, with a comment naming the file and lines, copy any `static inline` helpers from
  the same TU verbatim, and build the struct the way the alloc function and `initialize`
  do (`references/four-layers.md`, layer 1). Note the drift risk in the write-up.
* **The dispatch is in Ruby** and the C methods are one-line wrappers (`lib/**/*.rb`
  decides which native method runs, how big a buffer it gets, how the input is chunked).
  `find_boundary.sh` shows every library object at 0 and cannot tell you the logic is in
  `lib/`. The boundary is the library's C API driven exactly the way the Ruby drives it,
  in the same order, including how it re-chunks the input.

---

## Step 3 — Build the variants

Two variants now, one at a time, each snapshotted into `out/<variant>/`: `plain`
(throughput) and `asan` (bug finding). A third, `pristine` (ASAN, no AFL instrumentation),
is the control for "did my instrumentation invent this bug?": build it when you have a
crash to cross-check, not before (on five Node evaluation targets it was built every time
and used on none).

Every AFL variant gets `-include undef_fuzzmode.h`, because the compiler wrapper defines
`FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION` and libraries compile checks **out** under it
(on the Node sibling: a compression library's dictionary-id check, a regex engine's
parser limits). An instrumented library then accepts what the shipped extension rejects,
and the gate corpus is usually too small to notice. `grep -rl
FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION <library src>` tells you whether this target
cares; `build_ext.sh` and `link_harness.sh` add it either way.

### 3a. Library compiled into, or vendored by, the extension (the common case)

```sh
cd $X
for v in plain asan; do
  $R/build_ext.sh VARIANT=$v OUT=$W/out ORACLE=$W/oracle/gems/<gem>-<ver> GEM_PATH=$W/oracle \
      [EXTCONF_ARGS="<same as the oracle>"] [PKGROOT=<gem root>]
done
```

The compiler goes in at **both** stages. While `extconf.rb` runs: `CC`/`CXX` and
`AFL_USE_ASAN` in the environment, the flags through `--with-cflags` (mkmf ignores an
environment `CFLAGS` -- measured -- but vendored recipes read only the environment, so both
are set). Then `make CC= CXX= ARCH_FLAG="<sanitizer flags>"` for the extension's own TUs,
because mkmf writes Ruby's own compiler into the Makefile.

**Configure probes are compared with the oracle's.** mkmf's flag probes compile with
`-Werror`, and under clang 21 Ruby 3.3's own `ruby.h` warns, so every such probe failed
and was silently dropped -- on one target a vendored library's include path, which then
broke the build with a vendored header not found (measured). `build_ext.sh` silences those clang warnings and, with
`ORACLE=`, diffs every probe in the variant's `mkmf.log` against the oracle's gcc-built
one; any difference is a FAIL (`out/<v>/probes.diff`).
See `references/build-traps.md`.

The link
is done by **plain** `clang -shared` with the AFL runtime appended to `LIBS` inside the
Makefile: afl-clang-fast filters `afl-compiler-rt.o` out of a `-shared` link even when
`LIBS` names it (measured: the `.so` had no `__afl_area_ptr` and ruby refused it). Cached
mini_portile builds (`ports/<host>/`, the `ports/*.installed` markers and `tmp/`, under
the gem root and the extension dir) are deleted first, or the second variant silently
links the first variant's library -- a leftover marker alone made a gem skip its
vendored library build (measured). Downloaded tarballs are kept in `out/vendor-archives/`
and put back before each build: a gem may delete `ports/` including `ports/archives/`, and
the second variant then re-downloaded the library (measured; offline it would have failed).

**Everything vendored is snapshotted right after `extconf.rb`**, because a gem's
Makefile may delete the vendored install trees -- archives AND headers -- once the extension
is linked (measured: before this, `link_harness.sh` failed on a vendored header not found and
`LIBS_FROM_MK=1` on a missing archive, in two independent evaluation runs).
`out/<v>/ports/<lib>/<ver>/{include,lib}` holds the install trees and the snapshot
Makefile is rewritten to point there, so `lift_flags.sh` and `LIBS_FROM_MK=1` see this
variant's own copies (the originals are shared by every variant, whichever built last).
`out/<v>/vendor/<lib>-<ver>/` records each recipe -- mini_portile's configure options, the
tarball, the gem's patches in order -- for the self-test's out-of-tree rebuild
(`rebuild_vendored.sh`, step 6). Then it checks the AFL runtime is in the `.so`, the **library**
objects or archives carry coverage symbols, ASAN symbols are present when they should be,
and **ruby can load the result** -- standalone, or, when its `Init_` needs the gem's own
Ruby first (`cannot load such file -- <gem>/version`, then `uninitialized constant
<Gem>::<Class>` for a class `lib/` defines first; measured), through the gem's own `require` with this `.so` placed where
`lib/` expects it and verified mapped (`REQUIRE=` / `LOAD_PRE=` when the defaults do not
fit) -- and lists system libraries the `.so` links as
uninstrumented (measured: all variants of a system-library target built, verified and
loaded).

Snapshot: `out/<v>/{<name>.so, Makefile, extconf.h, mkmf.log, build.log, obj/*.o, lib/*.a,
ports/, vendor/}`, plus `out/vendor-archives/` shared by the variants.
`lift_flags.sh` drops `-D` macros whose value contains spaces or quotes (a string macro
holding the patch list) and names them on stderr: they cannot survive
the word splitting of the compile line, and cut in half they warned on every compile.
The `.so` keeps its original file name, because ruby calls `Init_<basename>`.
When the script fails, `out/<v>/build.log`, `mkmf.log` and `references/build-traps.md`.

### 3b. Library is a separate shared object

The runtime cannot live in the library. Instrument the library with plain clang
`-fsanitize-coverage=trace-pc-guard` and link `resources/covstub.c` into its targets so
its own executables still link; the AFL runtime lives in the harness. The meson
invocation is in the header of `covstub.c`; the attempts that do not work are in
`references/build-traps.md`. Link the harness with `LIBS_FROM_MK=1` so it gets the
extension's own `-l` flags (minus libruby), and make sure the instrumented `.so` is the
one the loader finds.

Whenever the harness TU is compiled by something other than afl-clang-fast
(`link_harness.sh HARNESS_CXX=g++`, for a header that refuses clang), it gets
`-include resources/afl_shim.h` for the persistent-mode macros, and
`strings out/<v>/harness | grep -c SIG_AFL_PERSISTENT` must be non-zero afterwards.
(That case is from the Node sibling; whether a Ruby extension needs it is unverified.)

---

## Step 4 — Write the harness

Start from `resources/harness_template.cc`. It already copies the input into an exactly
sized `malloc`, reads modes (and opt-in ceilings) from the environment, prints the
one-line `in_len= status= err= out_len= out_hash= lossy= invariant=` contract, frees its
init state in the single-shot path (or the ASAN variant dies in LeakSanitizer before
printing), traps with `AFL-HARNESS-RUBYPATH` on a branch only the binding reaches
(`binding_path_reached`), and builds both drivers from one TU. It is written for a
synchronous one-shot call; for a **streaming** API fed in chunks, concatenate every output
chunk and hash that, and for a **callback-driven** library (an event loop, a
handler-driven parser) serialise every event with every argument the real handlers read and hash the
stream; both templates carry a sketch of each. The extension's headers are C: wrap them
in `extern "C" { }` if they do not do it themselves.

What you add is the mirroring of **four layers**, which live in different files. The
checklist; the long form with cases is `references/four-layers.md`.

1. **The object the runtime owns.** Prefer a library factory. If the extension allocates
   it (`TypedData_Make_Struct`, an alloc function), copy the struct definition verbatim
   from the `.c` file, `calloc` it the way `ZALLOC` does, set every field `initialize`
   sets, and never `memset` a C++ object.
2. **The option layer, and the dispatch.** Defaults live in `lib/**/*.rb` (keyword
   defaults, a default option bitmask) and reach C
   as positional arguments or a Hash (`rb_get_kwargs`, `rb_hash_aref`). Check whether Ruby
   also decides *which* native method runs and *how big a buffer* it gets, and mirror that
   in the same order. When you need a runtime limit, ask the runtime at build time, never
   quote one, and `#error` when the macro is missing rather than defaulting it:
   `EXTRA_FLAGS="-DRUBY_LONG_MAX=$(ruby -rrbconfig/sizeof -e 'p RbConfig::LIMITS["LONG_MAX"]')"`.
   The same goes for **tables** the Ruby side consults: a gem's serializer that calls
   `Encoding.find(<document encoding>)` raises ArgumentError for encodings the library
   accepts and Ruby does not know (measured), so the direct side needs Ruby's
   `Encoding.name_list` -- generated into a header at build time, never typed in (one
   evaluation run found this; the gate would otherwise mismatch on those encodings).
   **Recovering parsers** (a recovering parse mode as the gem's default) reject almost
   nothing: almost every seed takes the success arm. Keep the default arm what a user
   gets, put what the recovery reported (the gem's error list) into the artifact, and add
   its strict option set as its own `MODE` if the gate's check 3 needs rejects. Mirroring a
   library from C++: a library's newer API changed pointer constness / `void*` fields
   (an error struct's node field, the error callback's argument, an output write
   callback's buffer); cast as needed -- each was a compile error in an evaluation run.
   Include only the library's headers there; the harness does not need `ruby.h` at all
   when no extension object is linked.
3. **Process-global state `Init_<name>` installs.** Custom allocators (they decide what a
   sanitizer can see: an extension that calls `xxxMemSetup(ruby_xfree, ruby_xmalloc,
   ...)` is mirrored with `free`/`malloc`/... and a comment, because those names are stubs
   here), error handlers, and the **full handler set** of a callback-driven library,
   reading the same arguments and returning what the real handlers return. Runtime-only
   branches inside a mirrored hook must **trap** (`binding_path_reached`).
   ```sh
   grep -rn "Init_[A-Za-z0-9_]*\s*(\|rb_define_method\|rb_define_alloc_func" $X/
   grep -rniE "MemSetup|SetAllocator|ruby_xmalloc|ruby_xfree|_default\(|SetErrorFunc" $X/
   ```
4. **What the method does after the boundary returns.** Read the whole method: a
   post-processing step that fills the values the Ruby API exposes is common and is never
   offered as a boundary candidate. Any `rb_raise` longjmps out, so the mirror stops where
   the real method stops.

Three more things to check, each a grep in the reference:

* **How the bytes are delivered.** `RSTRING_PTR`/`RSTRING_LEN` or `StringValuePtr` is
  length-delimited: copy exactly. `StringValueCStr` raises `ArgumentError` ("string
  contains null byte") for any embedded NUL: mirror that rejection before the call
  (status=1, `err=ArgumentError`). A transcode (`rb_str_conv_enc`, `#encode` in `lib/`)
  changes the bytes: mirror it or mark those inputs lossy. **Several byte arguments** (a
  pattern and a subject) go in one file, framed with a separator the API's values cannot
  carry (NUL before a `StringValueCStr`; a length prefix otherwise), split identically on
  both arms and documented at the top of `harness.cc`; the corpus skill's seeds then use
  the same framing.
* **NUL termination.** Do not add one unless the extension relies on one. Every Ruby
  String keeps a NUL after its bytes (measured), so a library that reads to NUL works on
  the real stack and over-reads in the harness: that is a finding, not a harness choice.
* **Make the library actually do the work.** An open is not a decode, and a parse is not
  an evaluation. Force it, record something only real work could produce, and reset only
  what is safe to reset.

**The `err` field is one token, identical on both sides**: the library's numeric code
when the gem exposes one (an exception `#code`), else for Ruby's own failures the
exception class (`ArgumentError`, `NoMemoryError`, `RangeError`), else the library's
error name or message with spaces replaced by `_`. Many Ruby messages embed the input
position (a message that embeds `line 1 column 4`; measured), so `err=` comes from a
stable field on the gem's exception (e.g. `#problem`), never the message. A token unique per seed is
useless for the corpus skill's histograms, which steer by that field.

**Attacker-declared allocations** (a declared content size, an image header's dimensions)
get **no cap by default**. Mirror what Ruby does instead, with its own tokens, all
measured on Ruby 3.3: a size the C string API cannot represent raises `ArgumentError`
("negative string size (or size too big)"); from Ruby code a size above `long` fails
earlier with `RangeError`; a legal size the allocator refuses raises `NoMemoryError`
("failed to allocate memory"), which is not a `StandardError`, so a gem's `rescue => e`
does not catch it. Linux overcommit let `String.new(capacity: 2**40)` succeed, so only a
bounded address space reaches that last branch. Let the fuzzer's memory limit bound the
run (`afl-fuzz -m`, or `max_allocation_size_mb` under ASAN, both from `ALLOC_CAP_MB` in
the campaign). An invented cap was measured, on the Node sibling, to reject inputs the
real package accepts. Both templates carry an **opt-in** `ALLOC_CEIL=<bytes>`, off unless
set, applied only at the attacker-declared site and reported as `err=alloc-ceiling`; set
it identically on both arms, never wrap `malloc` or `String.new` globally.

**Attacker-chosen work** is the same problem in time: an input field that sets an
iteration count, a cost or rounds exponent, a dimension of a loop. Mirror the gem's own
bound if it has one (read the Ruby validation and the C parser), and otherwise add an
**opt-in** `WORK_CEIL=<units>` applied identically on both arms at that field and reported
as `err=work-ceiling`. Set it for the campaign (the smoke's hangs are otherwise all that
field), and keep high-cost seeds out of `corpus-final/` as hangs. An unbounded
input-controlled work factor is itself a finding for triage: quote the field and the
time at its minimum and maximum.

Then link, once per variant:

```sh
$R/link_harness.sh VARIANT=plain MK=out/plain/Makefile SRCDIR=$X OUT=$W/out \
    LIB="out/plain/lib/lib<dep>.a" [EXT_OBJS="out/plain/obj/<file>.o"] [LIBS_FROM_MK=1]
```

`LIB=` is what the boundary's code is in: the vendored archive, or the library `.o` files
the extension compiles itself (`out/<v>/obj/<lib file>.o`, never the glue's). `EXT_OBJS=`
is extension objects you link because the boundary or a Ruby-free helper lives in them;
stubs are generated from exactly these. At least one of the two is required.
`LIBS_FROM_MK=1` appends the extension's own `$(LIBPATH) $(LOCAL_LIBS) $(LIBS)` minus
libruby (system libraries); `EXTRA_LIBS=` adds more.

It compiles `harness.cc` with the include paths and `-D` macros mkmf used (`lift_flags.sh`:
a `HAVE_*` macro changes struct layouts and which decoder is compiled), generates trapping
stubs (`gen_stubs.sh`), self-tests them, links `harness` and `harness-fork`, and writes
`out/<v>/map_size`. The stubs are **exactly** the undefined symbols of `EXT_OBJS` that
libruby exports (`nm -D` of `libruby.so`, or of the ruby binary for a static build), minus
what `LIB` defines (measured: data stubs are real, e.g. `rb_cObject`). Ruby
exports **data** too (`rb_cObject`, `rb_eNoMemError`, read by inline helpers such as
`rb_class_of`), which a function stub cannot trap, so each data stub is a read-only
64 KiB-aligned page made `PROT_NONE` at startup, with a SIGSEGV/SIGBUS handler. Every stub
prints `AFL-HARNESS-STUB: entered Ruby runtime: <symbol>` and traps; calling an extension's
`Init_<name>` from a harness printed `... rb_ext_ractor_safe` (measured). `link_harness.sh` proves one
stub of each kind aborts with the marker (`stubtest.cc`; `STUB_SYMBOL=` /
`DATA_STUB_SYMBOL=` choose which) and fails if either does not.

**If you link no extension object** (the system-library shape) there are no stubs and gate check 5
is N/A: record it that way. The same holds when the objects you link reference no
runtime symbol (`none: ... nothing to trap`). Your entire fidelity claim is then the
step-5 comparison, so it has to compare the deepest artifact the API exposes, not a
status code.

**A link error naming `rb_*`, `ruby_*`, `st_*` or `onig*`** means an object you link
references the runtime but is not in `EXT_OBJS`, so it got no stub: add it there, or do
not link what references it. If `gen_stubs.sh` warned that it fell back to `C_SYMBOLS`
(no runtime file to read), set `RUBY_RUNTIME=` to the `libruby.so` of the Ruby the oracle
runs on; the fallback stubs functions only, and data reads then go untrapped. A library
symbol undefined means `LIB` is incomplete or the system libraries are missing
(`LIBS_FROM_MK=1`).

---

## Step 5 — Gate it

Write the real-stack side from `resources/real_harness_template.rb`. It loads the gem from
`oracle/` (`PKG=$W/oracle/gems/<gem>-<ver>`; `REQUIRE=` when the feature to require is not
the gem name), reads the input as a BINARY String, and prints the same line. With
`EXT=<abs .so>` it swaps in a sanitized extension: it intercepts **both** `require` and
`require_relative` (a gem with precompiled builds first tries `require_relative
"3.3/<name>"`, then `require "<gem>/<name>"`), then **proves** the swap from
`/proc/self/maps`, and refuses to print a result (`EXT-NOT-SWAPPED`) if the gem's own `.so`
is mapped or no load was redirected. A non-matching `EXT_MATCH` was refused that way, and
plain and ASAN-swapped runs printed identical result lines (both measured). Set
`EXT_MATCH=` (a regex on the resolved path) when the gem loads several extensions and one
is yours, `EXT_MAP='<re>=<path>;...'` for several.

Its consumer calls live in an `ENTRIES` hash **keyed by the harness's `MODE` value**
(`default` when unset): one arm per entry point, called the way a user does, with no
options. Name each mode after the entry point it reaches (`MODE=file` -> the `file` arm).
That hash is the chain's contract: the campaign skill records each mode's `entry` as this
key, and the triage skill's `confirm.rb` uses the same hash unchanged, so the calls are
written once, here, where the gate proves they reach the native code. Then:

```sh
$R/gate.sh DIRECT=./out/plain/harness-fork \
    REAL="env PKG=$W/oracle/gems/<gem>-<ver> ruby real_harness.rb" \
    CORPUS=./corpus FIELDS="status err out_len out_hash" SOFT_FIELD=lossy SOFT_DROP="out_len out_hash" \
    MAP_SIZE=$(cat out/plain/map_size) MODES="MODE=file" JOBS=8
```

`MODES=` lists every entry point besides the default, in `campaign.sh`'s spelling; the
whole gate runs once per setting, exported to both sides, and fails if any mode fails.
`SOFT_DROP` must name **every field the oracle's loss can change**: a U+FFFD substitution
changes `out_len` as well as `out_hash`. `JOBS` runs seeds in parallel; ruby startup
dominates.

The gate's five checks, and what each one is for:

1. **Every seed reaches the library.** Exit 0 licenses nothing.
2. **Byte-exact agreement on the deepest artifact the API gives you**: the serialized
   document, every pixel, or for a callback-driven library the hashed event stream. This is
   what proves the *option* mirroring, not just the parse.
3. **Both arms populated.** The corpus must contain inputs the library rejects; truncate
   and bit-flip a few seeds. `MIN_ARMS=1` only for a target that cannot reject. The gate
   corpus also needs **one seed per branch of the mirrored dispatch** (a declared size over
   a ceiling, each entry point behind `MODE=`), or the gate proves nothing about the
   branches the corpus skill will later exercise.
4. **Coverage discriminates.** If a trivial input scores nearly as many tuples as a real
   one you are measuring init. **Unless** the decoders are in an uninstrumented system
   `.so` (`nm -D <lib.so> | grep -c sancov` is 0): then rejects out-score successes and the
   rule inverts. Check that before interpreting the numbers.
5. **The stubs stayed unreachable.** The gate reads `AFL-HARNESS-STUB` and
   `AFL-HARNESS-RUBYPATH` from stderr per seed.

**On a mismatch, read `references/oracle-ceiling.md` before touching the harness.** The
order there: a read of out-of-bounds or **uninitialised** memory in the target (run the
seed through the ASAN variant for the first; ASAN cannot see the second, which wants a
one-off MSan build of the library objects and the harness), then the gem's own lossy
transformations (`lossy=1` and the soft field), and only then your mirroring. A target bug
of the first kind is a finding: have the real side mark exactly those inputs `lossy=1` so
the gate stays honest, and write it down. Re-run the gate after the corpus skill has
produced a real corpus; a gate corpus is too small to find the oracle's ceiling.

**The Ruby side has a sensitivity ceiling of its own** (measured): a String shorter than
about 616 bytes is embedded in its GC slot rather than in a malloc block of its own, and
every String keeps a NUL terminator, so ASAN on the real side **cannot see** an over-read
of a small input String. Only the direct harness, with its exact-size copy, can, and Ruby
has no way to hand a gem an exactly sized external buffer. A seed whose ASAN report is an
over-read just past the harness's input copy, clean on the sanitized real side, is that
ceiling, not a fidelity failure. Name it in the write-up and in triage; do not "fix" the
harness to match.

Gate the `asan` variant too, with the sanitized extension swapped in and the sanitizer
runtime preloaded **inside `REAL=`**, never in front of `gate.sh`:

```sh
$R/gate.sh DIRECT=./out/asan/harness-fork CORPUS=./corpus FIELDS=... MODES=... \
    MAP_SIZE=$(cat out/asan/map_size) \
    REAL="env LD_PRELOAD=$($R/find_asan_rt.sh) PKG=$W/oracle/gems/<gem>-<ver> \
         EXT=$W/out/asan/<name>.so ruby real_harness.rb"
```

In front of `gate.sh` the runtime is preloaded into afl-showmap and the direct harness as
well: every seed is `NO-OUTPUT ... rc=86` and check 4 says `afl-showmap produced nothing`;
the gate names that cause. Its default `ASAN_OPTIONS` carry `detect_leaks=0` (ruby does
not free everything at exit) and the campaign's allocation ceiling
(`allocator_may_return_null=1`, `max_allocation_size_mb=$ALLOC_CAP_MB`), so a seed
declaring a huge allocation is refused the same way on both sides instead of aborting on
one. `real_harness.rb` adds `use_sigaltstack=0` itself, by re-exec, when it finds ASAN
loaded: without it every Ruby thread exit died in `AddressSanitizer: CHECK failed ...
unable to unmmap`, because ASAN munmaps Ruby's malloc'd per-thread signal stack
(measured). It is not set globally because the direct harness needs ASAN's alternate
stack to report stack overflows. The gate prints the first error line of whichever side
produced no output, so a wrong `EXT=`/`PKG=` path or a sanitizer abort is named rather
than counted; if **every** seed has no output, the command is broken, not the seeds.

---

## Step 6 — Smoke it, then prove it detects

Smoke first, self-test second. A smoke failure means fixing and rebuilding the harness,
and the self-test vouches only for the binary it ran against (the campaign skill flags a
harness newer than `selftest.txt` as stale). `smoke.sh` passes `SELFTEST=skip` to
`campaign.sh` for its own short run, because it judges the harness, not the detection.

### Smoke it: does the harness crash on its own account?

The gate runs the gate corpus, which is mostly valid input, so it never reaches the error
paths where a harness is most likely wrong. On the Node sibling, a harness that `memset` a
C++ object to zero crashed inside `std::string` on every decode **error** (43 phantom
SIGSEGVs in 15 seconds of fuzzing) while valid inputs worked perfectly, which is why it
survived the gate. A short run finds that in seconds; finding it after a campaign costs
the whole campaign.

```sh
$R/smoke.sh SMOKE_S=30 MODES="MODE=file" \
    HOSTSAN="env LD_PRELOAD=$($R/find_asan_rt.sh) PKG=$W/oracle/gems/<gem>-<ver> \
             EXT=$W/out/asan/<name>.so ruby real_harness.rb" [STRING_API=1]
```

It runs every seed through every sanitized fork harness, fuzzes each variant briefly (it
drives `campaign.sh` into `smoke/`, so the afl-fuzz setup is the campaign skill's), and
classifies each crash it saves. `MODES=` is the same list you gave the gate. It runs
`HOSTSAN` once on a seed first and stops (exit 2) if it prints no result line, since a
broken real-side command would otherwise make every crash `DIRECT-ONLY`. With `HOSTSAN`,
every crash is tried on the **real stack first**, because the harness may carry copies of
extension method bodies and `static inline` helpers (step 2), and a frame in `harness.cc`
can be a real bug in that copied code. `STRING_API=1` when the API takes a validated or
NUL-terminated String (`StringValueCStr`, a `valid_encoding?` check): crashes on input
it cannot carry are then `OUT-OF-SCOPE`.

The classes (`REAL`, `HARNESS-FRAME`, `DIRECT-ONLY`, `OUT-OF-SCOPE`, `UNVERIFIED`,
`PERSISTENT-ONLY`, `STATE`) and what to do about each are in `smoke.sh`'s header. It
exits 1 on `HARNESS-FRAME` (innermost project frame in the harness's own code) or
`DIRECT-ONLY` (crashes the harness, not the real stack, on input the API can express), and
2 when the smoke itself did not happen (no campaign `completed` or `walled`, one
`aborted` or `failed`, a variant not smoked, a broken `HOSTSAN`). It warns on execs/s
below 100 and stability below 90 %. **A `PASS` means the harness is not obviously wrong;
it does not mean it is right**; the gate and the self-test do that.

**A `DIRECT-ONLY` can be the String ceiling (step 5)**, not a harness bug: a library
over-read of a small input fires in the harness and is invisible to ASAN in ruby.
`smoke.sh` has no class for it. Before fixing the harness, read the report: an over-read
of the input block `run_one` allocated, on an input under ~616 bytes, is that case; hand
it to triage as a candidate finding with that reasoning, and fix the harness only for
anything else.

Without `HOSTSAN` a crash can only be called `UNVERIFIED`, so give it: "crashes only in
your harness, so your harness is wrong" is **false** under a sanitizer unless the real
side runs the same sanitizer. On the real side a wild segfault prints Ruby's own
`[BUG] Segmentation fault at 0x...` and aborts rather than an ASAN report; ASAN's own
checks still report normally.

Low stability has two known causes (both from the Node sibling): a harness that mirrors a
**context shared across calls** carries state between iterations by design and wants the
fork driver, and a library that seeds its hash tables from the **clock or pid** (a
parser's `gettimeofday ^ getpid` hash salt) jitters a few edges per run. The campaign
skill switches drivers on stability by itself.

### Then prove it detects

```sh
L=$(ls $W/out/asan/lib/*.a | tr '\n' ' ')
REBUILD="$R/rebuild_asan.sh EXT=$X OUT=$W/out MK=$W/out/asan/Makefile SRCDIR=$X \
         HARNESS=$W/harness.cc LIB='$L' EXTCONF_ARGS='<same as before>'"
$R/detect_selftest.sh FAULT_SRC=$X/<lib file>.c \
    FAULT_SED='/^parse_header(/,/^}/s|p\[n\] = 0;|p[n + 1] = 0; /* INJECTED */|' \
    REBUILD="$REBUILD" HARNESS=./out/asan/harness-fork CORPUS=./corpus \
    [SEED=corpus/<one that takes the faulted path>] | tee selftest.txt
```

Without this, "no crashes found" is indistinguishable from "detects nothing". The fault
must land **past an allocation boundary** (a 1-byte over-*read* into a larger buffer fires
nothing), and the seed must **reach** it: the script picks the largest non-empty seed that
reports `status=0` with `out_len>0`, which is often the wrong one, so pass `SEED=`. Anchor
`FAULT_SED` to the function (`/^Func/,/^}/`), because the same line exists in other
functions and the script prints where the fault landed for exactly that reason. The seed
must also take the **dispatch branch** the fault sits on; read the branch around the
faulted line before picking `SEED=`.

`REBUILD` is run with `eval`, twice (fault applied, then restore). Expand any list
**before** building the string and single-quote the result, as above; a `$(find ...)` left
inside single quotes reaches `eval` as a literal and the relink fails with an empty log.
`rebuild_asan.sh` takes `EXT=` (the directory holding `extconf.rb`) plus the arguments you
gave `build_ext.sh` and `link_harness.sh` (add `EXT_OBJS=`, `LIBS_FROM_MK=`, `EXTRA_LIBS=`
if you used them); it re-runs `build_ext.sh VARIANT=asan` there and relinks.

It **cannot** be used when `extconf.rb` extracts or patches the library during configure
(mini_portile2 recipes, anything under `ports/` or `tmp/`): the rebuild re-extracts the
tarball over your patch, and a gem may delete the build tree (and its `config.log`)
afterwards anyway. Rebuild that library out of tree from what `build_ext.sh` recorded:

```sh
$R/rebuild_vendored.sh RECIPE=$W/out/asan/vendor/<lib>-<ver> VARIANT=asan OUT=$W/out \
    DEST=$W/selftest/<lib>          # extract, apply the gem's patches, configure, make install
L=$(ls $W/out/asan/lib/*.a | grep -v lib<lib>.a | tr '\n' ' ')
REBUILD="make -C $W/selftest/<lib>/src -j6 install >/dev/null && $R/link_harness.sh VARIANT=asan \
         MK=$W/out/asan/Makefile SRCDIR=$X OUT=$W/out HARNESS=$W/harness.cc \
         LIB='$W/selftest/<lib>/install/lib/lib<lib>.a $L' LIBS_FROM_MK=1"
$R/detect_selftest.sh FAULT_SRC=$W/selftest/<lib>/src/<lib file>.c FAULT_SED='...' REBUILD="$REBUILD" ...
```

(Measured: the rebuilt library, with the gem's patches and the logged options, carried
the same coverage symbols as the extension's build. Both evaluation runs had to do this
by hand before the helper existed.) Only recipes with a `./configure` are supported; a
vendored library built from a source directory inside the gem (not a tarball) with its
own rules is not. That relinks the
asan harness against a different archive than the gate and smoke vouched for, so re-run
the asan gate on it afterwards. The same holds for every REBUILD: the
restore step relinks the asan harness, which counts as a harness change, so the asan gate
runs once more after the self-test (the map size may move by a few entries, which is
expected). The script removes its `<src>.injected` copy before the restore rebuild.

**Keep the self-test's output** (`| tee selftest.txt`, with its `PASS:` line): the
campaign skill refuses to run without it, because a campaign that finds nothing against a
harness that detects nothing is not a result. Re-run it whenever the harness is rebuilt.
The self-test's own restore relink leaves `out/asan/harness*` and `selftest.txt` in the
same second; that is fine, the campaign skill's `-nt` check compares nanoseconds and
`selftest.txt` is written last (measured: 11-13 ms later in both evaluation runs).

Then hand over: **derive-a-fuzzing-corpus-from-source** builds the seeds,
**run-a-fuzzing-campaign** runs the real campaigns and records how, and
**triage-fuzzing-findings** classifies what they find (its `confirm.rb` is the same
real-stack comparison, per entry point, with `PKG=` the same oracle gem).

---

## Traps that cost hours

Most build traps are checks inside `build_ext.sh`, `link_harness.sh` and the templates,
explained where they apply; `references/build-traps.md` has the mkmf and vendored-build
long form. afl-fuzz runtime symptoms (map size, `ASAN_OPTIONS`, `-m`, persistent mode not
engaging, `@@`, shared output directories) belong to **run-a-fuzzing-campaign**, whose
`campaign.sh` handles them. What is left:

| Symptom | Cause | Fix |
|---|---|---|
| ruby refuses the extension: `undefined symbol: __afl_area_ptr` | afl-clang-fast dropped its runtime from the `-shared` link (measured) | `build_ext.sh` links with plain clang; do not build by hand with `LDSHARED=afl-clang-fast` |
| second variant has no coverage, or asan objects in plain | mini_portile reused the first variant's cached library | `build_ext.sh` deletes `ports/<host>` and `tmp/`; pass `PKGROOT=` if it guessed the gem root wrong |
| `LeakSanitizer has encountered a fatal error` at every clean exit of the asan harness | data stubs in a writable segment; LSan scans them and faults on `PROT_NONE` (measured on a first version) | regenerate with the current `gen_stubs.sh` (read-only segment) |
| every real-side ASAN run dies at a thread exit: `CHECK failed ... unable to unmmap` | ASAN munmaps Ruby's per-thread signal stack (measured) | `use_sigaltstack=0`; `real_harness.rb` adds it by re-exec, so use the template |
| real side prints `[BUG] Segmentation fault` and no ASAN report | Ruby's own SIGSEGV handler | a crash all the same; reproduce on the direct harness for the stack |
| `Error: EXT-NOT-SWAPPED` | the gem loaded its `.so` by a path neither hook saw, or `EXT_MATCH` does not match it | find how the gem loads it; set `EXT_MATCH=`/`EXT_MAP=` |
| showmap says nondeterministic, AFL says stability 100 % | showmap prints exact counts, AFL buckets them | both are right; showmap locates, stability decides |
| Self-test: `REBUILD failed with the fault applied` | `FAULT_SED` mangled the code, or the injected statement does not compile | the script keeps the compiler log and the patched source in the workspace; read them |
