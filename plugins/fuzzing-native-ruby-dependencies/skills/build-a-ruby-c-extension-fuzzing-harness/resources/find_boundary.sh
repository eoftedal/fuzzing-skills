#!/bin/bash
# Rank an extension's compiled objects by how much they touch the Ruby runtime.
#
#   find_boundary.sh out/plain/obj/*.o [out/plain/lib/*.a]
#
# The object with the FEWEST references is where to start reading -- but the count
# is a hint, not the criterion.  What you actually want is an object containing a
# function on your input path that touches the runtime in none of its own lines.
# (On a Node binding over system codec libraries every object referenced the runtime
# 26-55 times and the lowest-count object was the wrong one; the right one had its refs
# all in functions the harness never calls.)
#
# Ruby extensions interleave rb_* calls with parsing far more than thin N-API glue
# does: a hand-written parser that builds Ruby objects as it goes (rb_hash_aset per
# key, rb_str_new per token, rb_yield per event) has NO runtime-free function on the
# input path.  The boundary is then one of:
#   * the vendored or system library's C API under the extension, driven the way the
#     extension drives it; or
#   * the extension's own parser with its rb_* callbacks replaced by a recording
#     shim -- a harness-side definition of the few callback functions, linked in
#     place of the stub for those names.  Say which, and mirror what the callbacks
#     return (four-layers.md, layer 4).
#
# It needs OBJECTS: an installed platform gem (x86_64-linux, aarch64-linux-gnu) ships a
# prebuilt .so and nothing else, so run build_ext.sh VARIANT=plain first (step 3).
#
# After picking a candidate, confirm it by finding WHICH functions own the refs:
#   objdump -dr <obj> | awk '/>:$/{f=$2} /R_.*(rb_|ruby_)/{print f}' | sort | uniq -c
#   then read the file and check your target function's body is clean.
#
# Look for GVL-released work first: a function passed to rb_thread_call_without_gvl
# (or rb_nogvl) must not touch Ruby objects at all, so it is the boundary by
# construction:
#   grep -rn 'rb_thread_call_without_gvl\|rb_nogvl' ext/
#
#   PAT   override the runtime-symbol regex (default rb_*, ruby_*, st_*, onig*/Onig*)
set -uo pipefail
[ $# -ge 1 ] || { echo "usage: $0 <object files or archives...>" >&2; exit 2; }
PAT=${PAT:-'^(rb|ruby|st|onig|onigenc)_|^Onig'}
# paths as given, not basenames: an extension and a vendored library can both have a
# parser.o, and only the path says which is the library's (0 refs) and which the
# extension's (20+)
printf '%6s  %s\n' REFS OBJECT
for o in "$@"; do
  [ -f "$o" ] || continue
  printf '%6s  %s\n' "$(nm -u "$o" 2>/dev/null | awk '{print $NF}' | grep -cE "$PAT")" "$o"
done | sort -n
