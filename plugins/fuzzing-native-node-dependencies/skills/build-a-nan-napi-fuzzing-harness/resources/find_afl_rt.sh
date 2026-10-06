#!/bin/bash
# Print the path of AFL++'s compiler runtime object (afl-compiler-rt.o).  Needed
# because afl-clang-fast drops the runtime from a -shared link, so the addon must be
# linked with plain clang++ and the runtime named explicitly.
#   ./find_afl_rt.sh
# Asks the compiler itself first (AFL_DEBUG prints the link line), then known dirs.
set -uo pipefail
cc=${AFL_CC:-afl-clang-fast}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
echo 'int main(void){return 0;}' > "$T/e.c"
cand=$(AFL_DEBUG=1 "$cc" "$T/e.c" -o "$T/e" 2>&1 | grep -oE '[^ ]*afl-compiler-rt\.o' | while read -r p; do
         [ -f "$p" ] && { echo "$p"; break; }; done)
[ -n "${cand:-}" ] && { readlink -f "$cand"; exit 0; }
for d in "${AFL_PATH:-}" /usr/local/lib/afl /usr/lib/afl "$(dirname "$(command -v "$cc")")/../lib/afl"; do
  [ -n "$d" ] && [ -f "$d/afl-compiler-rt.o" ] && { readlink -f "$d/afl-compiler-rt.o"; exit 0; }
done
echo "find_afl_rt.sh: afl-compiler-rt.o not found; set AFL_PATH" >&2
exit 1
