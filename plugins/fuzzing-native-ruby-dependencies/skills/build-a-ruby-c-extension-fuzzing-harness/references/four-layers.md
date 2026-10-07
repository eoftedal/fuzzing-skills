# The four layers a faithful harness mirrors, with the cases that taught them

Read this when step 4 of SKILL.md tells you to, or when the gate mismatches and you
suspect the harness rather than the oracle. Each section is one layer; each case names
the symptom you would have seen without it.

The cases are from the Node sibling plugin (fuzzing native Node addons), where these
layers were first found. They are about the C library and the binding pattern, not the
runtime, so they carry over; none was observed on a Ruby gem, and the Ruby mapping of
each is stated next to it.

## Layer 1 — the object the runtime owns

A Ruby C extension keeps its state in a C struct wrapped by `TypedData_Wrap_Struct` /
`TypedData_Make_Struct`, described by an `rb_data_type_t` whose `dmark`/`dfree` the GC
calls. The struct is usually defined in the `.c` file, not a header: copy the definition
verbatim into the harness (comment the source line it came from) so the layout matches
the object you link, rather than editing the extension's source.

For a C++ extension whose fields are **private**, patching the header would mean the
object you link is no longer the published gem. Reach them with the
explicit-instantiation trick, which is exempt from access checking and needs no source
edit:

```cpp
template <typename Tag, typename Tag::type M> struct Rob {
  friend typename Tag::type rob(Tag) { return M; }
};
struct FieldTag { typedef <FieldType>* Obj::*type; friend type rob(FieldTag); };
template struct Rob<FieldTag, &Obj::_field>;          // now: obj.*rob(FieldTag{})
```

**When the boundary is a method registered with `rb_define_method`** it takes `VALUE self`
and gets its struct with `TypedData_Get_Struct`, so it cannot run without the
interpreter. The recipe that worked on two Node targets carries over: copy the method
body into the harness minus its `rb_*` calls, copy any `static inline` helper from the
same TU verbatim, and build the struct the way the extension's `rb_define_alloc_func`
function and `initialize` do. An alloc function that uses `TypedData_Make_Struct` /
`ZALLOC` zero-fills, so `calloc` mirrors it; every field `initialize` then sets must be
mirrored, because one of them usually guards a whole branch. For a C++ member
(a `std::string`, an error struct) placement-new it, and never run the destructor.
Everything the real method calls around the boundary (the post-decode setter, the
`dfree` cleanup, `rb_gc_adjust_memory_usage`) must be mirrored or trapped, which is
layer 4. Comment the source lines you copied; the copy drifts when the gem updates.

Look for a library factory first (`xxx_make_context`, `xxx_new_from_buffer`): most
libraries with a C API have one and the problem vanishes. Only fabricate if the
extension allocates it, and then never `memset` a C++ object: zeroed memory is not a
valid `std::string`, so every *error* path crashes while valid inputs look perfect.

Case (Node sibling): an image-decoding binding's four fields (surface, data, data
length, SVG handle) were private. Patching the header would have unpublished the
object; the trick above cost six lines.

## Layer 2 — the option layer, and the dispatch that often lives in Ruby

Read the Ruby wrapper (`lib/**/*.rb`) for the defaults, then check the extension for a
default-constructed descriptor struct: it often already encodes them exactly, so
constructing it and attaching the input *is* the no-options call. Options reach C as a
Hash (`rb_hash_aref`, `rb_get_kwargs`) or as positional arguments the wrapper fills in;
read which.

Then check whether the Ruby wrapper does more than pass options, because the
**dispatch** often lives there: it decides *which* native method runs and *how big a
buffer* it gets.

Case (Node sibling): a decompression binding's `decompress` is not one native call. The
JS wrapper walks every frame summing each frame's *declared* output size, takes a fast
path that allocates exactly that total and asserts the result, or falls back to a
streaming loop sized `max(<library chunk size>, remaining)`. A harness that called the
obvious one-shot function fuzzed a path the package never takes. Mirror the dispatch in
the same order, and mirror its **ceiling**: where the size is attacker-declared,
omitting the limit turns a correctly-refused input into a harness-only OOM that looks
like a finding, and *inventing* the limit silently refuses inputs the real gem accepts.

Ask the runtime for that limit; do not quote one. A Ruby String's length is a `long`
(`RSTRING_LEN`), so the ceiling is far larger than it looks and differs between
architectures:

