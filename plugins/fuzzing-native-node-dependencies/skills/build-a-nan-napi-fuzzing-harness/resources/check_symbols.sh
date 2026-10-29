#!/bin/bash
# Does the host runtime INTERPOSE the library the addon vendors?
#
# The node binary exports its own copy of some libraries (compression, crypto, ...):
#   nm -D "$(command -v node)" | grep ' T '
# An addon that defines the same public symbols with DEFAULT visibility, and is not linked
# -Bsymbolic, has every one of its calls to them bound to node's copy by the dynamic
# linker (node is searched first).  The vendored library in the as-installed package is
# then dead code for those functions, and the real-stack gate compares the harness against
# a DIFFERENT version of the library: a gate that only agrees on inputs where the two
# versions happen to behave alike, and a mismatch nothing in the harness explains.
#
#   $R/check_symbols.sh [WORKSPACE=$W] [PKG=<oracle>/node_modules/<pkg>] [ADDON=/abs/x.node] [ADDON_MATCH=<regex>]
#
#   PKG          (fuzz.env) the oracle package.  The addon(s) checked are the files
#                `require(PKG)` actually dlopens (a package may load build/bindings/x.node or a
#                prebuild, not build/Release/x.node), else build/Release/*.node
#   ADDON        check this file instead (your out/<variant>/Release/x.node, a second oracle's)
#   ADDON_MATCH  (fuzz.env) only the loaded addons whose path matches this regex
#
# For each addon: its defined GLOBAL functions of default visibility (readelf --dyn-syms;
# `nm -D --defined-only` when readelf is missing), intersected with node's exported
# functions.  An addon carrying DT_FLAGS SYMBOLIC binds its own definitions first: OK.
# Then, when glibc's LD_DEBUG works, the binding is OBSERVED, not inferred:
#   LD_BIND_NOW=1 LD_DEBUG=bindings node -e "require('<addon>')" 2>&1 \
#     | grep "binding file <addon> \[0\] to " | grep -v "to <addon> \[0\]"
# LD_BIND_NOW resolves every PLT entry at load, so no call into the library is needed;
# by hand, without it, make one call that reaches the library inside -e (lazy binding
# resolves a function only on its first call), and the line reads
#   binding file .../x.node [0] to node [0]: normal symbol `<library function>'
#
# Prints, per addon, `OK: no shared exports` (or `OK: ... linked -Bsymbolic`), or
#   INTERPOSED: <n> symbols of <addon> are also exported by node (e.g. <first 3>)
# followed by the prescription.  Exit 0 all OK, 1 any INTERPOSED, 2 nothing could be checked.
#
# Then the addon's SHARED LIBRARIES (the closure ldd resolves, minus libc/libm/libpthread/
# libdl/librt/ld-linux/libstdc++/libgcc_s and sanitizer runtimes), each checked the same way:
#   WARN DEPENDENCY-INTERPOSED: <lib> exports <n> functions node also exports (e.g. ...)
# A binding over system libraries (an image library that inflates through a compression
# library) has that library's calls served by node's bundled copy in the real stack, while
# the harness, a plain executable, uses the system one.  The gate then compares two versions
# and passes only where they behave alike.  A WARN, not a FAIL (exit status unchanged): it is
# usually harmless, and there is no clean remedy short of a harness that loads the library
# the same way; name it in the scope statement, and suspect it first on a gate mismatch in
# code that library runs.  The binding is observed under LD_BIND_NOW/LD_DEBUG as above.
# init_workspace.sh runs it once PKG exists; its result does not change that script's status.
set -uo pipefail
for kv in "$@"; do case $kv in WORKSPACE=*) WORKSPACE=${kv#*=};; esac; done
WS=${WORKSPACE:-.}; [ -f "$WS/fuzz.env" ] && { set -a; . "$WS/fuzz.env"; set +a; }
for kv in "$@"; do case $kv in *=*) export "$kv";; esac; done
HERE=$(cd "$(dirname "$0")" && pwd)
NODE=$(command -v node) || { echo "check_symbols.sh: node not on PATH" >&2; exit 2; }
NODE=$(readlink -f "$NODE")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# ---- which addon(s) ----
addons=()
if [ -n "${ADDON:-}" ]; then
  [ -f "$ADDON" ] || { echo "check_symbols.sh: ADDON=$ADDON does not exist" >&2; exit 2; }
  addons=("$(readlink -f "$ADDON")")
