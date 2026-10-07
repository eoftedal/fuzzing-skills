#!/bin/bash
# Build ONE variant of a Ruby C extension (mkmf / extconf.rb) with the compiler swapped,
# verify it, and snapshot the build products (extension .so, objects, vendored archives,
# Makefile, extconf.h) into OUT/<variant>/.  Run it from the extension's source
# directory (where extconf.rb is: <gem>/ext/<name>/).
#
#   build_ext.sh VARIANT=plain|asan|pristine OUT=/abs/path/to/fuzz/out [JOBS=N]
#                [EXTCONF_ARGS="--use-system-libraries ..."] [EXTRA_CFLAGS="..."]
#                [PKGROOT=<gem root>] [AFL_RT=<afl-compiler-rt.o>]
#
#   plain     afl-clang-fast, no sanitizer         -> throughput
#   asan      afl-clang-fast + AFL_USE_ASAN=1      -> bug finding
#   pristine  plain clang + ASAN, NO afl runtime   -> control for "did my instrumentation
#                                                     invent this bug?"; build it when you
#                                                     have a crash to cross-check
#
#   OUT           pass an ABSOLUTE path into your fuzz workspace.
#   EXTCONF_ARGS  passed to `ruby extconf.rb` (the same flags `gem install -- ...` takes).
#                 Keep them identical across variants, and to what the oracle was
#                 installed with, or the variants are different programs.
#   PKGROOT       the gem root (default: the nearest parent holding a *.gemspec, else ../..).
#                 mini_portile recipes build vendored libraries under PKGROOT/ports and
#                 PKGROOT/tmp; see "cached vendored builds" below.
#   ORACLE        the oracle install's gem dir (oracle/gems/<gem>-<ver>).  Its mkmf.log
#                 (from `gem install`, built with Ruby's own compiler) is the reference the
#                 variant's configure-time probes are compared against; any probe that
#                 differs is a FAIL.  Strongly recommended -- see "probes" below.
#   GEM_PATH      set it to the oracle dir when extconf.rb needs gems of its own at build
#                 time (mini_portile2, for one).
#   REQUIRE       the gem feature the load check's fallback requires (default: the extension's
#                 name); LOAD_PRE: Ruby code run before it (see the load check).
#
# What it gets right so you do not have to:
#   * The compiler goes in at BOTH stages.  extconf.rb runs configure-time probes
#     (have_header, have_func) and may build a vendored library itself (mini_portile2:
#     a vendored library); those see only the ENVIRONMENT, so CC/CXX/CFLAGS and
#     AFL_USE_ASAN are exported while extconf.rb runs.  The extension's own TUs are then
#     compiled by `make CC=... CXX=...`: mkmf writes `CC = <the compiler Ruby was built
#     with>` as a plain variable, which a make command-line assignment overrides.
#   * Sanitizer flags go in through ARCH_FLAG, which mkmf appends to CFLAGS, CXXFLAGS and
#     DLDFLAGS (the link) -- not by replacing CFLAGS, which holds the Ruby build's own
#     flags (-fPIC via CCDLFLAGS among them).
#   * The AFL runtime is appended to LIBS INSIDE the generated Makefile, and the link is
#     done by plain clang.  afl-clang-fast drops its runtime from a -shared link (even
#     one naming afl-compiler-rt.o explicitly), and ruby then refuses the extension
#     (undefined symbol: __afl_area_ptr).
#   * Cached vendored builds are removed first.  mini_portile skips a recipe that looks
#     installed, so the second variant would silently link the FIRST variant's library
#     (asan objects in the plain build, or no coverage in the asan one).  ports/<host>/,
#     the ports/*.installed markers and tmp/ are deleted under both PKGROOT and the
#     extension dir.  Downloaded tarballs are kept in OUT/vendor-archives/ and put back
#     (an extconf.rb may delete ports/archives/ itself).
#   * Vendored install trees, archives and recipe records (configure options, tarball,
#     patches) are snapshotted into OUT/<variant>/ right after extconf.rb, before make --
#     an extconf.rb may delete them after the link -- and the snapshot Makefile is
#     rewritten to point at the variant's own copies.
#   * Probes.  mkmf decides features at configure time by compiling test programs, and
#     append_cflags/append_cppflags/append_ldflags compile them with -Werror.  Under clang 21
#     Ruby 3.3's own ruby.h warns (-Wdefault-const-init-field-unsafe), so EVERY such probe
#     failed and was silently dropped -- measured: a vendored library's -I path was rejected
#     and the build died on its header not found; a probe whose
#     failure only disables a feature would not even fail the build.  So the clang warnings
#     Ruby's gcc-made flags trigger are silenced (CLANG_QUIET), and with ORACLE= every probe
#     result is compared against the gcc-built oracle's mkmf.log.
#   * FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION, which afl-clang-fast defines, is
#     undefined again via -include undef_fuzzmode.h for the AFL variants.
#   * Checks after the build: AFL runtime present, ASAN symbols present when they should
#     be, the LIBRARY objects/archives carry coverage symbols (a dropped instrumentation
#     passes the runtime check), and ruby can LOAD the extension.
set -uo pipefail
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
VARIANT=${VARIANT:?set VARIANT=plain|asan|pristine}
OUT=${OUT:-out}
JOBS=${JOBS:-$(nproc)}
EXTRA_CFLAGS=${EXTRA_CFLAGS:-}
EXTCONF_ARGS=${EXTCONF_ARGS:-}
HERE=$(cd "$(dirname "$0")" && pwd)
[ -f extconf.rb ] || { echo "FAIL: no extconf.rb here; run from the extension's source dir (<gem>/ext/<name>)" >&2; exit 2; }
case $OUT in /*) ;; *) echo "note: OUT=$OUT is relative to $PWD; pass an absolute path into your fuzz workspace" >&2 ;; esac
if [ -z "${PKGROOT:-}" ]; then
  d=$PWD; while [ "$d" != / ] && ! ls "$d"/*.gemspec >/dev/null 2>&1; do d=$(dirname "$d"); done
  [ "$d" = / ] && d=$(cd ../.. && pwd)
  PKGROOT=$d
fi

UNDEF="-include $HERE/undef_fuzzmode.h"
case $VARIANT in
  plain)    CC_=afl-clang-fast; CXX_=afl-clang-fast++; unset AFL_USE_ASAN
            SAN="$UNDEF"; NEED_AFL=1; NEED_ASAN=0 ;;
  asan)     CC_=afl-clang-fast; CXX_=afl-clang-fast++; export AFL_USE_ASAN=1
            SAN="$UNDEF -fsanitize=address -fno-omit-frame-pointer"; NEED_AFL=1; NEED_ASAN=1 ;;
  pristine) CC_=clang; CXX_=clang++; unset AFL_USE_ASAN
            SAN="-fsanitize=address -fno-omit-frame-pointer"; NEED_AFL=0; NEED_ASAN=1 ;;
  *) echo "FAIL: VARIANT must be plain|asan|pristine" >&2; exit 2 ;;
esac
# Warnings clang raises on Ruby's own headers and gcc-made flags; under mkmf's -Werror
# probes they turn into silently failed feature checks (see "Probes" above).
CLANG_QUIET="-Wno-default-const-init-field-unsafe -Wno-unused-command-line-argument -Wno-unknown-warning-option"
SAN="$SAN $CLANG_QUIET $EXTRA_CFLAGS"
RT=""
if [ "$NEED_AFL" = 1 ]; then
  RT=${AFL_RT:-$("$HERE/find_afl_rt.sh")} || exit 1
fi
export AFL_QUIET=1
mkdir -p "$OUT/$VARIANT"
LOG=$OUT/$VARIANT/build.log

# Downloaded recipe tarballs are kept OUTSIDE the source tree, in OUT/vendor-archives:
# An extconf.rb's cleanup may delete ports/ including ports/archives/ (measured), so a
# second variant re-downloaded its libraries and an offline container would fail.  Saved before the
# clean, restored after it, and refreshed after extconf.rb.
VA=$OUT/vendor-archives; mkdir -p "$VA"
save_archives() { for root in "$PKGROOT" "$PWD"; do
  for t in "$root"/ports/archives/*; do [ -f "$t" ] && [ ! -f "$VA/$(basename "$t")" ] && cp "$t" "$VA/"; done; done; }
save_archives

echo "== clean ($VARIANT) =="
[ -f Makefile ] && make distclean >/dev/null 2>&1
rm -f Makefile mkmf.log extconf.h ./*.o ./*.so ./*.bundle
# mini_portile recipes install under ports/<host>/ AND drop a ports/<recipe>-<host>.installed
# marker; with the marker left behind, the recipe is skipped even though its directory
# is gone (measured: "Activating <lib> ... from ports/..." with no compile, then a
# have_func reported the library's core function missing).  Recipes can live under the
# gem root and under the extension dir itself, so both are cleaned.
for root in "$PKGROOT" "$PWD"; do
  for d in "$root"/ports/*/; do
    [ -d "$d" ] && [ "$(basename "$d")" != archives ] && rm -rf "$d" && echo "  removed cached vendored build $d"
  done
  for m in "$root"/ports/*.installed; do [ -f "$m" ] && rm -f "$m" && echo "  removed recipe marker $(basename "$m")"; done
  [ -d "$root/tmp" ] && rm -rf "$root/tmp" && echo "  removed $root/tmp"
done
if ls "$VA"/* >/dev/null 2>&1; then           # put saved tarballs back where recipes look
  mkdir -p "$PKGROOT/ports/archives"
  for t in "$VA"/*; do [ -f "$PKGROOT/ports/archives/$(basename "$t")" ] || cp "$t" "$PKGROOT/ports/archives/"; done
fi

echo "== extconf ($VARIANT) =="
# mkmf itself IGNORES CFLAGS from the environment (measured: neither its probes nor the
# Makefile saw an env -D); it honours CC, and --with-cflags.  --with-cflags REPLACES
# Ruby's CFLAGS (the -g -O2 and hardening flags vanished), so Ruby's own are passed back
# in front.  --with-ldflags would likewise replace ldflags (-L. and friends): not used,
# the sanitizer reaches the link through ARCH_FLAG at make time.  The environment
# CFLAGS/LDFLAGS are still set, for vendored recipes (mini_portile, a bundled configure)
# that read them; LDFLAGS without the -include, a compile-only flag a configure script
# would also pass to its link tests.
RUBY_CFLAGS=$(ruby -e 'print RbConfig::CONFIG["CFLAGS"]')
STAMP=$OUT/$VARIANT/.build-start; touch "$STAMP"     # archives newer than this were built now
CC=$CC_ CXX=$CXX_ CFLAGS="$SAN" CXXFLAGS="$SAN" LDFLAGS="${SAN//$UNDEF/}" \
  ruby extconf.rb --with-cflags="$RUBY_CFLAGS $SAN" $EXTCONF_ARGS > "$LOG" 2>&1 \
  || { echo "FAIL: ruby extconf.rb; see $LOG and mkmf.log" >&2; tail -20 "$LOG" >&2
       # extconf.rb can need gems of its own (mini_portile2, for one).  The oracle install
       # pulled them in as dependencies; point GEM_PATH at it rather than installing anew.
       grep -q 'MissingSpecError\|Could not find' "$LOG" && \
         echo "      extconf.rb needs a gem at build time: rerun with GEM_PATH=/abs/oracle (the oracle install has it)" >&2
       exit 1; }
[ -f Makefile ] || { echo "FAIL: extconf.rb wrote no Makefile; see $LOG" >&2; exit 1; }

# Compare configure-time probe results with the oracle's (gcc-built) mkmf.log.  Paths
# differ between the two build dirs, so absolute paths are normalised away.
# every probe line: `have_header: checking for x.h... ---------- yes`, also pkg_config's
# `... ---------- [" ", "", "-lfoo"]`.  Probes OF our own flags are dropped: an extconf.rb
# that appends ENV["CFLAGS"] itself (measured) probes the sanitizer flags, which the
# oracle never saw.
probes() { grep -E '^[a-z_]+: checking .* -{5,} ' "$1" | grep -vF -e "$CLANG_QUIET" -e "undef_fuzzmode.h" -e "-fsanitize=" \
             | sed -E 's#/[^ "]*#<path>#g; s/ -{5,} / => /' | sort -u; }
# Fallback when the oracle has no mkmf.log (an extconf.rb that ends with `make clean`
# deletes it -- measured): extconf.rb's own stdout, `checking for x... yes`, which the gem
# install keeps in gem_make.out and build_ext.sh keeps in build.log.
probes_out() { grep -E '^checking .*\.\.\. ' "$1" | grep -vF -e "$CLANG_QUIET" -e "undef_fuzzmode.h" -e "-fsanitize=" \
                 | sed -E 's#/[^ "]*#<path>#g' | sort -u; }
PROBE_FAIL=0
if [ -n "${ORACLE:-}" ]; then
  EXTD=$(ls -d "$ORACLE"/../../extensions/*/*/"$(basename "$ORACLE")" 2>/dev/null | head -1)
  if [ -f "$EXTD/mkmf.log" ]; then REF=$EXTD/mkmf.log; how="mkmf.log"; mine=$(probes mkmf.log); theirs=$(probes "$REF")
  elif [ -f "$EXTD/gem_make.out" ]; then REF=$EXTD/gem_make.out; how="gem_make.out (no mkmf.log)"; mine=$(probes_out "$LOG"); theirs=$(probes_out "$REF")
  else REF=""; fi
  if [ -z "$REF" ]; then echo "  WARN: neither mkmf.log nor gem_make.out for $(basename "$ORACLE") under the oracle's extensions/; probes not compared" >&2
  else
    diff <(echo "$theirs") <(echo "$mine") > "$OUT/$VARIANT/probes.diff"
    if [ -s "$OUT/$VARIANT/probes.diff" ]; then
      echo "  FAIL: configure probes differ from the oracle's $how ($(grep -c '^>' "$OUT/$VARIANT/probes.diff") lines; $OUT/$VARIANT/probes.diff):" >&2
      grep '^[<>]' "$OUT/$VARIANT/probes.diff" | head -6 | sed 's/^/        /' >&2
      echo "        the variant is configured differently from the gem users run; see mkmf.log for the failing compile" >&2
      PROBE_FAIL=1
    elif [ -z "$mine" ]; then echo "  note: extconf.rb ran no configure probes; nothing to compare"
    else echo "  ok: $(echo "$mine" | wc -l) configure probes match the oracle's $how"; fi
  fi
