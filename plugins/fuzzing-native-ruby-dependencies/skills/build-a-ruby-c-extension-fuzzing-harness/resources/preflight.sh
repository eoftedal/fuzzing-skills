#!/bin/bash
# Check the host before the first build: every script in the chain assumes these, and
# each one fails quietly when missing.  BSD sed has no \b, so the gate reads every key as
# empty and both sides "agree"; a missing `timeout` makes every per-seed bound a "command
# not found" exit; afl-fuzz aborts at start-up when core_pattern pipes to a crash handler.
#
#   resources/preflight.sh          # one ok / WARN / FAIL line per check, each FAIL with its fix
#
# Exit status: 1 on any FAIL, 0 otherwise (a WARN does not fail).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
case $HERE in *nan-napi*) RUNTIME=node ;; *ruby*) RUNTIME=ruby ;; *) RUNTIME= ;; esac
fails=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n        fix: %s\n' "$1" "$2"; fails=$((fails + 1)); }
warn() { printf '  WARN  %s\n        %s\n' "$1" "$2"; }
tool() { if command -v "$1" >/dev/null 2>&1; then ok "$1 ($(command -v "$1"))"; else bad "$1 not on PATH" "$2"; fi; }

echo "== preflight (${RUNTIME:-unknown} plugin) =="
for t in afl-clang-fast afl-clang-fast++ afl-fuzz afl-showmap afl-tmin; do
  tool "$t" "install AFL++ (4.x, built with LLVM mode) and put its bin directory on PATH"
done
tool clang "install clang, the same major version AFL++ was built against"
tool nm "install binutils or llvm (llvm-nm works; link it as nm)"
tool c++filt "install binutils or llvm (llvm-cxxfilt works; link it as c++filt)"
tool python3 "install python3"
tool timeout "install GNU coreutils; on macOS put its gnubin directory first on PATH"
if [ "$(echo ab | sed -n 's/\ba//p' 2>/dev/null)" = b ]; then ok "GNU sed (\\b word boundary works)"
else bad "sed is not GNU sed (no \\b): key lookups come back empty and the gate agrees on nothing" \
         "install GNU sed and put it first on PATH (on macOS: gnu-sed's gnubin directory)"; fi
if stat -c%s /dev/null >/dev/null 2>&1; then ok "GNU stat (stat -c%s)"
else bad "stat is not GNU coreutils stat (stat -c%s fails)" "install GNU coreutils and put its gnubin directory first on PATH"; fi
if date +%s%N 2>/dev/null | grep -qE '^[0-9]+$'; then ok "date +%s%N (nanoseconds)"
else bad "date +%s%N does not print digits (BSD date): timings come out wrong" "install GNU coreutils date and put it first on PATH"; fi
for rt in node ruby; do
  if command -v "$rt" >/dev/null 2>&1; then ok "$rt ($("$rt" --version 2>/dev/null | head -1))"
  elif [ "$rt" = "$RUNTIME" ]; then bad "$rt not on PATH: the real-stack harness needs it" "install $rt (the version the package targets) and put it on PATH"
  else printf '  --    %s not on PATH (not needed by this plugin)\n' "$rt"; fi
done
CP=/proc/sys/kernel/core_pattern
if [ ! -r "$CP" ]; then
  warn "$CP not readable (not Linux?)" "the chain is validated on Linux; afl-fuzz checks core_pattern there"
elif [ "$(head -c1 "$CP")" = '|' ]; then
  warn "core_pattern pipes to a handler ($(cut -c1-60 "$CP")): afl-fuzz aborts at start-up" \
       "fix: echo core > $CP (where permitted), else AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 (campaign.sh sets it itself)"
else ok "core_pattern ($(cut -c1-60 "$CP"))"; fi

if [ "$fails" -gt 0 ]; then echo "FAIL: $fails check(s) failed; fix them before building"; exit 1; fi
echo "PASS: preflight"
