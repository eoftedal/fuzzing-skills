# The four layers a faithful harness mirrors, with the cases that taught them

Read this when step 4 of SKILL.md tells you to, or when the gate mismatches and you
suspect the harness rather than the oracle. Each section is one layer; each case names
the symptom you would have seen without it.

## Layer 1 — the object the runtime owns

The fields you must initialise and later free are usually **private**, and patching the
header would mean the object you link is no longer the published package. Reach them
with the explicit-instantiation trick, which is exempt from access checking and needs no
source edit:

```cpp
template <typename Tag, typename Tag::type M> struct Rob {
  friend typename Tag::type rob(Tag) { return M; }
};
struct FieldTag { typedef <FieldType>* Obj::*type; friend type rob(FieldTag); };
template struct Rob<FieldTag, &Obj::_field>;          // now: obj.*rob(FieldTag{})
```

**When the boundary is a method of an `ObjectWrap` / `Nan::ObjectWrap` subclass** the
object cannot be constructed without a `CallbackInfo`, and the recipe that worked on two
targets is: copy the method body into the harness minus its runtime calls, copy any
`static inline` helper from the same TU verbatim, and for the few fields the body reads
either zero the storage (POD fields are zero in the real constructor too), placement-new
the non-trivial members (a `std::string`, an error struct), and never run the
destructor. Everything the real method calls around the boundary (the post-decode setter, the
cleanup routine, `AdjustExternalMemory`) must be mirrored or trapped, which is layer 4.
Comment the source lines you copied; the copy drifts when the package updates.

Look for a library factory first (`xxx_make_context`, `xxx_new_from_buffer`): most
libraries with a C API have one and the problem vanishes. Only fabricate if the runtime
allocates it, and then never `memset` a C++ object: zeroed memory is not a valid
`std::string`, so every *error* path crashes while valid inputs look perfect.
Placement-new the non-trivial members and mirror every field the real constructor sets;
one of them usually guards a whole branch.

Case: an image-decoding binding's four fields (surface, data, data length, SVG handle)
were private. Patching the
header would have unpublished the object; the trick above cost six lines.

## Layer 2 — the option layer, and the dispatch that often lives in JS

Read `lib/*.js` for the defaults, then check the addon for a default-constructed
descriptor struct: it often already encodes them exactly, so constructing it and attaching
the buffer *is* the no-options call.

Then check whether the JS does more than pass options, because the **dispatch** often
lives there: it decides *which* native call runs and *how big a buffer* it gets.

Case: a decompression binding's `decompress` is not one native call. JS walks every
frame summing each frame's *declared* output size, takes a fast path that allocates
exactly that total and asserts the result, or falls back to a streaming loop sized
`max(<library chunk size>, remaining)`. A harness that called the obvious one-shot
function fuzzed a path the package never takes. Mirror the dispatch in the same order,
and mirror its **ceiling**: where the size is attacker-declared, omitting the limit turns
a correctly-refused input into a harness-only OOM that looks like a finding, and
*inventing* the limit silently refuses inputs the real package accepts.

Ask the runtime for that limit; do not quote one. It is far larger than it looks and it
changes between runtimes and architectures:

```sh
node -e "console.log(require('buffer').kMaxLength)"
node -e "try{Buffer.allocUnsafe(2**40);console.log('1 TiB ok')}catch(e){console.log(e.code)}"
```

Pass it in at build time, `-DNODE_KMAXLENGTH=$(node -p 'require("buffer").kMaxLength')`,
and `#error` when the macro is missing rather than defaulting it.