else
  nno=$(probes mkmf.log | grep -c ' => no$')
  echo "  note: no ORACLE= to compare configure probes against; $nno probe(s) said no (see mkmf.log)"
fi

# Snapshot everything vendored NOW, before make: recipes build it during extconf.rb, and
# an extconf.rb may delete it once the extension is linked (measured: one gem's Makefile
# removes ports/<host>/ after the link unless --disable-clean -- the archives AND their
# include dirs were gone, so the snapshot Makefile's -I and LIBS pointed at nothing
# and link_harness.sh failed on the library's header not found).
#   out/<v>/ports/<lib>/<ver>/{include,lib}  the recipes' install trees; the snapshot Makefile
#                                            is rewritten to point here (after make, below)
#   out/<v>/lib/*.a                          one flat copy per archive (LIB= for link_harness.sh)
#   out/<v>/vendor/<lib>-<ver>/              configure options, source tarball name, patches in
#                                            order: what rebuild_vendored.sh replays for the
#                                            self-test's out-of-tree library build
save_archives
rm -rf "$OUT/$VARIANT/lib" "$OUT/$VARIANT/ports" "$OUT/$VARIANT/vendor"
PORTMAP=""                                   # "<ports/<host> path>" lines, for the Makefile rewrite
for root in "$PKGROOT" "$PWD"; do
  for d in "$root"/ports/*/; do
    [ -d "$d" ] && [ "$(basename "$d")" != archives ] || continue
    mkdir -p "$OUT/$VARIANT/ports"; cp -a "$d". "$OUT/$VARIANT/ports/"
    PORTMAP="$PORTMAP ${d%/}"
  done
done
# Archives: the ones the Makefile links, plus any other library built since the stamp --
# not a recipe's build tree (tmp/, a second copy of the same library) and not a
# library's own test archive (test*.a).  One per basename.
ARCHIVES=$( { "$HERE/mkvar.sh" Makefile LOCAL_LIBS LIBS | sed 's/^[A-Z_]*=//' | tr ' ' '\n' | grep '\.a$';
              find "$PKGROOT" "$PWD" -name '*.a' -newer "$STAMP" -not -path '*/archives/*' -not -path '*/tmp/*' \
                   -not -name 'test*' 2>/dev/null; } \
            | while read -r a; do [ -f "$a" ] && readlink -f "$a"; done | awk -F/ '!seen[$NF]++')
if [ -n "$ARCHIVES" ]; then
  mkdir -p "$OUT/$VARIANT/lib"; cp $ARCHIVES "$OUT/$VARIANT/lib/"
  ARCHIVES=$(ls "$OUT/$VARIANT"/lib/*.a)
fi
# Recipe records, from mini_portile's own log lines.  Each recipe ends at "Running
# 'compile' for <name> <ver>"; the last "Configuration options:" line, the "Extracting
# <tarball>" or "Copying <dir> files" line and the "Running git apply with <patch>" lines
# seen since the previous recipe belong to it.
# Fields are separated by \037, not tabs: `read` collapses consecutive tabs (IFS
# whitespace), so an empty field (a recipe with no patches) shifted the configure options
# into the patches field.
awk -v US=$'\037' '
  /^Configuration options: / { opts = substr($0, 24) }
  /^Extracting .* into /     { src = "tarball" US $2 }
  /^Copying .* files into /  { src = "dir" US $2 }
  /^Running git apply with / { p = $5; sub(/\.\.\..*$/, "", p); patches = patches p ";" }
  /^Running .compile. for /  { name = $4; ver = $5; sub(/\.\.\..*$/, "", ver)
                               if (src == "") src = US
                               print name US ver US src US patches US opts
                               opts = ""; src = ""; patches = "" }' "$LOG" |
while IFS=$'\037' read -r name ver kind source patches opts; do
  rd=$OUT/$VARIANT/vendor/$name-$ver; mkdir -p "$rd/patches"
  printf '%s\n' "$opts" > "$rd/configure.opts"
  if [ "$kind" = tarball ]; then echo "$source" > "$rd/tarball"
  elif [ -n "$source" ]; then
    s=$source; case $s in /*) ;; *) [ -d "$PWD/$s" ] && s=$PWD/$s || s=$PKGROOT/$s ;; esac
    echo "$s" > "$rd/sourcedir"
  fi
  i=0; IFS=';'; for p in $patches; do i=$((i+1)); [ -f "$p" ] && cp "$p" "$rd/patches/$(printf %02d $i)-$(basename "$p")"; done; unset IFS
  echo "  recorded vendored recipe $name $ver ($i patch(es)) -> $rd"
done

if [ -n "$RT" ]; then
  sed -i "s#^LIBS = \(.*\)\$#LIBS = \1 $RT#" Makefile
  grep -q "^LIBS = .*$RT" Makefile || { echo "FAIL: could not add the AFL runtime to LIBS in Makefile" >&2; exit 1; }
fi

echo "== make ($VARIANT) =="
# LDSHARED is PLAIN clang: afl-clang-fast filters afl-compiler-rt.o out of a -shared
# link even when LIBS names it (measured: the .so linked without __afl_area_ptr and
# ruby refused it).  The sanitizer flag still reaches the link through ARCH_FLAG.
make -j"$JOBS" V=1 CC="$CC_" CXX="$CXX_" ARCH_FLAG="$SAN" \
     LDSHARED="clang -shared" LDSHAREDXX="clang++ -shared" >> "$LOG" 2>&1 \
  || { echo "FAIL: make; see $LOG" >&2; grep -m5 -E 'error:|Error ' "$LOG" >&2; exit 1; }

DLLIB=$("$HERE/mkvar.sh" Makefile DLLIB | sed -n 's/^DLLIB=//p')
SO=$PWD/$DLLIB
[ -f "$SO" ] || { echo "FAIL: make produced no $DLLIB" >&2; exit 1; }

OBJS=$(ls ./*.o 2>/dev/null)

echo "== verify =="
fail=$PROBE_FAIL
# counting form, not `| grep -q ... ||`: under pipefail grep -q closes the pipe and
# nm dies of SIGPIPE, which reads as "symbol missing" when it is right there.
if [ "$NEED_AFL" = 1 ]; then
  [ "$(nm "$SO" | grep -c ' [BD] __afl_area_ptr')" != 0 ] \
    && echo "  ok: AFL runtime present in $DLLIB" \
    || { echo "  FAIL: no AFL runtime in $DLLIB; ruby will refuse it" >&2; fail=1; }
  own=$(nm $OBJS 2>/dev/null | grep -c sancov)
  if [ -n "$ARCHIVES" ]; then
    # per archive: one uninstrumented archive among instrumented ones is the usual failure
    for a in $ARCHIVES; do
      n=$(nm "$a" 2>/dev/null | grep -c sancov)
      if [ "$n" != 0 ]; then echo "  ok: $n coverage symbols in vendored $(basename "$a")"
      else echo "  FAIL: vendored $(basename "$a") carries no coverage: its recipe ignored CC/CFLAGS (see build-traps.md)" >&2; fail=1; fi
    done
  elif [ "$own" != 0 ]; then
    echo "  ok: $own coverage symbols in the extension's own objects (no vendored archive: the library is compiled into the extension, or is a system .so)"
  else echo "  FAIL: no coverage symbols in the extension's objects" >&2; fail=1; fi
  ldd "$SO" 2>/dev/null | awk '$3 ~ /^\// {print $3}' | grep -vE 'lib(c|m|ruby|pthread|dl|rt|gcc_s|stdc\+\+|asan)[.-]' \
    | sed 's/^/  note: links system library (uninstrumented): /'
fi
if [ "$NEED_ASAN" = 1 ]; then
  [ "$(nm "$SO" | grep -c '__asan_')" != 0 ] \
    && echo "  ok: ASAN symbols present" \
    || { echo "  FAIL: variant $VARIANT has no ASAN symbols" >&2; fail=1; }
  PRELOAD="LD_PRELOAD=$("$HERE/find_asan_rt.sh")"
else
  PRELOAD=""
fi
# An Init_<name> may need the gem's own Ruby loaded first: it requires "<gem>/version" and
# uses a class that lib/<gem>.rb defines before `require '<gem>/<gem>'` (measured:
# standalone it fails with "cannot load such file -- <gem>/version", and with lib/ on the
# load path with "uninitialized constant <Gem>::<Class>").  So the fallback loads it the way the gem does:
# the gem's lib/ on the load path, this .so at <target_prefix>/<name>.so in a scratch
# dir, `require "<REQUIRE>"` (default: the extension's name), and /proc/self/maps must
# then show THIS .so mapped -- a fallback that silently loaded another copy proves nothing.
# LOAD_PRE= is Ruby code run first, for anything else Init needs.
ASAN_LOAD="detect_leaks=0:use_sigaltstack=0"
TPFX=$("$HERE/mkvar.sh" Makefile target_prefix | sed -n 's/^target_prefix=//p')
LC=$OUT/$VARIANT/loadcheck; rm -rf "$LC"; mkdir -p "$LC$TPFX"; ln -s "$SO" "$LC$TPFX/$DLLIB"
FEATURE=${REQUIRE:-${DLLIB%.*}}
if env $PRELOAD ASAN_OPTIONS=$ASAN_LOAD ruby -e "${LOAD_PRE:-}require '$SO'" 2>"$OUT/$VARIANT/load.err"; then
  echo "  ok: ruby loads $DLLIB"
elif [ -d "$PKGROOT/lib" ] && env $PRELOAD ASAN_OPTIONS=$ASAN_LOAD ruby -I"$PKGROOT/lib" -I"$LC" -e \
       "${LOAD_PRE:-}require '$FEATURE'; m = File.read('/proc/self/maps'); exit(m.include?(File.realpath('$SO')) ? 0 : 3)" \
       2>>"$OUT/$VARIANT/load.err"; then
  echo "  ok: ruby loads $DLLIB through the gem's own require '$FEATURE' (its Init needs the gem's Ruby; verified mapped)"
else
  echo "  FAIL: ruby cannot load $DLLIB, standalone or through require '$FEATURE' (see $OUT/$VARIANT/load.err)" >&2
  echo "        exit 3 there means another copy was loaded; set REQUIRE=<feature> / LOAD_PRE='require \"<dep>\"; '" >&2
  fail=1
fi
rm -rf "$LC"

echo "== snapshot -> $OUT/$VARIANT =="
rm -rf "$OUT/$VARIANT/obj"
mkdir -p "$OUT/$VARIANT/obj"
cp "$SO" Makefile "$OUT/$VARIANT/"
# Point the snapshot Makefile's -I/-L/archive paths at this variant's own copies.  The
# originals are shared by every variant (whichever built last) and may already be gone.
for p in $PORTMAP; do sed -i "s#$p#$OUT/$VARIANT/ports#g" "$OUT/$VARIANT/Makefile"; done
[ -f extconf.h ] && cp extconf.h "$OUT/$VARIANT/"
cp mkmf.log "$OUT/$VARIANT/" 2>/dev/null
cp $OBJS "$OUT/$VARIANT/obj/"
# archives were already copied to $OUT/$VARIANT/lib right after extconf.rb
echo "  extension: $OUT/$VARIANT/$DLLIB"
echo "  objects:   $(ls "$OUT/$VARIANT/obj" | wc -l) under $OUT/$VARIANT/obj  (EXT_OBJS= for link_harness.sh, if the boundary is in them)"
[ -d "$OUT/$VARIANT/lib" ] && echo "  archives:  $(ls "$OUT/$VARIANT/lib" | tr '\n' ' ')under $OUT/$VARIANT/lib  (LIB= for link_harness.sh)"
echo "  flags:     $HERE/lift_flags.sh $OUT/$VARIANT/Makefile SRCDIR=$PWD"
exit $fail
