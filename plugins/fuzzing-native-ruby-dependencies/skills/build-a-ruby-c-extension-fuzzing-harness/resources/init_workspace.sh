#!/bin/bash
# Write the workspace's fuzz.env: the paths and settings every script in the chain would
# otherwise need on each command line.  The scripts source $WORKSPACE/fuzz.env before
# reading their arguments, so an explicit KEY=VALUE still wins.
#
#   resources/init_workspace.sh W=/abs/fuzz PKG_NAME=<pkg> PKG=/abs/oracle/... \
#       [MODES="MODE=file"] [ADDON_ASAN=/abs/...|EXT_ASAN=/abs/...] [REAL="..."] [REAL_ASAN="..."] \
#       [FIELDS=...] [SOFT_FIELD=...] [SOFT_DROP=...] [ALLOC_CAP_MB=...] [ADDON_MATCH='<name>\.node$']
#
# Re-run it with only the keys to change (W= and, say, MODES="MODE=file MODE=string"): keys
# given on this run replace, every other key in an existing fuzz.env is kept.  W is required
# unless the current directory holds the fuzz.env; PKG_NAME and PKG on the first run.  SKILLS, R and RC are derived from this
# script's own location, PKG_VERSION from $PKG: in the Node plugin its package.json; in the
# Ruby plugin an installed gem's ../../specifications/<dir>.gemspec, else $PKG/*.gemspec,
# else the dir's -<version> suffix.
# REAL and REAL_ASAN, when never given, default to the workspace's real-stack harness, but
# only once that file exists (REAL_ASAN also once the sanitized build's path is known): a
# run before step 5 writes neither, the next run after the file appears does.
# ADDON_MATCH (Node): the regex naming the one addon to swap when the package loads several
# (build_addon.sh prints it); the real harness, gate.sh, smoke.sh and triage read it from here,
# and the default REAL_ASAN carries it.
# Once PKG exists (Node): check_symbols.sh runs on the addon the package actually loads
# (which file that is, and whether node interposes the library it vendors), and an npm
# tarball under W that ships its own build/ is named.  Neither changes the exit status.
# Prints the resulting file, then runs preflight.sh; its exit status is this script's.
set -uo pipefail
# internal names are lower case: fuzz.env keys are upper case and must not clobber them
here=$(cd "$(dirname "$0")" && pwd)
# the plugin from this script's own path, as preflight.sh does
case $here in *nan-napi*) rtbin=node; rh=real_harness.mjs; swap=ADDON ;;
              *)          rtbin=ruby; rh=real_harness.rb;  swap=EXT ;; esac
keys="SKILLS R RC W PKG_NAME PKG PKG_VERSION ADDON_ASAN EXT_ASAN ADDON_MATCH MODES FIELDS SOFT_FIELD SOFT_DROP ALLOC_CAP_MB REAL REAL_ASAN"
known() { case " $keys $extra " in *" $1 "*) return 0;; esac; return 1; }

# arguments into A_<key>, the old file into O_<key>; the caller's environment plays no part
given=" "; extra=""
for kv in "$@"; do
  case $kv in
    [A-Za-z_]*=*) k=${kv%%=*}
      case $k in *[!A-Za-z0-9_]*) echo "init_workspace.sh: bad key: $k" >&2; exit 2;; esac
      printf -v "A_$k" '%s' "${kv#*=}"; given="$given$k "
      known "$k" || extra="$extra $k" ;;
    *) echo "init_workspace.sh: not KEY=VALUE: $kv" >&2; exit 2 ;;
  esac
done
isgiven() { case $given in *" $1 "*) return 0;; esac; return 1; }
# W defaults to the current directory when it already holds a fuzz.env, so a re-run from the
# workspace needs only the keys that change; the first run must say where the workspace is.
if ! isgiven W; then
  if [ -f ./fuzz.env ]; then A_W=$PWD; given="$given W "
  else echo "init_workspace.sh: W=/abs/workspace is required (no fuzz.env in $PWD)" >&2; exit 2; fi
