# Build traps: what `build_ext.sh` guards against, and what it cannot

`resources/build_ext.sh` encodes everything in "Getting the compiler into an mkmf build"
and "Configure probes fail silently under clang". Read this when the script fails, when you
must build by hand (an extension whose library has its own build system that ignores the
environment), or when a variant behaves wrongly. The first two sections are step 1's long
form.

Measured on Ruby 3.3.8 (Ubuntu 26.04 package), clang 21, AFL++ 4.33c, aarch64 Linux, with
a gem over a system library and a gem with vendored libraries (several, via
mini_portile2), unless a line says otherwise.

## Before building: the oracle and the source copy

* **`--platform ruby` on the oracle install.** A precompiled platform gem
  (`<gem>-<ver>-aarch64-linux-gnu`, `-x86_64-linux`) ships someone else's build of the
  extension and of every vendored library, a different back end from the one your harness
  links. Anything after `--` goes to `extconf.rb` (`--use-system-libraries`,
  `--with-<lib>-dir=`); pass the **same** string as `EXTCONF_ARGS=` to every
  `build_ext.sh` run, or the oracle and the harness are different programs.
* **Runtime dependencies are installed with the oracle.** `real_harness.rb` activates the
  gem's spec by path (`PKG=$W/oracle/gems/<gem>-<ver>`) and points the gem path at
  `oracle/` unless `GEM_PATH` is set, so its runtime dependencies must resolve there
  (measured on a gem that also ships as a Ruby default gem: the oracle copy is the one
  activated).
* **The source you build is a separate copy**, never the oracle's directory:
  `build_ext.sh` writes a Makefile and objects into the extension directory and deletes
  cached vendored builds under the gem root. Unpack the **published** `.gem` rather than a
  git clone: it is exactly what the oracle compiled, and a clone often lacks generated
  sources the release ships (a parser generated at `rake` time).
* **Build-time gems.** `extconf.rb` may need gems of its own: a gem that vendors its
  libraries via mini_portile2 does `gem "mini_portile2"`, and from the unpacked tree it
  failed with `Could not find 'mini_portile2' (~> 2.8.2)` (measured). They are runtime
  dependencies, so the oracle install has them: run `build_ext.sh` with
  `GEM_PATH=$W/oracle`, and with `ORACLE=$W/oracle/gems/<gem>-<ver>` so every configure
  probe is compared with the oracle's (below).

The four triage questions, long form:

* **Generated glue** (SWIG: `SWIGEXPORT`, `_wrap_` functions) has no binding-free function
  and nothing to link from the extension: the boundary is the library call each wrapper
  makes, and the risk is the state `Init_<name>` installs. Hand-written glue *may* have
  one; step 2 settles it.