Mirror the runtime's **two distinct failures** rather than one cap, with node's own
tokens: `ERR_OUT_OF_RANGE` above the maximum length, and `ERR_MEMORY_ALLOCATION_FAILED`
when the allocator refuses a length that is legal (`Buffer.allocUnsafe` under the
sanitizer's `max_allocation_size_mb`; only the asan gate exercises this path). The
second is the branch the package's own error path handles, and it is reached by bounding
the fuzz run (`afl-fuzz -m`, or `ASAN_OPTIONS=max_allocation_size_mb` under a sanitizer,
both from `ALLOC_CAP_MB` in the campaign), not by a constant in your harness. An invented cap was measured to reject
inputs the real package accepts.

So the templates ship **no cap by default**. Both carry an **opt-in** `ALLOC_CEIL=<bytes>`
for when a declared size would otherwise make the run crawl: set it to the same value on
both arms, and apply it **only at the attacker-declared site** (`over_ceiling()` in
`harness_template.cc`, `overCeiling()` before the call in `real_harness_template.mjs`,
which reads the declared size from the input the same way), reporting
`err=alloc-ceiling`. Never wrap `Buffer.alloc*` or `malloc` globally: that also refuses
the package's internal buffers and the harness's own input copy. Say in the write-up
that a ceiling was on, and turn it off for the gate on the real corpus, because every
input it refuses is one the comparison no longer covers.

### Attacker-chosen work: `WORK_CEIL`

The same problem in time: an input field that sets an iteration count, a cost or rounds
exponent, a dimension of a loop (a password hash's cost field is `2^n` rounds, so one
byte decides milliseconds or hours). Mirror the package's own bound if it has one (read
the JS validation and the native parser). Otherwise add an **opt-in** `WORK_CEIL=<units>`,
applied identically on both arms at that field and reported as `err=work-ceiling`, so the
gate can compare the parse of a huge cost without paying for it.

* Set it for the campaign: the smoke's hangs are otherwise all that field.
* Keep high-cost seeds out of `corpus-final/`; they belong in `hangs/`.
* When the package does **not** bound the field, record it as a finding for triage: an
  input-controlled work factor is a denial of service by itself, like declared-size
  memory amplification. Quote the field and the time at its minimum and maximum.

## Layer 3 — process-global state the init block installs

```sh
grep -rn "NAN_MODULE_INIT\|NAPI_MODULE_INIT\|napi_register_module_v1\|%init" $SRCDIR/
grep -rniE "MemSetup|SetAllocator|RegisterNode|_default\(|SetErrorFunc" $SRCDIR/
```

This is the one people skip, and it is invisible from the call you are harnessing.

* **Library configuration.** A **custom allocator** matters most, because it decides heap
  layout and therefore what a sanitizer can see at all. Case: one binding wraps every
  allocation with an 8-byte header, and the identical injected under-read is reported by
  a default-allocator harness and **invisible** with the allocator mirrored. Node/alloc
  counters and error handlers are cheap to mirror and buy real coverage.
* **Callbacks that are the binding's whole purpose.** A SAX-style library does the work
  only when a handler is installed. Case: one XML parser walks attribute lists, decodes
  text runs and assembles comments *because* the binding registered its handlers at
  construction (nine setter calls installing ten callbacks). Parse with none and you skip most of what the package exercises. Mirror
  the full handler set, reading exactly the arguments the real handlers read
  (`Nan::New(name)` calls `strlen(name)`; a handler striding an attribute array in pairs
  until NULL; a text handler reading exactly `len` bytes) so any over-read the library
  commits while building them is still committed. Mirror the **return value** too: the
  same binding's unknown-encoding handler returns an error status when no JS listener
  answered, so a default parser *rejects* unknown encodings. Returning OK would open a
  branch the package never takes.

Make the runtime-only branches inside a mirrored hook **trap** (`binding_path_reached`),
so "that branch is dead" is checked, not assumed.

## Layer 4 — what the binding does around the boundary, before and after

Read the *whole* exported function, not just down to the boundary call. A
post-processing step that fills in the fields the JS API exposes is common, and it is
usually **not** binding-free, so `find_boundary.sh` never offers it as a candidate.

Case: a binding's image setter called a post-decode hook *after* the decode, and that is where
width and height are set for two of its five formats. The first working harness reported
`w=0 h=0` for every input in those formats, and the gate caught it. The fix was four
lines (mirror the function minus its runtime calls) but nothing in a three-layer model
says to look.

