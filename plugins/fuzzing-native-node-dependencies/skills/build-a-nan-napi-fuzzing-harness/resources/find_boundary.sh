#!/bin/bash
# Rank a package's compiled objects by how much they touch the binding runtime.
#
#   find_boundary.sh $(find out/plain/Release/obj.target -name '*.o')     # every object, every depth
#
# The object with the FEWEST references is where to start reading -- but the count
# is a hint, not the criterion.  What you actually want is an object containing a
# function on your input path that touches the runtime in none of its own lines.
# On an image-processing binding over system codec libraries every object references
# N-API 26-55 times and the lowest-count object is the wrong one; the right one (the shared-helpers object, 35 refs) has
# them all in functions the harness never calls.
#
# It needs OBJECTS: if the install fetched a prebuilt there are none until you have run
# build_addon.sh VARIANT=plain (step 3), then rank them all as above.  (Not `**/*.o`:
# without `shopt -s globstar` that matches one directory level only.)
#
# If every library object scores 0 and every addon object scores 20+, and the addon
# objects are thin one-line wrappers, the logic you need to mirror is in lib/*.js
# (a streaming compression binding's decompress walks frames and picks a path in JS).  The boundary is then
# the library's C API driven the way the JS drives it; see SKILL.md step 2.
#
# Objects from a zig build sit in .zig-cache/o/<hash>/ and the archives record members
# with that path, so `ar x` recreates nested directories and `ar p` needs the exact
# member name.  Simplest: copy the .o files out of the cache by basename and rank those.
#
# After picking a candidate, confirm it by finding WHICH functions own the refs:
#   nm -uC <obj> | grep -E 'Napi::|napi_|v8::|node::'
#   then read the file and check your target function's body is clean.
#
# Look for an AsyncWorker first: in node-addon-api packages the real work usually
# sits in SomeWorker::Execute(), which may not touch the runtime at all and is then
# the boundary by construction:
#   grep -rn 'AsyncWorker\|::Execute()\|napi_create_async_work\|uv_queue_work' src/
set -uo pipefail
[ $# -ge 1 ] || { echo "usage: $0 <object files...>" >&2; exit 2; }
PAT='(^|[^A-Za-z0-9_:])(Napi|v8|node)::|\bnapi_|\bnode_api_'
# paths as given, not basenames: two targets can both have a match.o, and only the path
# says which is the library's (0 refs) and which the addon's (20+)
printf '%6s  %s\n' REFS OBJECT
for o in "$@"; do
  [ -f "$o" ] || continue
  printf '%6s  %s\n' "$(nm -uC "$o" 2>/dev/null | grep -cE "$PAT")" "$o"
done | sort -n