* **Where the library lives.** Library `.c` files beside the glue in `ext/<name>/`:
  compiled in, its objects land in `out/<v>/obj/`. A mini_portile2 recipe or a configure
  step that builds a static library: a vendored archive, which `build_ext.sh` copies to
  `out/<v>/lib/`. A `-l<dep>` against a system library: instrument the extension, accept
  the system library as uninstrumented or rebuild it (step 3b), and state that scope
  (step 5's check 4 reads differently then).
* **Feature macros outside `extconf.h`.** An extconf without `create_header` writes no
  `extconf.h` at all and puts its macros in `$defs`/`$CPPFLAGS` (the Makefile's `-D`
  list); `lift_flags.sh out/plain/Makefile SRCDIR=$X` prints them all, which is why it is
  the first command of question 3 and the greps are extras. An extconf that ends with
  `make clean` (or similar) may leave no `mkmf.log` in the snapshot; `build_ext.sh` then
  compares its probes with the oracle's `gem_make.out` and says so. A gem over a system
  library may make one `pkg_config` probe and nothing else, so `mkmf.log` holds no `no`
  line even when it exists (each seen on an evaluation run).
* **A precompiled gem that loads** is still an asset for a second comparison: install it
  into another directory and gate against it later (`oracle-ceiling.md`, "Comparison
  strength").

## Gems this build route does not cover

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

## What build_ext.sh guards against

One entry per guard SKILL.md step 3a lists; the sections below have the mechanics.

* **Variants.** `plain` and `asan` now; `pristine` (ASAN, no AFL instrumentation) only when
  a crash needs the cross-check (on five Node evaluation targets it was built every time
  and used on none).
* **The compiler at both stages.** While `extconf.rb` runs: `CC`/`CXX` and
  `AFL_USE_ASAN` in the environment, the flags through `--with-cflags` (mkmf ignores an
  environment `CFLAGS`, measured, but vendored recipes read only the environment, so both
  are set). Then `make CC= CXX= ARCH_FLAG="<sanitizer flags>"` for the extension's own
  TUs, because mkmf writes Ruby's own compiler into the Makefile.
* **Configure probes compared with the oracle's.** mkmf's flag probes compile with
  `-Werror`, and under clang 21 Ruby 3.3's own `ruby.h` warns, so every such probe failed
  and was silently dropped: on one target a vendored library's include path, which then
  broke the build with a vendored header not found (measured). `build_ext.sh` silences
  those clang warnings and, with `ORACLE=`, diffs every probe in the variant's `mkmf.log`
  against the oracle's gcc-built one; any difference is a FAIL (`out/<v>/probes.diff`).
* **The link.** Plain `clang -shared` with the AFL runtime appended to `LIBS` inside the
  Makefile: afl-clang-fast filters `afl-compiler-rt.o` out of a `-shared` link even when
  `LIBS` names it (measured: the `.so` had no `__afl_area_ptr` and ruby refused it).
* **Cached mini_portile builds** (`ports/<host>/`, the `ports/*.installed` markers and
  `tmp/`, under the gem root and the extension dir) are deleted first, or the second
  variant silently links the first variant's library; a leftover marker alone made a gem
  skip its vendored library build (measured).
* **Downloaded tarballs** are kept in `out/vendor-archives/` and put back before each
  build: a gem may delete `ports/` including `ports/archives/`, and the second variant
  then re-downloaded the library (measured; offline it would have failed).
* **Everything vendored is snapshotted right after `extconf.rb`**, because a gem's
  Makefile may delete the vendored install trees, archives AND headers, once the extension
  is linked (measured: before this, `link_harness.sh` failed on a vendored header not
  found and `LIBS_FROM_MK=1` on a missing archive, in two independent evaluation runs).
  `out/<v>/ports/<lib>/<ver>/{include,lib}` holds the install trees and the snapshot
  Makefile is rewritten to point there, so `lift_flags.sh` and `LIBS_FROM_MK=1` see this
  variant's own copies (the originals are shared by every variant, whichever built last).
  `out/<v>/vendor/<lib>-<ver>/` records each recipe (mini_portile's configure options, the
  tarball, the gem's patches in order) for the self-test's out-of-tree rebuild
  (`rebuild_vendored.sh`, `selftest-rebuild.md`).
* **Checks after the build.** The AFL runtime is in the `.so`, the **library** objects or
  archives carry coverage symbols, ASAN symbols are present when they should be, and
  **ruby can load the result**: standalone, or, when its `Init_` needs the gem's own Ruby
  first (`cannot load such file -- <gem>/version`, then `uninitialized constant
  <Gem>::<Class>` for a class `lib/` defines first; measured), through the gem's own
  `require` with this `.so` placed where `lib/` expects it and verified mapped (`REQUIRE=`
  / `LOAD_PRE=` when the defaults do not fit; "Two checks after every build" below). It
  lists the system libraries the `.so` links as uninstrumented (measured: all variants of
  a system-library target built, verified and loaded).
* **`lift_flags.sh` drops `-D` macros whose value contains spaces or quotes** (a string
  macro holding the patch list) and names them on stderr: they cannot survive the word
  splitting of the compile line, and cut in half they warned on every compile.
* **The `.so` keeps its original file name**, because ruby calls `Init_<basename>`.

## Getting the compiler into an mkmf build

```sh
CC=afl-clang-fast CXX=afl-clang-fast++ CFLAGS="$SAN" \
  ruby extconf.rb --with-cflags="$(ruby -e 'print RbConfig::CONFIG["CFLAGS"]') $SAN"
sed -i "s#^LIBS = \(.*\)\$#LIBS = \1 $(resources/find_afl_rt.sh)#" Makefile
make CC=afl-clang-fast CXX=afl-clang-fast++ ARCH_FLAG="$SAN" LDSHARED="clang -shared" LDSHAREDXX="clang++ -shared"
```

* **mkmf ignores `CFLAGS` from the environment.** Measured with a one-line extconf.rb:
  an exported `CFLAGS=-DENVFLAG` reached neither the configure probes nor the Makefile;
  `--with-cflags=-DARGFLAG` reached both. mkmf does honour `CC` from the environment
  (its probes ran with afl-clang-fast).
* **`--with-cflags` REPLACES Ruby's CFLAGS.** The Makefile's `CFLAGS` lost `-g -O2` and the
  distro hardening flags. Pass `RbConfig::CONFIG["CFLAGS"]` back in front, as above.
  `--with-ldflags` likewise replaces `ldflags` (`-L.` and friends): do not use it; the
  sanitizer reaches the link through `ARCH_FLAG`.
* **`ARCH_FLAG` is the clean hook at make time.** mkmf appends it to `CFLAGS`, `CXXFLAGS`
  and `DLDFLAGS`, so one variable adds the sanitizer to every compile and to the link
  without touching Ruby's own flags. `CC = ...` in the Makefile is a plain assignment, so
  `make CC=...` overrides it.
* **Some extconf.rb files DO read the environment.** One appended `ENV["CFLAGS"]` and
  `ENV["LDFLAGS"]` itself (its mkmf.log probes them), and vendored recipes (mini_portile,
  a bundled configure) only see the environment. So `build_ext.sh` sets both: env for the
  recipes, `--with-cflags` for mkmf.
* **`afl-clang-fast` drops the AFL runtime from a `-shared` link**, even when `LIBS` names
  `afl-compiler-rt.o` explicitly. Measured: the `.so` linked without `__afl_area_ptr`, and
  ruby refused it with `undefined symbol: __afl_area_ptr` (LoadError). Hence
  `LDSHARED="clang -shared"` plus the runtime in `LIBS`. Under plain ruby the runtime is
  inert (no `__AFL_SHM_ID`, dummy map, no forkserver).

## Configure probes fail silently under clang

mkmf decides features by compiling test programs, and `append_cflags`, `append_cppflags`
and `append_ldflags` compile them with **`-Werror`**. With clang 21, Ruby 3.3's own
`ruby.h` warns (`rstring.h: default initialization of an object of type 'struct RString'
with const member ... [-Wdefault-const-init-field-unsafe]`), so **every probe that
includes ruby.h failed** -- not because the flag was bad but because the header warns.
Case: `checking for whether -I.../<vendored lib>/include is accepted as CPPFLAGS... no`,
then a vendored header not found (`fatal error: '<header>.h' file not found`). That one
failed loudly; a probe whose failure only disables a feature (a `have_func` that guards an
optional decoder, an `append_cflags` for a define) produces a build that works and fuzzes
something else.

Two defences, both in `build_ext.sh`:

* `CLANG_QUIET` (`-Wno-default-const-init-field-unsafe -Wno-unused-command-line-argument
  -Wno-unknown-warning-option`) silences what Ruby's headers and gcc-made flags trigger
  under clang. The list is for clang 21; a newer clang may add a warning of its own.
* With `ORACLE=<oracle gem dir>`, every probe line in the variant's mkmf.log is compared
  with the oracle's mkmf.log (built by `gem install` with Ruby's own compiler, gcc on
  Ubuntu), paths normalised, probes of our own injected flags dropped. Any difference is a
  FAIL with `out/<variant>/probes.diff`. Measured: every probe identical once the
  warnings were silenced. This is the check that would catch the *next* version of this trap, so
  pass `ORACLE=` always.

To look by hand: `grep -- '-------------------- no' mkmf.log`, and read the compile command
and error printed right after each `no`.

## Vendored libraries: mini_portile and friends

* **A recipe that looks installed is skipped.** mini_portile installs into
  `ports/<host>/<lib>/<ver>/` and drops a `ports/<lib>-<ver>-<host>.installed` marker. With
  the directory deleted but the marker left, the build printed `Activating <lib> <ver>
  (from .../ports/...)` with no compile, and then a later `have_func` reported the
  library's core function missing. With
  both left, the second variant silently links the FIRST variant's library (asan objects in
  the plain build, or no coverage in the asan one). `build_ext.sh` deletes `ports/<host>/`,
  the markers and `tmp/` under both the gem root and the extension dir (a gem may keep a
  vendored library under `ext/<name>/ports`).
* **The extension's build may delete everything vendored afterwards.** One gem's cleanup
  removes `ports/` once the extension is linked (unless extconf.rb ran with
  `--disable-clean`): the archives, the headers and `ports/archives/` with the downloaded
  tarballs. Measured: an after-the-fact search found only the archive built outside `ports/`; two
  evaluation runs then failed to compile the harness on a vendored header not found,
  because the snapshot Makefile's `-I`/`LIBS` named the deleted paths; and the second
  variant silently re-downloaded the library. `build_ext.sh` therefore, right after extconf.rb and before make:
  copies the install trees to `out/<variant>/ports/` and rewrites the snapshot Makefile to
  point there; copies every archive the Makefile links to `out/<variant>/lib/`; records
  each recipe (configure options, tarball, patches) in `out/<variant>/vendor/`; and keeps
  the tarballs in `OUT/vendor-archives/`, restoring them before each build.
* **The self-test needs the library rebuilt out of tree**, and after such a cleanup there
  is no build tree or `config.log` left to copy the configure line from. `rebuild_vendored.sh`
  replays a recorded recipe: extract the saved tarball, apply the gem's patches in order,
  configure with mini_portile's logged options and the variant's compiler, `make install`.
  The rebuild carried the same coverage symbols as the extension's build (measured).
* **extconf.rb may need gems of its own.** A vendoring gem's extconf.rb does `gem
  "mini_portile2"`; from an unpacked source tree it failed with `Could not find
  'mini_portile2' (~> 2.8.2)`. The oracle install pulls it in as a dependency: run
  `build_ext.sh` with `GEM_PATH=/abs/oracle`.
* **Per-archive coverage, not total.** One uninstrumented archive among instrumented ones
  is the usual failure (a recipe whose configure ignored `CC`). `build_ext.sh` counts
  sancov symbols in each archive; every one must be non-zero, a test archive the gem
  builds included. If one is zero, read the recipe's
  `config.log` (`grep -c 'checking for gcc... afl-clang-fast'`).
* **Patched sources.** A gem may apply its own patches to the libraries it vendors (the
  gem's `patches/` directory, logged as `Running git apply with ...`). The library you
  fuzz is the patched one -- report bugs against the gem's build, and check whether a
  finding is in a patched region before reporting it upstream to the library.
* **`--use-system-libraries`** (and similar flags elsewhere) switches the
  vendored build off and links the distro's shared library, uninstrumented: step 3b
  territory. Keep `EXTCONF_ARGS` identical across variants and to how the oracle was
  installed, or the variants are different programs.

## The compiler wrapper defines a macro the library may honour

`afl-clang-fast` injects `-DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION=1`, and libraries use
it to compile checks out (on the Node sibling: a compression library skipped its
dictionary-id check, and a 630-seed gate reported 50 mismatches). `-U` on the command line
does not help (the wrapper re-adds it); `-include resources/undef_fuzzmode.h` does, and
`build_ext.sh` and `link_harness.sh` pass it for the AFL variants. An instrumented
library then accepts what the shipped extension rejects, and the gate corpus is usually
too small to notice. A vendored recipe only
sees it if it honours the environment `CFLAGS`. Check:
`grep -rl FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION <library src>`.

## Which extension does the gem actually load?

* **Precompiled platform gems** (`<gem>-<ver>-aarch64-linux-gnu`) ship a `.so` per
  Ruby minor under `lib/<gem>/<ruby_version>/` and never compile anything. An oracle
  installed that way is someone else's build of every library: install with
  `--platform ruby`, and check `ls oracle/gems/` shows no platform suffix.
* **Load order.** A gem with precompiled builds may try `require_relative "#{ruby
  minor}/<name>"` (the precompiled path) and fall back to `require "<gem>/<name>"` (a
  source build, from the gem's extension dir on `$LOAD_PATH`). Another does `require
  '<name>.so'` -- and when Ruby ships that gem as a default gem, an un-activated require
  resolves to Ruby's copy, not the oracle's. `real_harness.rb` activates the oracle's spec explicitly and proves
  the loaded file from `/proc/self/maps`; use the same one-liner by hand:
  `ruby -e 'require "x"; puts File.readlines("/proc/self/maps").grep(/\.so/).map{_1.split.last}.uniq'`.

## Two checks after every build

```sh
[ "$(nm out/plain/<name>.so | grep -c ' [BD] __afl_area_ptr')" != 0 ] || echo "FAIL: no AFL runtime"
ruby -e "require '$PWD/out/plain/<name>.so'"                         || echo "FAIL: builds but will not load"
```

Use the counting form in a script: `nm ... | grep -q x ||` inverts under
`set -o pipefail` (grep closes the pipe, nm takes SIGPIPE). Load the sanitized variants
with the runtime preloaded: `LD_PRELOAD=$(resources/find_asan_rt.sh)
ASAN_OPTIONS=detect_leaks=0 ruby -e ...`.

A standalone `require` of the `.so` is not always possible: an `Init_` that requires the
gem's own Ruby, or uses classes `lib/` defines before loading the extension, fails
outside the gem (`cannot load such file -- <gem>/version`, and with `lib/` on the load
path `uninitialized constant <Gem>::<Class>`; measured). Load it the way the gem does instead --
`lib/` on the load path, the `.so` at `<target_prefix>/<name>.so` (mkmf's `target_prefix`,
`/mygem` for `create_makefile("mygem/mygem")`) in a scratch dir also on the path,
`require "<gem>"` -- and check `/proc/self/maps` shows THIS `.so`. `build_ext.sh` does
that as its fallback (`REQUIRE=`, `LOAD_PRE=`).

## Compiling a harness against ruby.h

A harness or shim that includes the extension's header gets `ruby.h` with it:
* **`ruby.h` must come first and outside `extern "C"`.** It pulls in C++ templates
  (`stdalign.h`) when compiled as C++, and inside an `extern "C"` block that fails with
  `templates must have C++ linkage` (measured). Many extension headers carry their
  own `extern "C"` (check the extension's header); wrap only those that do not.
* **`ruby.h` redefines `snprintf` and `vsnprintf`** to `ruby_snprintf`/`ruby_vsnprintf`,
  libruby's own printf, which the harness does not link: `undefined reference to
  'ruby_snprintf'` (measured). `#undef` both after the includes in files that call
  them; define `ruby_vsnprintf` in the shim only if the extension's objects call it.
