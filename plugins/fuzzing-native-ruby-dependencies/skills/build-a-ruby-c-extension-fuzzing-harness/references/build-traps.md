# Build traps: what `build_ext.sh` guards against, and what it cannot

`resources/build_ext.sh` encodes everything in the first two sections. Read this when the
script fails, when you must build by hand (an extension whose library has its own build
system that ignores the environment), or when a variant behaves wrongly.

Measured on Ruby 3.3.8 (Ubuntu 26.04 package), clang 21, AFL++ 4.33c, aarch64 Linux, with
a gem over a system library and a gem with vendored libraries (several, via
mini_portile2), unless a line says otherwise.

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
`build_ext.sh` and `link_harness.sh` pass it for the AFL variants. A vendored recipe only
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

## The library is a separate shared object (step 3b)

When the extension links a system library (`ldd out/plain/<name>.so` names it) the library is uninstrumented: coverage stops at the extension's own
code. Either fuzz the extension's glue only and say so, or build the library from source
instrumented as a static archive and link the harness against it. On the Node sibling the
working combination was: library instrumented with plain clang
`-fsanitize-coverage=trace-pc-guard` and no AFL runtime, the runtime only in the harness
(linked by `afl-clang-fast++`), and `resources/covstub.c` for the library's own executables.
Putting the runtime in the `.so` needs `AFL_SKIP_BIN_CHECK=1`, which also disables
persistent-mode detection.

## Feature detection: a missing `-dev` package removes a feature silently

`have_header` / `have_library` / `pkg_config` in extconf.rb turn missing system packages
into silently absent features: the extension builds, without the decoder. Read
`extconf.h` (`#define HAVE_...`) and the `-D` list in the Makefile's `CPPFLAGS`, not the
documentation, and compare them with the oracle's (`ORACLE=` does this for every probe).
A gem over a system library may have a single `pkg_config` probe, and that one decides
everything.
