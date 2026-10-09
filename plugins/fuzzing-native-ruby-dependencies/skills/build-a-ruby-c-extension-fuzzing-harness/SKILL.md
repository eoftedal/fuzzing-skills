---
name: build-a-ruby-c-extension-fuzzing-harness
description: Build a direct AFL++ fuzzing harness for the C library behind a Ruby gem's C extension (a native gem built with mkmf / extconf.rb), bypassing ruby while executing the same machine code, and prove it is faithful (fidelity gate against an independently installed gem), detects injected faults, and does not crash on its own account. Use when asked to fuzz a Ruby gem's C extension, a native gem (a parser, image, compression or regex binding), or the C library a gem vendors or links; to harness the library behind a Ruby binding; or when fuzzing through the interpreter is too slow. The first of four skills - then derive-a-fuzzing-corpus-from-source, run-a-fuzzing-campaign, triage-fuzzing-findings.
---

# Build a direct fuzzing harness for a Ruby C extension

Goal: delete ruby from the loop while still executing **the same machine code** the
extension executes. A fast harness that tests something subtly different is worse than no
harness, so every step below ends in a check that it is still faithful.

`resources/` (`$R`, step 1) holds the scripts; every step names the one it uses, and every script's
header documents its knobs. `references/` holds the long versions of the rules with the
cases that produced them; read one only when a step points you at it or a check fails.
`references/build-traps.md` has the mkmf and vendored-build traps. Read this file with a
file reader, not `cat` into a terminal that truncates.

**Status.** Ported from the Node sibling's `build-a-nan-napi-fuzzing-harness`; tested on
Ruby 3.3.8 / clang 21 / AFL++ 4.33c / aarch64 Linux against three shapes (a gem over a system
library, one with vendored libraries, one whose parser is the extension's own C). Facts
marked *measured* come from those runs (`EVIDENCE.md`); rules from the Node sibling are about
the C library or the method, not the runtime. Your target's numbers are yours to measure.

**Layout convention** (the scripts assume it): a fuzz workspace `W` holding `fuzz.env`
(step 1), an independent `oracle/` install of the published gem, `out/<variant>/` for each build (`plain`, `asan`,
and `pristine` when you need it) with the snapshot `build_ext.sh` makes (`<name>.so`,
`Makefile`, `extconf.h`, `mkmf.log`, `obj/*.o`, vendored archives under `lib/`) plus
`harness`, `harness-fork`, `map_size` and `dict.afl`, and the gate corpus in `corpus/`. The gem
source you build lives elsewhere (`$W/src/<gem>-<ver>`, below); always pass `build_ext.sh`
an **absolute** `OUT=` into the workspace, because it runs from the extension directory.

**The whole path, for the common case** (library compiled into, or vendored by, the extension):

```sh
# 1  <this skill>/resources/init_workspace.sh W=/abs/fuzz PKG_NAME=<gem> PKG=/abs/fuzz/oracle/gems/<gem>-<ver>
cd $W && . ./fuzz.env                  # the first line of every later block
#    gem install --install-dir $W/oracle --platform ruby --no-document <gem> -v <ver>   (the REAL stack)
#    gem fetch + gem unpack into $W/src; append X=$W/src/<gem>-<ver>/ext/<name> to fuzz.env
# 2  (cd $X && $R/build_ext.sh VARIANT=plain OUT=$W/out ORACLE=$PKG GEM_PATH=$W/oracle); then
#    $R/find_boundary.sh out/plain/obj/*.o out/plain/lib/*.a                -> the function to call
# 3  the same build_ext.sh with VARIANT=asan                                -> out/asan/
# 4  harness.cc from $R/harness_template.cc, then for v in plain asan:
#    $R/link_harness.sh VARIANT=$v MK=out/$v/Makefile SRCDIR=$X OUT=$W/out \
#        LIB="out/$v/lib/lib<dep>.a" | EXT_OBJS="out/$v/obj/<file>.o" SHIM=shim.c LIBS_FROM_MK=1
# 5  real_harness.rb from $R/real_harness_template.rb; init_workspace.sh MODES= EXT_ASAN=;
#    corpus/ + $R/mkgate.sh; $R/gate.sh (plain, then asan)
# 6  $R/smoke.sh; then, once smoke passes (its fixes rebuild the harness, staling a self-test):
#    $R/detect_selftest.sh ... REBUILD=./rebuild.sh | tee selftest.txt
#    then: corpus skill -> run-a-fuzzing-campaign -> triage-fuzzing-findings
```

The order is **gate -> smoke -> self-test**. Smoke failures force harness fixes, and the
self-test vouches only for the binary it ran against, so running it before the smoke
means running it twice. After any harness change, re-run the gate too.

---

## Step 1 — Triage, before building anything

**The workspace file first.** Each tool call is a fresh shell, so `fuzz.env` holds the
paths and settings, and the scripts read it as defaults (an explicit argument wins).
Write it; **every** later block starts with `cd $W && . ./fuzz.env`, `$W` spelled out:

```sh
<this skill>/resources/init_workspace.sh W=/abs/fuzz PKG_NAME=<gem> PKG=/abs/fuzz/oracle/gems/<gem>-<ver>
```

It sets `R`, `RC`, `PKG` and the rest (`REAL` once `real_harness.rb` exists), then runs
`preflight.sh` (toolchain, GNU sed, `timeout`, core_pattern). Re-run it with just the new
keys as they become known (`MODES=`, `EXT_ASAN=`, and after step 5).

**The oracle**, an independent install of the published gem, built from source, with its
dependencies:

```sh
cd $W && . ./fuzz.env
gem install --install-dir $W/oracle --platform ruby --no-document <gem> -v <ver> [-- <extconf args>]
```

`--platform ruby`: a precompiled platform gem is someone else's build. Whatever follows
`--` goes to `extconf.rb`: pass the **same** string as `EXTCONF_ARGS=` to every
`build_ext.sh` run, or the oracle and the harness are different programs. Why each:
`references/build-traps.md`, "Before building".

**The source you build** is a separate copy, never the oracle's directory (`build_ext.sh`
writes into it), unpacked from the **published** `.gem`, not a git clone:

```sh
cd $W && . ./fuzz.env && mkdir -p src && cd src
gem fetch <gem> -v <ver> --platform ruby && gem unpack <gem>-<ver>.gem --target=$W/src
ls $W/src/<gem>-<ver>/ext/*/extconf.rb      # one directory per extension; X is the one you fuzz
```

`X` (that directory) and `EXTCONF_ARGS` are not `init_workspace.sh` keys: append
`X=<abs dir>` and `EXTCONF_ARGS="<same as the oracle>"` lines to `fuzz.env` by hand.
`extconf.rb` may need build-time gems (mini_portile2); the oracle has them, so run
`build_ext.sh` with `GEM_PATH=$W/oracle` and `ORACLE=$PKG` (step 3a).

**Is a direct harness the right tool here?** If every call costs
milliseconds *at the smallest input the API accepts* (a renderer, a default-level compressor), or everything
interesting is in a system library that cannot be rebuilt instrumented, it buys less than
it costs to keep faithful: say so and stop. A system library that can be rebuilt is step
3b's static archive, the common route. Not that case: an input-chosen cost (bound it, step 4), and a
slow entry point beside a cheap parser of the same bytes (harness the parser as a mode).
The speed-up over the interpreter is a given: do not measure or report it.

Three things end this skill's build route early (long form: `references/build-traps.md`,
"Gems this build route does not cover"):

* **No `ext/` and no `extconf.rb`** (an FFI gem): nothing to build, and `build_ext.sh` /
  `link_harness.sh` do not apply; say so before improvising.
* **A Rust extension** (`rb_sys`, `create_rust_makefile`): not covered by this skill.
* **The extension does not build on this Ruby**: install the Ruby the gem supports. Never
  patch the gem.

Then answer four questions, each one command (long form: `references/build-traps.md`,
"Before building").