* clang 21 warns on `ruby.h` itself (`-Wdefault-const-init-field-unsafe`);
  `link_harness.sh` silences it for the harness TU. Noise, not a problem -- except in
  mkmf probes (above).

## Clang and Ruby's gcc-made flags

Ruby's `RbConfig` flags come from the compiler Ruby was built with (gcc on Ubuntu):
`-Wl,-z,gcs-report-dynamic=none` in `CFLAGS`, gcc-only warnings in `warnflags`
(`-Wsuggest-attribute=format`, `-Wduplicated-cond`). Under clang these are warnings, not
errors -- except inside mkmf's `-Werror` probes, which is the trap above. If an extension
genuinely does not compile with clang (rare for C; check before building variants), fuzz
with `afl-gcc-fast` if your AFL++ has the gcc plugin, and say so in the write-up.

## System library as an instrumented static archive (step 3b)

When the extension links a system library (`ldd out/plain/<name>.so` names it), that
library is uninstrumented: coverage stops at the extension's own code. "Uninstrumented"
does not mean "out of reach": rebuild it from source as an instrumented static archive
and link the harness against it. That is the common route for a gem over a system library
(both evaluation runs on that shape took it, and the harness linked and gated first time). Fuzz the extension's glue only, and say so, only when the library cannot be
rebuilt (no source, a build system that resists the compiler override).