```sh
ruby -rrbconfig/sizeof -e 'p RbConfig::LIMITS["LONG_MAX"]'
# a legal size the allocator refuses -- bound the address space, or Linux overcommit
# hands out even 1 TiB (String.new(capacity: 2**40) succeeded on Ruby 3.3, aarch64):
(ulimit -v 4000000; ruby -e 'begin; String.new(capacity: 2**34); rescue Exception => e; p [e.class, e.message]; end')
```

Mirror the runtime's **two distinct failures** rather than one cap:
* a length the C API cannot represent: `rb_str_new` and friends raise `ArgumentError`,
  "negative string size (or size too big)" (the message is in libruby 3.3; which call
  sites reach it depends on the extension). From Ruby code, a size above `long` fails
  earlier with `RangeError` ("bignum too big to convert into `long'").
* a legal length the allocator refuses: `NoMemoryError`, "failed to allocate memory"
  (Ruby 3.3, aarch64, under the `ulimit -v` above). `NoMemoryError` is not a
  `StandardError`, so a gem's `rescue => e` does not catch it.
The second is the branch the gem's own error path handles, and it is reached by
bounding the fuzz run (`afl-fuzz -m`, or `ASAN_OPTIONS=max_allocation_size_mb` under a
sanitizer), not by a constant in your harness.

So the templates ship **no cap by default**. Both carry an **opt-in** `ALLOC_CEIL=<bytes>`
for when a declared size would otherwise make the run crawl: set it to the same value on
both arms, and apply it **only at the attacker-declared site** (`over_ceiling()` in
`harness_template.cc`, the matching check before the call in `real_harness.rb`, which
reads the declared size from the input the same way), reporting `err=alloc-ceiling`.
Never wrap `String.new`, `malloc` or `ruby_xmalloc` globally: that also refuses the
gem's internal buffers and the harness's own input copy. Say in the write-up that a
ceiling was on, and turn it off for the gate on the real corpus, because every input it
refuses is one the comparison no longer covers.

## Layer 3 — process-global state the init block installs

```sh
grep -rn "Init_[A-Za-z0-9_]*\s*(\|rb_define_method\|rb_define_alloc_func" $SRCDIR/
grep -rniE "MemSetup|SetAllocator|ruby_xmalloc|ruby_xfree|_default\(|SetErrorFunc" $SRCDIR/
```

This is the one people skip, and it is invisible from the call you are harnessing:
`Init_<name>` runs once at `require` and can configure the library for the whole process.

