# Finding the boundary: the ranking, the modes, and the four shapes

Read this when SKILL.md step 2 points here: when `find_boundary.sh` offers no Ruby-free
function on your input path, or when deciding how many entry points to harness.

## Reading the ranking

The ranking needs objects, so run `build_ext.sh VARIANT=plain` (step 3) first and come
back; the two steps are not strictly ordered. An installed gem has only the `.so`. An
archive is counted as a whole; to rank its members:

```sh
mkdir t && cd t && ar x ../out/plain/lib/lib<dep>.a && $R/find_boundary.sh *.o
```

The library's own objects showing 0 and the extension's showing dozens is the whole
picture in one view (measured: the system library's archive at 0 runtime references, the
gem's parser glue in the dozens). The lowest count is where to start reading, not the
answer: the criterion is *a function on your input path whose own body is Ruby-free*. On
the Node sibling every object of one binding referenced the runtime 26-55 times and the
lowest-count object was the wrong one.

## Modes: what earns one

Keep a mode only if it reaches library code the default does not (a different decoder,
the compressor behind a decompressor, a different parser state machine), and stop at two
or three. A mode added after the gate rebuilds the harness, and gate, smoke and self-test
all run again: on the Node sibling one run spent 5 of its 10 harness minutes on exactly
that, and six modes gated and smoked on two variants cost another an hour. Entry points
that are thin wrappers over the same call are one mode with different post-processing:
fuzz the richest one and say so.

## The four shapes when there is no single Ruby-free function

Ruby extensions interleave `rb_*` calls with parsing far more than thin N-API glue does,
so expect one of these more often than not. Say in the write-up which shape you chose.

### The parser builds Ruby objects as it goes

An `rb_hash_aset` per key, an `rb_str_new` per token, an `rb_funcall` into a handler per
event. Typical of a gem over a system library: its glue builds Ruby objects per library
event, so the boundary is **the library's C API driven the way the gem drives it**
(measured). Mirror the setup calls, the input and encoding settings and the event loop in
the same order, and serialise every event with every argument the extension reads from
it. Link no extension object (so gate check 5 is N/A, SKILL.md step 4).

### The parser IS the extension's own C

The parser entry function is in the parser source, with no library underneath. Link the
parser's objects (`EXT_OBJS="out/<v>/obj/<parser>.o out/<v>/obj/<error helper>.o ..."`)
and give the runtime calls on its path real definitions in a **shim**
(`resources/ruby_shim_template.c`, passed as `link_harness.sh ... SHIM=shim.c`). How to
write the shim, and what the template already covers: `ruby-shim.md`. Mirror what the
callbacks return (`four-layers.md`, layer 4).

### The work is a method on a `TypedData`-wrapped object

`rb_define_method` taking `VALUE self`, `TypedData_Get_Struct` inside. The object cannot
exist without the interpreter. Do not try: **copy the method body into the harness** minus
its `rb_*` calls, with a comment naming the file and lines, copy any `static inline`
helpers from the same TU verbatim, and build the struct the way the alloc function and
`initialize` do (`four-layers.md`, layer 1). Start from `harness_template.cc` all the
same: keep its driver tail (the contract line, the drivers, the ceilings) and replace its
input sections wholesale with the copied body, deleting their `#error` lines. Note the drift risk in the write-up. Smoke
crashes in that copied code can be real bugs in its original (`smoke.md`).

### The dispatch is in Ruby

The C methods are one-line wrappers, and `lib/**/*.rb` decides which native method runs,
how big a buffer it gets, how the input is chunked. `find_boundary.sh` shows every library
object at 0 and cannot tell you the logic is in `lib/`. The boundary is the library's C
API driven exactly the way the Ruby drives it, in the same order, including how it
re-chunks the input (`four-layers.md`, "The dispatch in Ruby can re-chunk the input").