**Which source.** The real side keeps loading the **system** `.so`, and the gate compares
the harness's archive against it byte for byte, so the archive must be the same program:

* the version: `dpkg -s lib<x>-dev | grep Version` (the `-dev` package carries the headers
  the extension compiled against; the runtime package has the same upstream version);
* the distro's patches: read the package's changelog or patch list
  (`/usr/share/doc/lib<x>-dev/changelog.Debian.gz`, the `debian/patches/series` of the
  source package). If it patches the library, apply the same patches;
* the source itself: `apt-get source lib<x>` when `deb-src` is configured (it brings the
  patches applied), else the upstream release tarball of exactly that version.

A different version would let the gate pass on the seeds and the campaign fuzz code the
user's stack does not run; a mismatch the gate does catch then looks like a fidelity bug.

**Autotools**, out of tree, one build directory per variant:

```sh
cd $W && . ./fuzz.env
tar xf <lib>-<ver>.tar.gz -C $W/src
for v in plain asan; do
  mkdir -p $W/lib-build/$v $W/out/$v/lib
  (cd $W/lib-build/$v && ([ $v = asan ] && export AFL_USE_ASAN=1
    export AFL_LLVM_DICT2FILE=$W/out/$v/dict2file.raw    # the library's compared constants
    CC=afl-clang-fast CFLAGS="-O2 -g -fPIC -include $R/undef_fuzzmode.h" \
      $W/src/<lib>-<ver>/configure --disable-shared --enable-static && make -j6) &&
   cp src/.libs/lib<x>.a $W/out/$v/lib/)         # libtool's archive; find . -name '*.a'
done
$R/link_harness.sh VARIANT=plain MK=out/plain/Makefile SRCDIR=$X OUT=$W/out \
    LIB=out/plain/lib/lib<x>.a EXTRA_FLAGS=-I$W/src/<lib>-<ver>/include   # then asan
# no merge step: link_harness.sh rebuilds out/$v/dict.afl from dict2file.raw plus the harness's own constants
```