1. **Where is the glue, and is it hand-written or generated?**
   ```sh
   cd $W && . ./fuzz.env
   grep -rln --include='*.c' --include='*.cc' --include='*.cpp' --include='*.h' \
        -e 'ruby\.h' -e 'Init_' $X
   grep -rlim1 "swig\|automatically generated\|DO NOT EDIT" $X
   ```
   Generated glue (SWIG) has no binding-free function: the boundary is the library call
   each wrapper makes and the risk is what `Init_<name>` installs (step 4, layer 3).
2. **Is the library compiled into the extension, vendored as an archive, or a system
   `.so`?**
   ```sh
   cd $W && . ./fuzz.env
   grep -nE 'mini_portile|MiniPortile|pkg_config|have_library|find_library|dir_config|use-system-libraries' $X/extconf.rb
   ldd $(find oracle -name '<name>.so' | head -1) | grep -vE 'libc|libm|libruby|libgcc|linux-vdso|ld-linux|libpthread'
   ```
   Library `.c` beside the glue is compiled in, a mini_portile2 recipe is a vendored
   archive, and a `-l<dep>` system library is step 3b: **state that scope**.
3. **Which optional features did the build detect?** After the plain build (step 3):
   ```sh
   cd $W && . ./fuzz.env
   $R/lift_flags.sh out/plain/Makefile SRCDIR=$X              # every -D, $defs included
   grep -E '^#define (HAVE|USE|WITH)_' out/plain/extconf.h   # optional: only with create_header
   grep -- '-------------------- no' out/plain/mkmf.log      # optional: every have_* that said no
   ```
   A missing `-dev` package turns a decoder into dead code without failing `extconf.rb`
   (`references/build-traps.md`, "Feature detection").
4. **Which binary does the gem actually load?** Ask the process, not the directory:
   ```sh
   cd $W && . ./fuzz.env
   GEM_HOME=$W/oracle GEM_PATH=$W/oracle ruby -e 'require "<feature>"
     puts File.readlines("/proc/self/maps").map { _1.split(" ", 6)[5].to_s.strip }.grep(/oracle.*\.so\z/).uniq'
   file <that .so>
   ```
   A path under `gems/<gem>-<ver>-<platform>/` means the platform gem won: reinstall (a
   loading platform gem, installed elsewhere, is a second oracle to gate against).

---

## Step 2 — Find the boundary

The deepest function the extension calls that touches no Ruby API itself.

**Look for GVL-released work first.** A function passed to `rb_thread_call_without_gvl`
(or `rb_nogvl`) may not touch Ruby objects, so it is the boundary when it exists (and runs
without the GVL, which matters for triage).

```sh
cd $W && . ./fuzz.env
grep -rn 'rb_thread_call_without_gvl\|rb_nogvl' $X/
$R/find_boundary.sh out/plain/obj/*.o out/plain/lib/*.a           # rank EVERY object
objdump -dr <candidate.o> | awk '/>:$/{f=$2} /R_.*(rb_|ruby_)/{print f}' | sort | uniq -c   # which functions own the refs?
```