```sh
grep -n -A40 '<ExportedMethod>' $SRCDIR/<file>.cc     # BOTH sides of the boundary call
```

## The dispatch in JavaScript can re-chunk the input

Beyond options and sizes, a JS `Transform` can drive the native stream in pieces: one
binding splits every written chunk after each `YZ` byte pair (a stream footer magic),
skips leading zero bytes after a finished member, restarts the decoder on
`STREAM_END`, and sends a final `code(null)` on flush. A corpus file is then one input
but the library sees several calls, and any seed containing that byte pair exercises the
multi-call path. Mirror the state machine, not just the options, and note the byte
pattern for the corpus skill.

## How the bytes are delivered

The native signature can hide the whole input contract.

Case: an incremental parser's `Parse` entry point does not take a string. It takes a
**function**, and three decisions live outside the call: `index.js` wraps a string as
`(offset) => str.slice(offset)`; the conversion layer hands that callback a **code-unit**
index (`byte_count / 2`); the addon sets the input descriptor's encoding to UTF-16 and
copies each chunk into its own fixed 32 768-unit staging buffer, so the library never
sees the caller's memory. A harness that called the one-shot `parse_string` with UTF-8
would run fine, gate green on a careless field set, and fuzz a different code path. Grep
the addon for `encoding`, callback-struct typedefs with a `read` member, and any `/ 2`
or `* 2` on offsets.

**Choose the corpus encoding so that file bytes to the API's value is lossless.** It
can delete an oracle ceiling. In that case `Buffer.toString('utf16le')` is lossless for
*arbitrary even-length bytes*, because a JS string may hold lone surrogates; a UTF-8
corpus would have been lossy for invalid sequences and made whole byte ranges
unreachable. Mirror the lossy edges too: `toString('utf16le')` drops a trailing odd
byte, so the harness uses `len / 2` units rather than inventing one.

**Several byte arguments** (a salt and a password, a pattern and a subject) go in one
file, framed with a separator the API's values cannot carry (NUL for a JS-string
argument; a length prefix for a Buffer one), split identically on both arms and
documented at the top of `harness.cc`. The corpus skill's seeds then use the same
framing, and the gate still compares what the real API consumed after the split.

**An option that selects code: framing, not a mode.** A `MODE` is for a handful of entry
points, each a campaign of its own. A free-form API argument with a large value space
that selects code paths is input: an encoding-name pair that picks one of about a
hundred and fifty converters (one function pointer per name), a regex flags string, a
format name. Frame it into the file ahead of the payload (`<from>\0<to>\0<payload>`, or
newline separated when the values cannot hold a newline), document it at the top of
`harness.cc`, and mirror whatever the binding does to the string on the way in: a
fixed-size `napi_get_value_string_utf8` buffer truncates it (63 bytes plus NUL), a JS
helper normalises it. A mode per converter would have meant a hundred and fifty
campaigns, and the fuzzer could never cross from one converter to another. Restrict the
framed names to bytes that map losslessly to the JS string (ASCII, say) and give both
arms the same `err` token for the rest, rather than letting the transcoding differ.

**NUL termination.** `node::Buffer::Data()` is raw and unterminated; a JS string via
`Nan::Utf8String` / `napi_get_value_string_utf8` is NUL-terminated and transcoded, and so
cannot carry invalid UTF-8 or anything past a NUL. Note which you have.

**When the binding itself stages the input into a fixed buffer**, an over-read past the
input really is invisible in production, and mirroring the staging buffer is the
faithful choice even though it costs sensitivity. Say so, and offer the sensitive version
behind an env var clearly labelled as *not* faithful and never used for the gate
(`EXACT=1`, corresponding to C API callers who pass an exact buffer).

## Make the library actually do the work; reset only what is safe to reset

An open is not a decode. Force evaluation and record something only real work could
produce.

Read the implementation of any reset you call in a loop. Case: an image-processing
binding's library-wide cache-drop call reads like a reset and is a *teardown* that frees its hash table
and leaves it NULL, breaking every later operation. Faithful configuration plus
`__AFL_LOOP(1000)` is usually the right answer.
