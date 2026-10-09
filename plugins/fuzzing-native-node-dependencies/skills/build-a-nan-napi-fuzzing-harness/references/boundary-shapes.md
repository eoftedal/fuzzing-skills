# Three boundary shapes with no single binding-free function

Read this when step 2 of SKILL.md finds no function on the input path whose own body is
binding-free. All three shapes occurred on the first five targets this skill was tried
on, so expect one of them more often than not.

## The work is a method of an `ObjectWrap` / `Nan::ObjectWrap` subclass

(`Decoder::decodeBuffer`, `Stream::pump`.) The object cannot be constructed without the
runtime. Do not try: **copy the method body into the harness** minus its runtime calls,
with a comment naming the file and lines, and copy any `static inline` helpers from the
same TU verbatim. Link no addon object unless a binding-free helper (a translator, a
parser) lives in one. Note the drift risk in the write-up: the copy must be re-checked
when the package updates. Private fields you still need are reached with the trick in
`four-layers.md` (layer 1), which also has the recipe for the fields the body reads.

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
JavaScript can re-chunk the input").