* `-fPIC`, because the harness links as a PIE and non-PIC objects may not relocate into
  it; `-include
  undef_fuzzmode.h`, for the reason in "The compiler wrapper defines a macro" above;
  `--disable-shared`, so the harness cannot pick up a `.so` by accident.
* `AFL_USE_ASAN=1` makes afl-clang-fast add `-fsanitize=address`; the asan archive must not
  go into the plain harness, so keep one build directory per variant.
* `AFL_LLVM_DICT2FILE`: `build_ext.sh` and `link_harness.sh` set it for the code they
  compile, so `out/<v>/dict.afl` holds the extension's and harness's comparison constants
  only. Export it into the library's build too, as an ABSOLUTE path (afl-cc aborts on a
  relative one) pointing at `$W/out/<v>/dict2file.raw`, and build the library AFTER
  `build_ext.sh`, which starts that raw file afresh; `link_harness.sh` then deduplicates it
  with the harness's constants into `dict.afl`, and the corpus skill's `dict.sh` merges
  that into the campaign's dictionary.
* **Copy a configured or built tree only with `cp -a`.** A plain `cp -r` gives every file a
  new mtime, `make` then thinks `configure.ac` is newer than `configure` and runs the
  autotools (`config/missing: aclocal-1.15: command not found`; measured). The self-test's
  copy (`selftest-rebuild.md`) is the usual place this bites.