elif [ -n "${PKG:-}" ] && [ -d "$PKG" ]; then
  # what the package's loader really dlopens: the same hook real_harness.mjs swaps through
  (cd "$T" && timeout 60 node -e '
    const o = process.dlopen;
    process.dlopen = function (m, f, ...r) { process.stdout.write("DLOPEN\t" + f + "\n"); return o.call(this, m, f, ...r); };
    require(process.argv[1]);' "$PKG") > "$T/dl" 2>"$T/dl.err"
  while IFS=$'\t' read -r tag f; do [ "$tag" = DLOPEN ] && [ -f "$f" ] && addons+=("$(readlink -f "$f")"); done < "$T/dl"
  if [ ${#addons[@]} = 0 ]; then
    echo "  note: require(PKG) dlopened no addon (lazy loader, or it failed: $(grep -m1 -E 'Error' "$T/dl.err" | cut -c1-100)); checking build/Release/*.node"
    for f in "$PKG"/build/Release/*.node; do [ -f "$f" ] && addons+=("$(readlink -f "$f")"); done
  fi
else
  echo "check_symbols.sh: set PKG=<oracle package dir> (fuzz.env) or ADDON=<x.node>" >&2; exit 2
fi
if [ -n "${ADDON_MATCH:-}" ] && [ -z "${ADDON:-}" ]; then
  keep=(); for a in "${addons[@]}"; do grep -qE "$ADDON_MATCH" <<<"$a" && keep+=("$a"); done
  [ ${#keep[@]} -gt 0 ] && addons=("${keep[@]}") || echo "  note: ADDON_MATCH=$ADDON_MATCH matches none of the loaded addons; checking all"
fi
[ ${#addons[@]} -gt 0 ] || { echo "check_symbols.sh: no addon found under ${PKG:-?}" >&2; exit 2; }

# defined, GLOBAL, default-visibility functions of a shared object (PROTECTED binds locally)
exports() {
  if command -v readelf >/dev/null 2>&1; then
    readelf --dyn-syms -W "$1" 2>/dev/null | awk '$4=="FUNC" && $5=="GLOBAL" && $6=="DEFAULT" && $7!="UND" {sub(/@.*/, "", $8); print $8}'
  else
    nm -D --defined-only "$1" 2>/dev/null | awk '$2=="T" {sub(/@.*/, "", $3); print $3}'
  fi | LC_ALL=C sort -u
}
symbolic() { readelf -d "$1" 2>/dev/null | grep -qE '\(SYMBOLIC\)|FLAGS.*SYMBOLIC'; }
needed() { readelf -d "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p'; }
asan_preload() { nm -D "$1" 2>/dev/null | grep -q ' U __asan_' && "$HERE/find_asan_rt.sh" 2>/dev/null; }

exports "$NODE" > "$T/node.syms"
[ -s "$T/node.syms" ] || { echo "check_symbols.sh: no exported functions read from $NODE (readelf/nm missing?)" >&2; exit 2; }
status=0
own_check() {   # <addon>: its own exports against node's; sets status=1 when INTERPOSED
  local a=$1 n seen pre
  case $a in */build/Release/*) ;;
    *) if [ -z "${ADDON:-}" ]; then rel=$PKG/build/Release/$(basename "$a"); same="no build/Release copy"
         [ -f "$rel" ] && { cmp -s "$rel" "$a" && same="same bytes as build/Release/$(basename "$a")" || same="DIFFERENT bytes from build/Release/$(basename "$a")"; }
         echo "  note: require(PKG) loads this file, not build/Release/ ($same): this is the addon the real stack runs"; fi;;
  esac
  exports "$a" > "$T/addon.syms"
  LC_ALL=C comm -12 "$T/node.syms" "$T/addon.syms" > "$T/shared"
  n=$(wc -l < "$T/shared")
  if [ "$n" = 0 ]; then echo "  OK: no shared exports ($(wc -l < "$T/addon.syms") functions exported by $(basename "$a"), none also exported by node)"; return; fi
  if symbolic "$a"; then
    echo "  OK: $n exported functions are also in node, but $(basename "$a") is linked -Bsymbolic (DT_FLAGS SYMBOLIC): its own calls bind to its own copy"; return; fi
  status=1
  echo "INTERPOSED: $n symbols of $(basename "$a") are also exported by node (e.g. $(head -3 "$T/shared" | paste -sd' '))"
  # observe it: every PLT entry bound at load, then count the shared symbols bound outside the addon
  pre=$(asan_preload "$a")
  ( cd "$T" && env ${pre:+LD_PRELOAD=$pre} ASAN_OPTIONS=detect_leaks=0 LD_BIND_NOW=1 LD_DEBUG=bindings timeout 60 \
      node -e 'require(process.argv[1])' "$a" ) > /dev/null 2> "$T/ld"
  grep -F "binding file $a [0] to " "$T/ld" | grep -vF "to $a [0]" \
    | sed -n "s/.* to \([^ ]*\) \[0\]: normal symbol \`\([^']*\)'.*/\2\t\1/p" | LC_ALL=C sort -u > "$T/bound"
  if [ -s "$T/ld" ] && grep -q 'binding file' "$T/ld"; then
    seen=$(cut -f1 "$T/bound" | LC_ALL=C comm -12 - "$T/shared" | wc -l)
    echo "  observed (LD_BIND_NOW=1 LD_DEBUG=bindings): the addon's own references to $seen of the $n bind outside it, to $(cut -f2 "$T/bound" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')"
  else echo "  (LD_DEBUG=bindings printed nothing here: not glibc? the static intersection above stands)"; fi
  cat <<EOF
  Every call $(basename "$a") makes to these runs node's copy of the library, not the one the package
  vendors: the as-installed oracle compares your harness against node's version.
  Prescription:
   1. a second oracle, linked -Bsymbolic, so the real stack runs the vendored code:
        mkdir -p \$W/oracle-sym && cd \$W/oracle-sym && npm init -y >/dev/null
        LDFLAGS=-Wl,-Bsymbolic npm_config_build_from_source=true npm install \$PKG_NAME@\$PKG_VERSION
        \$R/init_workspace.sh W=\$W PKG=\$W/oracle-sym/node_modules/\$PKG_NAME \\
            REAL="env PKG=\$W/oracle-sym/node_modules/\$PKG_NAME node \$W/real_harness.mjs" REAL_ASAN="..."
      then re-check: \$R/check_symbols.sh ADDON=<the .node that oracle loads>  ->  OK ... -Bsymbolic
   2. build the swapped-in addons the same way: build_addon.sh VARIANT=asan EXTRA_LDFLAGS=-Wl,-Bsymbolic
      (and plain); rebuild_asan.sh passes EXTRA_LDFLAGS on, so give it in rebuild.sh too
   3. keep the as-installed oracle: a finding's final reproducer is checked against what users run
EOF
}

# the addon's shared libraries (ldd's closure), each intersected with node's exports
deps_check() {   # <addon>
  local a=$1 lib path n via pre nd=0 nw=0
  ldd "$a" 2>/dev/null | sed -n 's/^[[:space:]]*\([^ ]*\) => \(\/[^ ]*\) .*/\1\t\2/p' > "$T/deps"
  # who needs whom, for the "needed by" column: the addon and every library in the closure
  : > "$T/needs"; : > "$T/dshared.all"
  for path in "$a" $(cut -f2 "$T/deps"); do needed "$path" | sed "s|^|$(basename "$path")\t|" >> "$T/needs"; done
  while IFS=$'\t' read -r lib path; do
    case $lib in libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*|ld-linux*|libstdc++.so*|libgcc_s.so*|libclang_rt.*|libasan.so*|libubsan.so*) continue;; esac
    nd=$((nd + 1))
    exports "$path" > "$T/dep.syms"
    LC_ALL=C comm -12 "$T/node.syms" "$T/dep.syms" > "$T/dshared"
    n=$(wc -l < "$T/dshared"); [ "$n" = 0 ] && continue
    symbolic "$path" && { echo "  OK: dependency $lib shares $n exports with node but is linked -Bsymbolic"; continue; }
    nw=$((nw + 1)); cat "$T/dshared" >> "$T/dshared.all"
    via=$(awk -F'\t' -v l="$lib" '$2==l{print $1}' "$T/needs" | sort -u | paste -sd, -)
    echo "WARN DEPENDENCY-INTERPOSED: $lib exports $n functions node also exports (e.g. $(head -3 "$T/dshared" | paste -sd' ' -)); needed by ${via:-?}"
  done < "$T/deps"
  if [ "$nw" -gt 0 ]; then
    pre=$(asan_preload "$a")
    ( cd "$T" && env ${pre:+LD_PRELOAD=$pre} ASAN_OPTIONS=detect_leaks=0 LD_BIND_NOW=1 LD_DEBUG=bindings timeout 60 \
        node -e 'require(process.argv[1])' "$a" ) > /dev/null 2> "$T/dld"
    if grep -q 'binding file' "$T/dld"; then
      # references made by a library of the closure (not the addon, not node) to one of the
      # shared functions above that bind to the node executable
      LC_ALL=C sort -u -o "$T/dshared.all" "$T/dshared.all"
      grep -F 'binding file ' "$T/dld" | grep -E " to ([^ ]*/)?node \[0\]: normal symbol" | grep -vF "binding file $a " \
        | sed -n "s/.*binding file \([^ ]*\) \[0\] to .*normal symbol \`\([^']*\)'.*/\1\t\2/p" \
        | awk -F'\t' 'NR==FNR{want[$1]=1; next} ($2 in want) && $1 !~ /(^|\/)node$/' "$T/dshared.all" - | LC_ALL=C sort -u > "$T/dbound"
      if [ -s "$T/dbound" ]; then
        cut -f1 "$T/dbound" | sort | uniq -c | while read -r c f; do
          echo "  observed (LD_BIND_NOW=1 LD_DEBUG=bindings): $c of $(basename "$f")'s references bind to node (e.g. $(awk -F'\t' -v f="$f" '$1==f{print $2}' "$T/dbound" | head -3 | paste -sd' ' -))"
        done
      else echo "  observed (LD_BIND_NOW=1 LD_DEBUG=bindings): no dependency's reference binds to node at load (unused, or reached by dlsym)"; fi
    else echo "  (LD_DEBUG=bindings printed nothing here: not glibc? the static intersection above stands)"; fi
    cat <<EOF
  In the real stack these libraries' calls into the shared functions run node's bundled copy;
  the harness, a plain executable, runs the system library.  The gate compares the two and agrees
  only where they behave alike.  Not a failure: say so in the scope, and suspect it first when a
  gate mismatch sits in code the dependency runs.
EOF
  fi
  echo "  dependencies: $nd shared librar$([ "$nd" = 1 ] && echo y || echo ies) besides the C/C++ runtime checked; $nw share exports with node"
}

for a in "${addons[@]}"; do
  echo "== $a"
  own_check "$a"
  deps_check "$a"
done
exit $status
