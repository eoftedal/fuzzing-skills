#!/bin/bash
# Print the path of clang's ASAN runtime shared object, for LD_PRELOAD under ruby
# (run with ASAN_OPTIONS=detect_leaks=0: ruby leaks its own allocations at exit by design).
# Handles both layouts: lib/linux/libclang_rt.asan-<arch>.so (older clang) and
# lib/<triple>/libclang_rt.asan.so (per-target runtime dirs, newer clang).
#   ./find_asan_rt.sh [clang]
CLANG=${1:-${CLANG:-clang}}
arch=$(uname -m)
for cand in "$($CLANG -print-file-name=libclang_rt.asan-$arch.so 2>/dev/null)" \
            "$($CLANG -print-runtime-dir 2>/dev/null)/libclang_rt.asan.so" \
            "$($CLANG -print-resource-dir 2>/dev/null)/lib/linux/libclang_rt.asan-$arch.so"; do
  case $cand in /*) [ -f "$cand" ] && { echo "$cand"; exit 0; } ;; esac
done
echo "find_asan_rt.sh: no ASAN runtime found for $CLANG" >&2
exit 1