* The headers: `EXTRA_FLAGS=-I<the source's include dir>`, or the build directory when the
  library generates a config header there. No extension object is linked in the usual
  shape (the parser builds Ruby objects as it goes), so there are no stubs and gate check
  5 is N/A.

**CMake**: `cmake -S <src> -B $W/lib-build/$v -DCMAKE_C_COMPILER=afl-clang-fast
-DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_C_FLAGS="-O2 -g -include
$R/undef_fuzzmode.h"`, `AFL_USE_ASAN=1` in the environment for asan, then `cmake --build`.
Carried from the autotools case, not measured on a Ruby gem.

**What the real side can and cannot see.** The extension is still built (3a), because
the real side's sanitized column swaps in the ASAN extension; that `.so` still loads the
uninstrumented, unsanitized system library. So `REAL_ASAN` (the gate's and smoke's host
side) and triage's `gem+asan-ext` column cannot see an overflow inside the library:
`oracle-ceiling.md`, "Over a system library the sanitized real side is blind inside it".

**The secondary route: the library as an instrumented shared object.** For a library with
no static build. The AFL runtime cannot live in the library: instrument it with plain clang
`-fsanitize-coverage=trace-pc-guard` and no AFL runtime, keep the runtime in the harness
(linked by `afl-clang-fast++`), and link `resources/covstub.c` into the library's own
executables (the meson invocation is in its header). Link with `LIBS_FROM_MK=1` and make
sure the instrumented `.so` is the one the loader finds. Putting the runtime in the `.so`
needs `AFL_SKIP_BIN_CHECK=1`, which also disables persistent-mode detection. That route is
from the Node sibling.