fi
mkdir -p "$A_W" && A_W=$(cd "$A_W" && pwd) || exit 2
envf=$A_W/fuzz.env
oldkeys=""
if [ -f "$envf" ]; then
  oldkeys=$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$envf" | xargs)
  # sourced in a subshell, read back NUL-separated: a value may hold anything but NUL
  ( . "$envf" >/dev/null || exit 1; for k in $oldkeys; do printf '%s\0%s\0' "$k" "${!k-}"; done ) > "$A_W/.fuzz.env.old" \
    || { echo "init_workspace.sh: $envf does not source cleanly" >&2; rm -f "$A_W/.fuzz.env.old"; exit 2; }
  while IFS= read -r -d '' k && IFS= read -r -d '' v; do
    printf -v "O_$k" '%s' "$v"; known "$k" || extra="$extra $k"
  done < "$A_W/.fuzz.env.old"
  rm -f "$A_W/.fuzz.env.old"
fi
# resolve every key: this run's argument, else the old file, else unset
for k in $keys $extra; do
  unset "$k"; a=A_$k; o=O_$k
  if isgiven "$k"; then printf -v "$k" '%s' "${!a}"
  elif [ -n "${!o+x}" ]; then printf -v "$k" '%s' "${!o}"; fi
done

[ -n "${PKG_NAME:-}" ] || { echo "init_workspace.sh: PKG_NAME= is required (no earlier fuzz.env holds it)" >&2; exit 2; }
[ -n "${PKG:-}" ] || { echo "init_workspace.sh: PKG=/abs/path is required (no earlier fuzz.env holds it)" >&2; exit 2; }
case $PKG in /*) ;; *) echo "init_workspace.sh: PKG must be absolute: $PKG" >&2; exit 2;; esac
[ -e "$PKG" ] || echo "init_workspace.sh: WARN: PKG does not exist yet: $PKG" >&2

# always derived: the plugin may have moved since the last run
SKILLS=$(cd "$here/../.." && pwd)
R=$here
RC=$SKILLS/derive-a-fuzzing-corpus-from-source/resources
W=$A_W
if ! isgiven PKG_VERSION; then
  PKG_VERSION=""
  gemver() { sed -n 's/.*\.version *= *["'\'']\([^"'\'']*\)["'\''].*/\1/p' "$1" | head -1; }
  pkgdir=${PKG%/}; spec=$(dirname "$(dirname "$pkgdir")")/specifications/$(basename "$pkgdir").gemspec
  if [ "$rtbin" = node ]; then
    tried="$PKG/package.json"
    if [ -f "$PKG/package.json" ]; then
      PKG_VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$PKG/package.json" 2>/dev/null \
                    || sed -n 's/^ *"version" *: *"\([^"]*\)".*/\1/p' "$PKG/package.json" | head -1)
    fi
  else
    tried="$spec, $PKG/*.gemspec, a -<version> suffix on $(basename "$pkgdir")"
    # an installed gem keeps its spec two levels up, under specifications/<dir name>.gemspec
    [ -f "$spec" ] && PKG_VERSION=$(gemver "$spec")
    # a source checkout carries its own; one that computes the version (a constant) gives nothing
    if [ -z "$PKG_VERSION" ]; then
      gs=$(ls "$PKG"/*.gemspec 2>/dev/null | head -1)
      [ -n "$gs" ] && PKG_VERSION=$(gemver "$gs")
    fi
    # the directory name's -<version> suffix, before any -<platform> tail (name-1.2.3-x86_64-linux)
    if [ -z "$PKG_VERSION" ] && [[ $(basename "$pkgdir") =~ -([0-9][0-9A-Za-z.]*)(-[a-z_][a-z0-9_-]*)?$ ]]; then
      PKG_VERSION=${BASH_REMATCH[1]}
    fi
  fi
  [ -n "$PKG_VERSION" ] || echo "init_workspace.sh: WARN: no PKG_VERSION found (tried $tried); pass PKG_VERSION= to enable the triage version check" >&2
fi
FIELDS=${FIELDS-"status err out_len out_hash"}
SOFT_FIELD=${SOFT_FIELD-lossy}
SOFT_DROP=${SOFT_DROP-"out_len out_hash"}
ALLOC_CAP_MB=${ALLOC_CAP_MB:-1024}
MODES=${MODES-}
# defaults only once the real harness exists: an earlier value would be a guess
if [ -f "$W/$rh" ]; then REAL=${REAL:-env PKG=$PKG $rtbin $W/$rh}
elif [ -z "${REAL:-}" ]; then echo "init_workspace.sh: NOTE: no $W/$rh yet, so no default REAL= (re-run this script once it exists)" >&2; fi
san=${ADDON_ASAN:-${EXT_ASAN:-}}
if [ -z "${REAL_ASAN:-}" ] && [ -n "$san" ] && [ -f "$W/$rh" ]; then
  if asanrt=$("$here/find_asan_rt.sh" 2>/dev/null); then
    am=""; [ "$swap" = ADDON ] && [ -n "${ADDON_MATCH:-}" ] && am="ADDON_MATCH=$ADDON_MATCH "
    REAL_ASAN="env LD_PRELOAD=$asanrt PKG=$PKG $am$swap=$san $rtbin $W/$rh"
  else echo "init_workspace.sh: WARN: no ASAN runtime found (find_asan_rt.sh); REAL_ASAN left unset" >&2; fi
fi

# double-quoted when it needs quoting, with \ " $ ` escaped, so `. fuzz.env` gives back
# exactly the value
q() { case $1 in *[!A-Za-z0-9_./:=@%+,-]*) local v=${1//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\$/\\\$}; v=${v//\`/\\\`}; printf '"%s"' "$v";;
               *) printf '%s' "$1";; esac; }
tmpf=$(mktemp "$W/.fuzz.env.XXXXXX") || exit 2
{
  echo "# fuzz.env: this workspace's paths and settings, written by init_workspace.sh (re-run it"
  echo "# to change a key; keys not given are kept).  Put \`. ./fuzz.env\` at the top of every"
  echo "# command block.  The chain's scripts also source it themselves, before their arguments."
  for k in $keys $extra; do
    [ -n "${!k+x}" ] || continue
    # an empty sanitized path is the same as none
    case $k in ADDON_ASAN|EXT_ASAN|REAL_ASAN|ADDON_MATCH) [ -n "${!k}" ] || continue;; esac
    printf '%s=%s\n' "$k" "$(q "${!k}")"
  done
} > "$tmpf" && mv "$tmpf" "$envf" || { rm -f "$tmpf"; exit 2; }
echo "== $envf"; cat "$envf"; echo
if [ "$rtbin" = node ]; then
  # an npm tarball that ships build/ (a publisher's build/Release, makefiles from another
  # machine): ldd/readelf on the unpacked tree's build/ reads THEIR binary until the first build
  for t in "$W"/*.tgz "$W"/*/*.tgz; do
    [ -f "$t" ] || continue
    nb=$(tar tzf "$t" 2>/dev/null | grep -c '^package/build/')
    [ "$nb" -gt 0 ] && echo "init_workspace.sh: NOTE: $t ships a build/ directory ($nb entries: $(tar tzf "$t" 2>/dev/null | grep '^package/build/' | grep -m3 -E '\.node$|\.mk$|Makefile$' | sed 's#^package/##' | paste -sd' ')):" \
      && echo "        anything read from the unpacked tree's build/ before build_addon.sh is the publisher's build, not this machine's; build_addon.sh deletes it before configure"
  done
  # which addon the package loads, and whether node interposes the library it vendors
  if [ -d "$PKG" ] && [ -f "$here/check_symbols.sh" ]; then
    echo "== check_symbols.sh (the addon require(PKG) loads, and symbol interposition by node)"
    bash "$here/check_symbols.sh" WORKSPACE="$W"; echo
  fi
fi
exec bash "$here/preflight.sh"