* **Library configuration.** A **custom allocator** matters most, because it decides heap
  layout and therefore what a sanitizer can see at all. Ruby C extensions often hand the
  library Ruby's allocator, e.g. `xxxMemSetup(ruby_xfree, ruby_xmalloc, ruby_xrealloc,
  ruby_strdup)`, so library memory is counted by the GC. In the direct harness libruby
  is not linked and those symbols are stubs, so the mirrored call would trap: mirror it
  with `free`/`malloc`/`realloc`/`strdup` and comment why. `ruby_xmalloc` is `malloc`
  plus GC accounting and a retry, so the block layout ASAN sees is the same (check
  `gc.c` of the Ruby you target; a build with `CALC_EXACT_MALLOC_SIZE` adds a header).
  What does differ is failure: on the real stack a refused allocation raises
  `NoMemoryError`, which longjmps out of the library mid-call, while `malloc` returns
  NULL into the library's own error path; seeds that hit the allocation ceiling can
  therefore disagree (unverified on Ruby). Case (Node sibling): one binding wraps every
  allocation with an 8-byte header, and the identical injected under-read is reported by
  a default-allocator harness and **invisible** with the allocator mirrored. GC
  accounting and error handlers are cheap to mirror and buy real coverage.
* **Callbacks that are the binding's whole purpose.** A callback-style library does the work
  only when a handler is installed. Case (Node sibling): one parser walks attribute
  lists, decodes text runs and assembles comments *because* the binding registered its
  handlers at construction (nine setter calls installing ten callbacks). Parse with none
  and you skip most of what the package exercises. Mirror the full handler set, reading
  exactly the arguments the real handlers read (`rb_str_new_cstr(name)` /
  `rb_enc_str_new_cstr` call `strlen(name)`; a handler striding an attribute array in
  pairs until NULL; a text handler reading exactly `len` bytes) so any over-read the
  library commits while building them is still committed. Mirror the **return value**
  too: on the Node sibling the same binding's unknown-encoding handler returns an error
  status when no JS listener answered, so a default parser *rejects* unknown encodings.
  Returning OK would open a branch the package never takes. The Ruby analogue is a
  handler that only succeeds when a block or a Ruby callback object is present.

Make the runtime-only branches inside a mirrored hook **trap** (`binding_path_reached`),
so "that branch is dead" is checked, not assumed.

## Layer 4 — what the binding does around the boundary, before and after

Read the *whole* method registered with `rb_define_method`, not just down to the
boundary call. A post-processing step that fills in the values the Ruby API exposes
(instance variables, a result Hash) is common, and it is usually **not** binding-free,
so `find_boundary.sh` never offers it as a candidate. Remember that any `rb_raise` or
failing `rb_*` call longjmps out: code after it in the real method does not run for
that input, and the mirror must stop at the same point.

Work the extension hands to `rb_thread_call_without_gvl` is often the cleanest boundary:
that function may not touch the Ruby API, so it is binding-free by construction. What the
method does before it (copying the String into a C buffer) and after it (building the
result) is this layer.

Case (Node sibling): a binding's image setter called a post-decode hook *after* the
decode, and that is where width and height are set for two of its five formats. The
first working harness reported `w=0 h=0` for every input in those formats, and the gate
caught it. The fix was four lines (mirror the function minus its runtime calls) but
nothing in a three-layer model says to look.

```sh
grep -n -A40 '<exported_method>' $SRCDIR/<file>.c      # BOTH sides of the boundary call
```

## The dispatch in Ruby can re-chunk the input

Beyond options and sizes, a Ruby wrapper can drive the native stream in pieces (a
`write`/`<<` method, an `each_chunk` loop). Case (Node sibling): a JS `Transform` split
every written chunk after each `YZ` byte pair (a stream footer magic), skipped leading
zero bytes after a finished member, restarted the decoder on `STREAM_END`, and sent a
final `code(null)` on flush. A corpus file is then one input but the library sees
several calls, and any seed containing that byte pair exercises the multi-call path.
Mirror the state machine, not just the options, and note the byte pattern for the corpus
skill.

## How the bytes are delivered

The native signature can hide the whole input contract.

Case (Node sibling): an incremental parser's `Parse` entry point does not take a string.
It takes a **function**, and three decisions live outside the call: the JS wrapper wraps
a string as `(offset) => str.slice(offset)`; the conversion layer hands that callback a
**code-unit** index (`byte_count / 2`); the binding sets the input descriptor's encoding
to UTF-16 and copies each chunk into its own fixed 32 768-unit staging buffer, so the
library never sees the caller's memory. A harness that called the one-shot
`parse_string` with UTF-8 would run fine, gate green on a careless field set, and fuzz a
different code path. Grep the extension for `rb_enc_get`, `rb_str_conv_enc`,
`rb_str_export_to_enc`, `StringValueCStr`, callback-struct typedefs with a `read`
member, and any `/ 2` or `* 2` on offsets; grep the wrapper for `encode`,
`force_encoding`, `scrub`, `valid_encoding?` and `unpack`.

**Choose the corpus encoding so that file bytes to the API's value is lossless.** It
can delete an oracle ceiling. A Ruby String holds arbitrary bytes in any encoding:
reading the file with `File.binread` (ASCII-8BIT) and passing it, or `force_encoding`
to the encoding the API expects, keeps every byte, including invalid sequences
(`valid_encoding?` is then false but nothing is replaced). Loss enters only where the
wrapper or the extension transcodes (`encode`, `rb_str_conv_enc`), scrubs, or refuses
an invalid String or a NUL (`StringValueCStr`). Mirror those lossy edges in the harness
rather than inventing a cleaner contract, and when the API transcodes, prefer a corpus
already in its target encoding.

**When the binding itself stages the input into a fixed buffer**, an over-read past the
input really is invisible in production, and mirroring the staging buffer is the
faithful choice even though it costs sensitivity. Say so, and offer the sensitive version
behind an env var clearly labelled as *not* faithful and never used for the gate
(`EXACT=1`, corresponding to C API callers who pass an exact buffer).

## Reset only what is safe to reset

Read the implementation of any reset you call in a loop. Case (Node sibling): an
image-processing binding's library-wide cache-drop call reads like a reset and is a
*teardown* that frees its hash table and leaves it NULL, breaking every later operation.
Faithful configuration plus `__AFL_LOOP(1000)` is usually the right answer.