Whenever the harness TU is compiled by something other than afl-clang-fast
(`link_harness.sh HARNESS_CXX=g++`, for a header that refuses clang), it gets
`-include resources/afl_shim.h` for the persistent-mode macros, and `strings
out/<v>/harness | grep -c SIG_AFL_PERSISTENT` must be non-zero afterwards. That case is from
the Node sibling; whether a Ruby extension needs it is unverified.

## Feature detection: a missing `-dev` package removes a feature silently

`have_header` / `have_library` / `pkg_config` in extconf.rb turn missing system packages
into silently absent features: the extension builds, without the decoder. Read
`extconf.h` (`#define HAVE_...`) and the `-D` list in the Makefile's `CPPFLAGS`, not the
documentation, and compare them with the oracle's (`ORACLE=` does this for every probe).
A gem over a system library may have a single `pkg_config` probe, and that one decides
everything. An extconf with no `create_header` writes no `extconf.h` (the Makefile's `-D`
list is then the whole record), and one that ends by cleaning may leave no `mkmf.log`
(`build_ext.sh` then compares `gem_make.out`).

## Linking the harness: stubs and link errors

The stubs are **exactly** the undefined symbols of `EXT_OBJS` that libruby exports (`nm -D`
of `libruby.so`, or of the ruby binary for a static build), minus what `LIB` defines
(measured: data stubs are real, e.g. `rb_cObject`). Ruby exports **data** too
(`rb_cObject`, `rb_eNoMemError`, read by inline helpers such as `rb_class_of`), which a
function stub cannot trap, so each data stub is a read-only 64 KiB-aligned page made
`PROT_NONE` at startup, with a SIGSEGV/SIGBUS handler. Every stub prints `AFL-HARNESS-STUB:
entered Ruby runtime: <symbol>` and traps; calling an extension's `Init_<name>` from a
harness printed `... rb_ext_ractor_safe` (measured). `link_harness.sh` proves one stub of
each kind aborts with the marker (`stubtest.cc`; `STUB_SYMBOL=` / `DATA_STUB_SYMBOL=`
choose which) and fails if either does not.

