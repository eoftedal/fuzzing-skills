# Three boundary shapes with no single binding-free function

Read this when step 2 of SKILL.md finds no function on the input path whose own body is
binding-free. All three shapes occurred on the first five targets this skill was tried
on, so expect one of them more often than not. The first section (ranking a library a gyp
action builds) and the last two (whether a worker really runs on a thread, options of a
compressor mode) are for step 2 generally.

## Ranking a library a gyp action builds

A library that a gyp action builds with its own build system is not under `obj.target`
but in `out/plain/lib/`, so rank its members too, or the ranking shows only addon objects:

```sh
cd $W && . ./fuzz.env
mkdir -p t && (cd t && ar x ../out/plain/lib/lib<dep>.a && $R/find_boundary.sh *.o)
```

## The work is a method of an `ObjectWrap` / `Nan::ObjectWrap` subclass

(`Decoder::decodeBuffer`, `Stream::pump`.) The object cannot be constructed without the
runtime. Do not try: **copy the method body into the harness** minus its runtime calls,
with a comment naming the file and lines, and copy any `static inline` helpers from the
same TU verbatim. Link no addon object unless a binding-free helper (a translator, a
parser) lives in one. Note the drift risk in the write-up: the copy must be re-checked
when the package updates. Private fields you still need are reached with the trick in
`four-layers.md` (layer 1), which also has the recipe for the fields the body reads.

### When the method fans out: script the copy

"The method" is rarely one body. A loader method of an image class typically sniffs the
format and dispatches to a loader per format, each with its own helpers and callbacks:
one run copied a dozen line ranges, about a thousand lines, out of one source file. Do
not paste that by hand; script the assembly so it can be redone when the package updates:

* a hand-written `head.cc` (includes, the class declaration with only the fields the
  copied code reads, the stubs for what you strip), a generated `copy.cc`, a hand-written
  `tail.cc` (the boundary call and the template's drivers), concatenated into `harness.cc`;
* `copy.cc` extracted range by range, each preceded by a provenance comment naming the
  file and the line range (`// copied from src/<File>.cc:<from>-<to>`), with the class
  name rewritten in the same script (a portable tool: BSD `sed` has no `\b`);
* strip only what is tied to the runtime: external-memory accounting calls, the env or
  closure fields a callback carries, the `Napi::`/`Nan::` value conversions at the edge.
  Everything else is copied verbatim, including its bugs;
* link the addon's pure-C++ helper objects that the copied code calls (a BMP parser, a
  colour table) via `ADDON_OBJS` rather than copying them.

When `link_harness.sh` then reports `none: the addon objects reference no binding symbol`,
gate check 5 is vacuous: record it as N/A, and make the step-5 artifact as deep as the
API allows (below).

### When the API returns an object, not bytes

An image loader hands back an object (dimensions plus decoded pixels held natively), not
a buffer to hash. Make the artifact on both sides from the same pixels:

* **the real arm** renders the object into a raw buffer deterministically: a surface of
  exactly the object's size, a composite mode that copies rather than blends, then the
  raw pixel export; it hashes the width and height (as fixed-width integers) followed by
  the pixel bytes;
* **the harness** hashes the same width, height and the surface's rows (skipping any
  per-row padding the stride adds), in the same pixel format;
* **teardown mirrored**: the arm releases the object the way the harness does (one run
  set the image's source to an empty buffer, which runs the same native clear-data path
  the harness's destructor runs), so a bug in the release path is reached on both sides.

The copy is why the smoke run tries every crash on the real stack first: a frame in
`harness.cc` can be a real bug in copied package code (`smoke.md`).

## Every addon function is an emitter into the runtime

A SAX binding whose handlers all call `Emit`. The boundary is the library's public API
plus the addon's constructor and handler registration, mirrored (`four-layers.md`,
layer 3, has the full handler set and its return values). Link no addon object.

## The dispatch is in JavaScript

The addon's C++ methods are one-line wrappers. Case: a streaming compression binding with
a shared decoder context walks frames in JS, sums declared sizes and picks a fast or a
streaming path in `lib/`. `find_boundary.sh` shows every library object at 0 and every
addon object at 20+, and cannot tell you the logic is in `lib/*.js`. The boundary is the
library's C API driven exactly the way the JS drives it: mirror that state machine in the
same order, including how it re-chunks the input (`four-layers.md`, "The dispatch in
JavaScript can re-chunk the input"). The cue to read `lib/` is that ranking together
with glue functions that are each a few lines long.

**Read the JS stream classes in full** (the `Transform` subclasses in `lib/` and whatever
they `require`), not only the method that calls the addon: the state machine is
spread over `_transform`, `_flush` and helpers, and the gate compares what a consumer
observes, so every state and every error path counts.

**Probe the oracle before writing the harness.** Two behaviours of a JS stream decide the
gate and are cheaper to find with a throwaway `node -e` script against `oracle/` than by
reading:

* **An error raised in `_flush` surfaces on a later tick.** One raised in `_transform`
  throws synchronously out of a synchronous wrapper (`status=1`), but node catches one
  from `_flush` and re-emits it after the call has returned. So a synchronous decode of a
  truncated input *returns* its partial output, and the real harness, which prints
  synchronously, reports `status=0`; the process dies afterwards. Mirror the observable
  return (status 0, the partial output), not the later death, and record the deferred
  crash as a JS-layer finding: no try/catch at the call site can stop it, and the gate
  cannot see it.
* **A dispatch state with no handler loops forever.** A state the main loop enters but
  never leaves (a skip-data state with no case) spins on any input that reaches it.
  Mirror it as a hang (`for (;;) usleep(100000);` in the harness), keep such seeds out of
  the gate corpus (a hang on both sides is `NO-OUTPUT`, a gate failure), and write one
  minimal seed into `hangs/` by hand, so triage screens it as a finding.

## The work runs on a worker thread, or does it?

An `AsyncWorker` boundary is assumed to run on a libuv thread. Check that the JS actually
passes the async flag the native method reads (`info[2]`, an `isAsync` field): a decoder
whose wrapper never passes it runs **synchronously on the main thread**, which changes the
stack size triage reasons about and the error-surfacing above.

## Options of a mode that cannot reject

A compressor's options (quality, window size) select whole encoders. Frame them into the
input file only when the mode is about them (step 4 of SKILL.md, "How the bytes are
delivered"); otherwise the arm calls the package with its defaults, and the write-up
lists the option surface as not covered.