The ranking needs objects (step 3's plain build first) and counts an archive as a whole
(`ar x` it to rank its members). The lowest count is where to start reading, not the answer: the criterion is *a
function on your input path whose own body is Ruby-free* (`references/boundary-shapes.md`).

Prefer a function that already does the dispatch and the option plumbing, so the gem's
format sniffing and limit checks are *its* code, not your copy. Several entry points over
one engine (string vs IO vs file, parse vs parse_stream) go behind an **environment
variable**, never an input byte, so a corpus file replays unchanged on the real stack.
**Decide the modes now, before the first gate**, and record them (`$R/init_workspace.sh
MODES="MODE=file"`): a mode added later rebuilds the harness and reruns every check. Keep a mode only if it reaches library code
the default does not, and stop at two or three. Thin wrappers over the same call are one
mode: fuzz the richest and say so. A mode that cannot reject its input (a compressor) gets
`:min_arms=1` in the gate's `MODES=` spec, so check 3 stays strict for the default mode.

For generated glue, skip the ranking: `grep -n '<libraryEntryPoint>(' $X/<generated>.c`.

**When there is no single Ruby-free function** (expect it more often than not), the
boundary is one of four shapes. Say which you chose; the recipes are in
`references/boundary-shapes.md`.

* **The parser builds Ruby objects as it goes** (typical over a system library): the
  library's C API driven the way the gem drives it, every event serialised; link no
  extension object (measured).
* **The parser IS the extension's own C**: link its objects (`EXT_OBJS=`) and define only
  the runtime calls its path makes in a shim (`$R/ruby_shim_template.c`,
  `link_harness.sh SHIM=shim.c`), leaving the rest as stubs (`references/ruby-shim.md`).
  The shim also defines the globals of objects you do not link (class VALUEs, IDs set in
  `Init_<name>`: not libruby's, so never stubbed) and, for a handler, a recording `rb_funcall`.
* **The work is a method on a `TypedData`-wrapped object**: copy the method body into the
  harness minus its `rb_*` calls, naming the file and lines; note the drift risk.
* **The dispatch is in Ruby** (`lib/**/*.rb` picks the method, the buffer, the chunking):
  drive the library's C API exactly as the Ruby does, re-chunking included.

---

## Step 3 — Build the variants

Two variants now, one at a time, each snapshotted into `out/<variant>/`: `plain`
(throughput) and `asan` (bug finding). A third, `pristine` (ASAN, no AFL instrumentation),
is the control for "did my instrumentation invent this bug?": build it when you have a
crash to cross-check, not before.

Every AFL variant gets `-include undef_fuzzmode.h` (`build_ext.sh` and `link_harness.sh`
add it), because libraries compile checks **out** under the wrapper's
`FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION`, and the instrumented library then accepts what
the shipped extension rejects (`references/build-traps.md`). Each AFL build also writes
`out/<variant>/dict.afl` (`AFL_LLVM_DICT2FILE`: the constants the instrumented code compares
against), which the corpus skill merges into the campaign's dictionary.

### 3a. Library compiled into, or vendored by, the extension (the common case)

```sh
cd $W && . ./fuzz.env && cd $X
for v in plain asan; do
  $R/build_ext.sh VARIANT=$v OUT=$W/out ORACLE=$PKG GEM_PATH=$W/oracle \
      EXTCONF_ARGS="$EXTCONF_ARGS" [PKGROOT=<gem root>]
done
```

Its guards (`out/<v>/probes.diff`, cached mini_portile builds, `REQUIRE=` / `LOAD_PRE=`):
`references/build-traps.md`, "What build_ext.sh guards against".

Then `$R/init_workspace.sh EXT_ASAN=$W/out/asan/<name>.so`. The `.so` keeps its file name,
because ruby calls `Init_<basename>`. When the script fails, read `out/<v>/build.log`,
`mkmf.log` and `references/build-traps.md`.

### 3b. Library is a system library: rebuild it as an instrumented static archive

Still build the extension (3a: the real side's sanitized `.so`). Take the library's upstream
source **at the version and patches the distro ships** (how: `references/build-traps.md`,
3b, "Which source"), because the real side runs the system `.so`. Build out of tree:

```sh
cd $W && . ./fuzz.env       # autotools; cmake and why: references/build-traps.md, 3b
for v in plain asan; do mkdir -p $W/lib-build/$v $W/out/$v/lib && (cd $W/lib-build/$v &&
  ([ $v = asan ] && export AFL_USE_ASAN=1; CC=afl-clang-fast \
   CFLAGS="-O2 -g -fPIC -include $R/undef_fuzzmode.h" \
   $W/src/<lib>-<ver>/configure --disable-shared --enable-static && make -j6) &&
  cp src/.libs/lib<x>.a $W/out/$v/lib/); done
```

Link with `LIB=out/$v/lib/lib<x>.a EXTRA_FLAGS=-I$W/src/<lib>-<ver>/include` (step 4).
Export `AFL_LLVM_DICT2FILE=$W/out/$v/dict2file.raw` into that configure/make, after
`build_ext.sh`; `link_harness.sh` merges it into `dict.afl`. No static build: the shared-object route (`build-traps.md`, 3b).

---

## Step 4 — Write the harness

Start from `$R/harness_template.cc`; its `#error` lines keep it from compiling until you
have filled in each marked section. It already copies the input into an exactly
sized `malloc`, reads modes and ceilings from the environment, prints the one-line
`in_len= status= err= out_len= out_hash= lossy= invariant=` contract, frees its init state,
traps with `AFL-HARNESS-RUBYPATH` on a binding-only branch, and builds both drivers. For a **streaming** API,
hash every output chunk concatenated; for a **callback-driven** library, serialise every
event with every argument the real handlers read and hash the stream (both templates
sketch each), on error too: the real template's rescue branch hashes `COLLECTED`, what
the arm gathered before the raise, so the harness hashes its partial stream. On success
hash the output even when empty; `out_hash=0` only on the error path with nothing
collected. Wrap the extension's C headers in `extern "C" { }` if they do not do it. For the
copy-the-method shape, keep the template's driver tail and replace its input sections
wholesale, deleting their `#error` lines.

What you add is the mirroring of **four layers**, which live in different files. The
checklist; the long form with cases is `references/four-layers.md`.

1. **The object the runtime owns.** Prefer a library factory. Else copy the struct
   verbatim from the `.c` file, `calloc` it as `ZALLOC` does, set every field `initialize`
   sets, and never `memset` a C++ object.
2. **The option layer, and the dispatch.** Mirror the defaults from `lib/**/*.rb` and what
   Ruby decides (*which* native method runs, *how big a buffer* it gets), in the same order.
   Ask the runtime for limits and tables at build time, never quote one, and `#error` when
   the macro is missing:
   `EXTRA_FLAGS="-DRUBY_LONG_MAX=$(ruby -rrbconfig/sizeof -e 'p RbConfig::LIMITS["LONG_MAX"]')"`.
   Ruby's encoding table, recovering parsers and C++ constness: layer 2 of the reference.
   Include only the library's headers; no `ruby.h` when no extension object is linked.
3. **Process-global state `Init_<name>` installs.** Custom allocators (mirror
   `ruby_xmalloc`/`ruby_xfree` with `malloc`/`free` and a comment: those names are stubs
   here), error handlers, and the **full handler set** of a callback-driven library, returning
   what the real handlers return. Runtime-only branches in a mirrored hook must **trap**.
   ```sh
   cd $W && . ./fuzz.env
   grep -rn "Init_[A-Za-z0-9_]*\s*(\|rb_define_method\|rb_define_alloc_func" $X/
   grep -rniE "MemSetup|SetAllocator|ruby_xmalloc|ruby_xfree|_default\(|SetErrorFunc" $X/
   ```
4. **What the method does after the boundary returns.** Read the whole method and mirror
   its post-processing; any `rb_raise` longjmps out, so stop where the real method stops.

Three more things to check (`references/four-layers.md`, "How the bytes are delivered"):

* **How the bytes are delivered.** `RSTRING_PTR`/`RSTRING_LEN` or `StringValuePtr`: copy
  exactly. `StringValueCStr` raises on an embedded NUL: mirror it (status=1,
  `err=ArgumentError`). A transcode (`rb_str_conv_enc`, `#encode` in `lib/`): mirror it or
  mark those inputs lossy. **Several byte arguments** go in one file, framed with a
  separator the values cannot carry (NUL before a `StringValueCStr`, else a length
  prefix), split identically on both arms and documented at the top of `harness.cc`. A
  free-form string argument whose large value space selects code paths (an encoding name,
  an options string) is framed into the input too (NUL or newline separated), not made a
  MODE: modes are for a handful of entry points.
* **NUL termination.** Add none (a read to NUL past the input is a finding) unless the
  extension takes the String with `strlen`: then exactly one, as Ruby keeps.
* **Make the library actually do the work.** An open is not a decode: force it, record
  something only real work could produce, and reset only what is safe to reset.

**The `err` field is one token, identical on both sides**: the library's numeric code
when the gem exposes one (an exception `#code`), else the Ruby exception class
(`ArgumentError`, `NoMemoryError`, `RangeError`), else the library's error name or message
with spaces replaced by `_`. Never a whole Ruby message: many embed the input position
(`line 1 column 4`; measured), so use a stable field (`#problem`), else, when the class
alone would collapse dozens of errors, the message cut at its position marker (` at line`,
` [file:`). The corpus skill steers by it.

**Attacker-declared sizes and work get no cap by default.** Mirror Ruby's own tokens
(`ArgumentError`, `RangeError`, `NoMemoryError`; measured) and the gem's own bound, and
let `ALLOC_CAP_MB` bound the run. The opt-in `ALLOC_CEIL=<bytes>` / `WORK_CEIL=<units>`
apply identically on both arms, only at the declared field (`err=alloc-ceiling` /
`err=work-ceiling`), never as a global `malloc` wrap. An unbounded input-controlled work
factor is itself a finding. Long form: `references/four-layers.md`, layer 2.

Then link, once per variant:

```sh
cd $W && . ./fuzz.env
$R/link_harness.sh VARIANT=plain MK=out/plain/Makefile SRCDIR=$X OUT=$W/out \
    [LIB="out/plain/lib/lib<dep>.a"] [EXT_OBJS="out/plain/obj/<file>.o"] [SHIM=shim.c] [LIBS_FROM_MK=1]
```

`LIB=` is what the boundary's code is in: the vendored or rebuilt archive, or the library
`.o` files the extension compiles itself (never the glue's). `EXT_OBJS=` is extension
objects you link because the boundary or a Ruby-free helper lives in them; stubs are
generated from exactly these. At least one of the two is required. `SHIM=` is the shim
(step 2; compiled without AFL instrumentation). `LIBS_FROM_MK=1` appends the extension's
own system libraries (minus libruby); `EXTRA_LIBS=` adds more.

It compiles with mkmf's include paths and `-D` macros (a `HAVE_*` macro changes struct
layouts), generates a trapping stub for **exactly** each libruby symbol `EXT_OBJS` leaves
undefined (data symbols included), and writes `harness`, `harness-fork` and `map_size`.
Stubs and link errors: `references/build-traps.md`, "Linking the harness".

**If you link no extension object**, or the objects reference no runtime symbol, there are
no stubs and gate check 5 is N/A: record it that way. The fidelity claim is then the step-5
comparison alone, so it must compare the deepest artifact the API exposes.

---

## Step 5 — Gate it

Write the real-stack side from `$R/real_harness_template.rb`. It loads the gem from
`oracle/` (`PKG=$PKG`; `REQUIRE=` when the feature to require is not
the gem name), reads the input as a BINARY String, and prints the same line. With
`EXT=<abs .so>` it swaps in a sanitized extension and **proves** the swap from
`/proc/self/maps`, or prints `EXT-NOT-SWAPPED` instead of a result (`EXT_MATCH=`,
`EXT_MAP=`: `references/oracle-ceiling.md`, "The real side's extension swap").

Its consumer calls live in an `ENTRIES` hash **keyed by the harness's `MODE` value**
(`default` when unset): one arm per entry point, called the way a user does, with no
options. Name each mode after the entry point it reaches (`MODE=file` -> the `file` arm).
That hash is the chain's contract: the campaign's `entry` column is its key, and triage's
`confirm.rb` pastes it unchanged, so the calls are written once, where the gate proves
they reach the native code.

**The gate corpus.** Write `corpus/` with one valid sample per entry point and dispatch
branch, then add truncations and flips of them (the rejecting arm:
`references/oracle-ceiling.md`, check 3); 15 to 40 seeds:

```sh
cd $W && . ./fuzz.env
$R/mkgate.sh OUT=./corpus SAMPLES="corpus/<a> corpus/<b>"
$R/gate.sh DIRECT=./out/plain/harness-fork CORPUS=./corpus MAP_SIZE=$(cat out/plain/map_size) JOBS=8
```

`REAL`, `FIELDS`, `SOFT_*` and `MODES` come from `fuzz.env`; by hand the real side is
`$REAL <file>` after sourcing it (a bare `ruby real_harness.rb` lacks `PKG`). `MODES` lists every entry
point besides the default, in `campaign.sh`'s spelling; the whole gate runs once per
setting, exported to both sides, and fails if any mode fails. `SOFT_DROP` must name
**every field the oracle's loss can change** (a U+FFFD substitution changes `out_len` too).
A seed that crashes both sides is `CRASHES-BOTH`, a finding: move it to `crashers/` with a
row in `crashers.summary.tsv`. Seeds in `crashers/` are skipped as `known-crasher`.

The gate's five checks (long form: `references/oracle-ceiling.md`, "The five checks"):

1. **Every seed reaches the library.** Exit 0 licenses nothing.
2. **Byte-exact agreement on the deepest artifact**: it proves the option mirroring.
3. **Both arms populated**, and one seed per dispatch branch; `MIN_ARMS=1` only if nothing rejects.
4. **Coverage discriminates**, inverted when the decoders are in an uninstrumented system `.so`.
5. **The stubs stayed unreachable**: no `AFL-HARNESS-STUB` / `AFL-HARNESS-RUBYPATH` on stderr.

**On a mismatch, read `references/oracle-ceiling.md` before touching the harness**: first a
read of out-of-bounds or uninitialised memory in the target (a finding: mark exactly those
inputs `lossy=1` on the real side and write it down), then the gem's own lossy
transformations, only then your mirroring. Re-run the gate on the corpus skill's real
corpus (the asan re-gate over `corpus-min` skips `known-crasher` seeds itself); a gate
corpus is too small to find the oracle's ceiling.

**ASAN on the Ruby side cannot see an over-read of a small input String** (measured): an
over-read just past the harness's input copy, clean on the sanitized real side, is that
ceiling, not a fidelity failure (`references/oracle-ceiling.md`, section 2).

Gate the `asan` variant too. For a sanitized `DIRECT` the gate uses `REAL_ASAN`, which
swaps in `EXT_ASAN` and preloads the sanitizer runtime **inside** the real command; never
preload it in front of `gate.sh` (it reaches afl-showmap and the direct harness, and every
seed is `NO-OUTPUT ... rc=86`):

```sh
cd $W && . ./fuzz.env
$R/gate.sh DIRECT=./out/asan/harness-fork CORPUS=./corpus MAP_SIZE=$(cat out/asan/map_size)
```

**Over a system library (3b)** `REAL_ASAN` cannot see an overflow inside the uninstrumented
system `.so`: the write-up must say so (`references/oracle-ceiling.md`).

The gate's default `ASAN_OPTIONS` and the `use_sigaltstack=0` `real_harness.rb` adds:
`references/build-traps.md`, "ASAN in ruby", with what it means when **every** seed has no output.

---

## Step 6 — Smoke it, then prove it detects

Smoke first, self-test second (the order above).

### Smoke it: does the harness crash on its own account?

The gate corpus is mostly valid input, so the gate never reaches the error paths where a
harness is most likely wrong; a short fuzz run does, in seconds.

```sh
cd $W && . ./fuzz.env
$R/smoke.sh SMOKE_S=30 [STRING_API=1]
```

`MODES` and `HOSTSAN` (`REAL_ASAN`; without it a crash can only be `UNVERIFIED`) come from
`fuzz.env`; `STRING_API=1` when the API takes a validated or NUL-terminated String.
It replays one crash per site on the real stack, seconds each, so run it detached or give
the tool call a generous timeout. It exits 1 on `HARNESS-FRAME` or `DIRECT-ONLY`, 2 when the smoke did not happen; the
classes are in `smoke.sh`'s header, the rest in `references/smoke.md`. **A `PASS` means the
harness is not obviously wrong, not that it is right.** A `DIRECT-ONLY` over-read of the
input block on an input under ~616 bytes is the String ceiling (step 5). `REAL` and
`PERSISTENT-ONLY` crashes land in `crashers/`, one representative per site, with a row in
`crashers.summary.tsv`, where triage reads them: nothing to copy. Stability in the low 90s from a library's caches is
benign (the campaign's fork fallback handles it).

### Then prove it detects

Write `rebuild.sh` once in the workspace, sourcing `fuzz.env`, and pass `REBUILD=./rebuild.sh`.
Pass it what you linked with, and never discard its output (`detect_selftest.sh` shows it
on failure); every form, the system library's included: `references/selftest-rebuild.md`.

```sh
cd $W && . ./fuzz.env
cat > rebuild.sh <<'EOF'
#!/bin/bash
cd "$(dirname "$0")" && . ./fuzz.env || exit 1
exec $R/rebuild_asan.sh EXT=$X OUT=$W/out MK=$W/out/asan/Makefile SRCDIR=$X HARNESS=$W/harness.cc \
    EXTCONF_ARGS="$EXTCONF_ARGS" LIB="$(ls $W/out/asan/lib/*.a | tr '\n' ' ')"   # vendored archive
#   shim shape, in place of LIB=: EXT_OBJS="$W/out/asan/obj/<file>.o" SHIM=$W/shim.c LIBS_FROM_MK=1
EOF
chmod +x rebuild.sh
$R/detect_selftest.sh FAULT_SRC=$X/<lib file>.c \
    FAULT_SED='/^parse_header(/,/^}/s|p\[n\] = 0;|p[n + 1] = 0; /* INJECTED */|' \
    REBUILD=./rebuild.sh HARNESS=./out/asan/harness-fork CORPUS=./corpus \
    [SEED=corpus/<one that takes the faulted path>] | tee selftest.txt
```

Without this, "no crashes found" is indistinguishable from "detects nothing". The fault
must land **past an allocation boundary** (a 1-byte over-*read* into a larger buffer fires
nothing), anchored to its function (`/^Func/,/^}/`), and `SEED=` must **reach** it on the
**engine or dispatch branch** it sits on (a pattern that selects another engine misses it;
the script's own pick is often wrong). It can run for minutes: run it detached or with a
generous timeout.

`rebuild_asan.sh` **cannot** rebuild a library built outside `build_ext.sh` (3b's system
library, or one mini_portile2 extracts or patches during configure): `rebuild.sh` then
makes that tree and relinks (`references/selftest-rebuild.md` has both).

**Re-run the asan gate after the self-test**: its restore step relinks the asan harness
(`references/selftest-rebuild.md`, "Re-gate afterwards").

**Keep the self-test's output** (`| tee selftest.txt`, with its `PASS:` line): the
campaign skill refuses to run without it, because a campaign that finds nothing against a
harness that detects nothing is not a result. Re-run it whenever the harness is rebuilt.

Then hand over: **derive-a-fuzzing-corpus-from-source** builds the seeds,
**run-a-fuzzing-campaign** runs the real campaigns and records how, and
**triage-fuzzing-findings** classifies what they find (its `confirm.rb` is the same
real-stack comparison, per entry point, with `PKG=` the same oracle gem).

---

## Traps that cost hours

Most build traps are checks inside the scripts and templates; afl-fuzz runtime symptoms
belong to **run-a-fuzzing-campaign**'s `campaign.sh`. The rest, by symptom (the real side's
`[BUG]` segfault, `EXT-NOT-SWAPPED`, a self-test `REBUILD failed`, more):
`references/build-traps.md`, "More symptoms that cost hours". The one that costs most:

| Symptom | Cause | Fix |
|---|---|---|
| ruby refuses the extension: `undefined symbol: __afl_area_ptr` | afl-clang-fast dropped its runtime from the `-shared` link (measured) | `build_ext.sh` links with plain clang; do not build by hand with `LDSHARED=afl-clang-fast` |