`LIBS_FROM_MK=1` appends the extension's own `$(LIBPATH) $(LOCAL_LIBS) $(LIBS)` minus
libruby. When you link no extension object (the system-library shape), or the objects you
link reference no runtime symbol (`link_harness.sh` prints `none: ... nothing to trap`), there
are no stubs and gate check 5 is N/A.

* **A link error naming `rb_*`, `ruby_*`, `st_*` or `onig*`** means an object you link
  references the runtime but is not in `EXT_OBJS`, so it got no stub: add it there, or do
  not link what references it.
* **`gen_stubs.sh` warned that it fell back to `C_SYMBOLS`** (no runtime file to read):
  set `RUBY_RUNTIME=` to the `libruby.so` of the Ruby the oracle runs on. The fallback
  stubs functions only, and data reads then go untrapped.
* **A library symbol undefined** means `LIB` is incomplete or the system libraries are
  missing (`LIBS_FROM_MK=1`).

## ASAN in ruby: the real side of the asan gate

* **Preload the runtime inside `REAL=`, never in front of `gate.sh`.** In front of it the
  runtime is preloaded into afl-showmap and the direct harness as well: every seed is
  `NO-OUTPUT ... rc=86` and check 4 says `afl-showmap produced nothing`; the gate names
  that cause.
* **The gate's default `ASAN_OPTIONS`** carry `detect_leaks=0` (ruby does not free
  everything at exit) and the campaign's allocation ceiling
  (`allocator_may_return_null=1`, `max_allocation_size_mb=$ALLOC_CAP_MB`), so a seed
  declaring a huge allocation is refused the same way on both sides instead of aborting on
  one.
* **`use_sigaltstack=0`.** `real_harness.rb` adds it itself, by re-exec, when it finds
  ASAN loaded: without it every Ruby thread exit died in `AddressSanitizer: CHECK failed
  ... unable to unmmap`, because ASAN munmaps Ruby's malloc'd per-thread signal stack
  (measured). It is not set globally because the direct harness needs ASAN's alternate
  stack to report stack overflows.
* **The gate prints the first error line of whichever side produced no output**, so a
  wrong `EXT=`/`PKG=` path or a sanitizer abort is named rather than counted; if **every**
  seed has no output, the command is broken, not the seeds.

## More symptoms that cost hours

The rest of SKILL.md's "Traps that cost hours" table:

| Symptom | Cause | Fix |
|---|---|---|
| second variant has no coverage, or asan objects in plain | mini_portile reused the first variant's cached library | `build_ext.sh` deletes `ports/<host>` and `tmp/`; pass `PKGROOT=` if it guessed the gem root wrong |
| `LeakSanitizer has encountered a fatal error` at every clean exit of the asan harness | data stubs in a writable segment; LSan scans them and faults on `PROT_NONE` (measured on a first version) | regenerate with the current `gen_stubs.sh` (read-only segment) |
| every real-side ASAN run dies at a thread exit: `CHECK failed ... unable to unmmap` | ASAN munmaps Ruby's per-thread signal stack (measured) | `use_sigaltstack=0`; `real_harness.rb` adds it by re-exec, so use the template |
| real side prints `[BUG] Segmentation fault` and no ASAN report | Ruby's own SIGSEGV handler | a crash all the same; reproduce on the direct harness for the stack |
| `Error: EXT-NOT-SWAPPED` | the gem loaded its `.so` by a path neither hook saw, or `EXT_MATCH` does not match it | find how the gem loads it; set `EXT_MATCH=`/`EXT_MAP=` |
| Self-test: `REBUILD failed with the fault applied` | `FAULT_SED` mangled the code, or the injected statement does not compile | the script keeps the compiler log and the patched source in the workspace; read them |
| showmap says nondeterministic, AFL says stability 100 % | showmap prints exact counts, AFL buckets them | both are right; showmap locates, stability decides |
