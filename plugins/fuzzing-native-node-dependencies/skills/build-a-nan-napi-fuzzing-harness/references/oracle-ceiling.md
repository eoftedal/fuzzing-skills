# When the gate mismatches: ceiling, bug, or your harness?

Read this when `gate.sh` reports MISMATCH on some seeds and not others. Work through the
causes in this order; the first two are cheap to check and the third is the one you
actually want to find. When every seed fails or produces no output, start at section 0.

Before section 1, rule out **symbol interposition** (`interposition.md`): if
`check_symbols.sh` prints `INTERPOSED`, the installed package runs the runtime's copy of
the library, not the vendored one the harness links, and every diagnosis below would be
about the wrong code. Its tell is a few valid seeds with the same `out_len` (or within a
byte or two) and a different `out_hash`, which neither ASAN nor MSan explains.

## 0. Every seed fails: the command, not the seeds

The real side (`real_harness_template.mjs`) swaps in a sanitized addon with `ADDON=`
through a `process.dlopen` hook, so the swap works however the package computes its
binary's path, and it refuses to print a result (`ADDON-NOT-SWAPPED`) if no load was
redirected. It also re-homes the input into an unpooled buffer before the call.

For the asan gate the sanitizer runtime is preloaded **inside `REAL=`**, never in front of
`gate.sh`. In front, it is preloaded into afl-showmap and the direct harness as well:
every seed is `NO-OUTPUT ... rc=86` with an empty message and check 4 says `afl-showmap
produced nothing`; the gate now names that cause.

The gate's default `ASAN_OPTIONS` carry the campaign's allocation ceiling
(`allocator_may_return_null=1`, `max_allocation_size_mb=$ALLOC_CAP_MB`), so a seed
declaring a huge allocation is refused the same way on both sides instead of aborting
with `allocation-size-too-big` and no result line on one.

The gate prints the first error line of whichever side produced no output, so a wrong
`ADDON=` path or a sanitizer abort on one side is named rather than counted. If **every**
seed has no output, the command is broken, not the seeds.

## 1. The target reads out-of-bounds or uninitialised memory, so neither arm is wrong

The reported value then depends on whatever follows the allocation, or on whatever was
on the stack, which differs between an exactly sized `malloc` and the runtime's buffer,
and between two processes. Chasing it as a fidelity problem wastes real time. Two tells:

* run **each arm twice**: stable within an arm, different between arms. (An uninitialised
  *heap* read can also differ between two runs of one arm; an uninitialised *stack* read
  is usually deterministic per binary. Both shapes are this case.)
* run the mismatching seed through the **ASAN variant**. For an out-of-bounds read it
  names the bug in one run. It does **not** see an uninitialised read: for that, build
  the library objects and the harness once with plain `clang -fsanitize=memory` (no AFL;
  a 5-minute side build, the node side cannot be MSan'd) and run the seed --
  `WARNING: MemorySanitizer: use-of-uninitialized-value` with the frame is the proof.

Do this before adjusting any mirroring. Case: four mismatching seeds were an unchecked
read callback. The library's read function received no buffer length at all, so a
4-byte input over-read it; found in a single ASAN run and reproduced in a pristine,
uninstrumented build. Second case: a password-hashing binding's base64 decoder leaves
part of a 16-byte salt buffer uninitialised when the salt holds an invalid character,
and the hash the API *returns* carries those stack bytes; stable per arm, different
between arms, invisible to ASAN, named by MSan in one run. The gate's most valuable
output was a bug report, not a fidelity fix.

**Keep the gate honest while you report it.** Have the real side set `lossy=1` for exactly
the inputs that take the uninitialised path (the condition is known once you have read
the code: the invalid salt character, the MIME mode) so the gate counts them
`oracle-limited` with the output fields dropped, and write the finding down:
*uninitialised memory reaches the API on <condition>*. Never widen the condition to a
whole mode or to every input: that hides the next real mismatch.

## 2. The oracle's ceiling: the package cannot report the library's bytes faithfully

The package reports through its own transformations. Three causes have produced fake
mismatches: a JS-string round trip replacing invalid UTF-8 with U+FFFD on input *or*
output, and a colour transform in a pipeline. Have the real-stack harness set `lossy=1`
for those inputs and let the gate drop the affected fields (`SOFT_FIELD=lossy
SOFT_DROP="out_len out_hash"`: name every field the loss changes, and a U+FFFD
substitution changes the length too) and count them separately. Never silently pass or
fail.

Two more causes, both seen in a mode that hands the library a JS string rather than a
Buffer, and both found only by the corpus skill's bigger corpus (the gate corpus was
clean):

* **Lone surrogates dropped on the way in.** The binding converts the JS string to bytes
  (`Buffer::New(isolate, string)`, `napi_get_value_string_utf8`), and V8's conversion
  drops or replaces an unpaired surrogate: `"x\ud83d"` reached the library as `x`, and
  `"\ud800"` as nothing. The direct harness decoded the file's UTF-16LE itself and passed
  the surrogate through, so the arms ran different inputs. Fix on both sides, so the
  framing stays lossless: the real arm calls `.toWellFormed()` on the string before the
  API call, and the harness's UTF-16 to UTF-8 conversion maps each lone surrogate to
  U+FFFD, which is what `toWellFormed()` produces. Document the mapping at the top of
  both files, and state the ceiling: lone surrogates are no longer an input.
* **A returned string that cuts a code point.** When the library returns a byte range
  (a match, a slice) that ends or starts inside a multi-byte UTF-8 sequence and the
  binding returns it as a JS string, the partial sequence becomes U+FFFD and the bytes
  are gone. The real side sets `lossy=1` when a returned string contains U+FFFD, and the
  default `SOFT_DROP` (`out_len out_hash`) drops what it changed. The direct side keeps
  hashing the raw bytes; mirroring the replacement there would hide the case rather than
  count it.

**Re-run the gate once the corpus skill has produced a real corpus.** A gate corpus
sized to populate both arms is too small to find the ceiling: one target gated 70/70
clean and then reported `oracle-limited=1` on 353 seeds, because the library accepts a
byte sequence whose string form the runtime replaces with U+FFFD. Without the soft-field
mechanism already in place that would have surfaced as a flat mismatch and sent you
hunting a mirroring bug that does not exist.

Raise the ceiling when you cheaply can:

* if a *single library call with a documented default* explains the difference (one
  colourspace conversion), mirror it; stop as soon as it becomes the package's own logic;
* if the field you wanted is simply not exposed, **swap it for one that is** rather than
  dropping it. One binding exposes the error *message* but no numeric code, so compare
  a hash of the message, which is strictly stronger than comparing nothing;
* if the binding's own conversion is lossy, **mirror the loss**. One binding does
  `if (standalone) True else False`, a C truthiness test that collapses the library's
  -1 ("absent") and 1 ("yes") into the same JS `true`. The harness has to collapse them
  too: the oracle can only compare what the package reports. It is also a finding:
  through that API a consumer cannot distinguish the two.

## 3. Your harness is wrong

Only after the two above. The usual culprits, in order of frequency: a layer from
`four-layers.md` not mirrored (post-boundary processing, a registered handler, a JS-side
dispatch), a `-D` feature macro missing from the harness TU so a decoder is compiled out
of the harness but not the addon (use `lift_flags.sh`), a macro the **compiler wrapper**
injected into the library build (`FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION`; see
`build-traps.md`, and note the mismatch then runs the other way: the *harness* accepts
what the addon rejects), a NUL terminator added or omitted, an option default read from
documentation instead of from the JS.

**`out_hash` differs only on rejected seeds** of a streaming or callback-driven API: the
two sides disagree about the partial output. The real-side template collects output
progressively (each arm's callbacks append to a `collected` buffer) and its catch branch
hashes what was collected before the error, so the direct harness must hash the same
partial stream on a reject, not an empty one and not nothing.

A fourth shape is not a mismatch the soft field can absorb: a delivery mode whose
transcoding flips **acceptance** (a JS-string argument replacing invalid UTF-8 with
U+FFFD turns an invalid pattern into a valid one). `SOFT_DROP` only drops output
fields. Gate the lossless delivery (a Buffer argument) and state that the string mode
is not gateable for invalid input.

## 4. What the sanitized real side cannot see: a system library

When the harness links an instrumented static archive of a library the package loads as
a system `.so` (`build-traps.md`, step 3b), the two sides no longer run the same build of
the library. `REAL_ASAN` swaps the sanitized **addon** into the oracle; the library under
it is still the distribution's uninstrumented `.so`. So:

* an overflow inside the library is seen by the asan harness and not by the sanitized
  real side, which reads CLEAN, or crashes only when the corruption reaches a signal;
* agreement on a seed the library accepts still proves the mirroring, since both run the
  same library version, provided the archive was built from the version the `.so` is;
* the triage confirm table's sanitized column measures the addon only.
* gate check 4 (coverage discriminates) WARNs when most decoders are system `.so` files:
  the instrumented edges are the addon's and the one archived library's, so seeds of
  the other formats score alike. Expected; it is harmless when checks 1 to 3 pass. Say in
  the write-up which decoders the coverage saw.

State it in the write-up ("the sanitized real side runs the sanitized addon against the
uninstrumented system library; it cannot see an overflow inside the library") and in the
triage report's Scope section, on its "Instrumented:" line.

## 5. Seeds that crash a side: `CRASHES-BOTH` and `CRASHES-REAL-ONLY`

A seed that crashes both sides is `CRASHES-BOTH`, a finding in the library or in copied
package code. The gate files it itself: a copy at `crashers/gate-both-<orig>` with its
`crashers.summary.tsv` row (the corpus skill's `union_crashers.sh` keeps every row whose
file still exists), counted apart, not a failure; the original stays in the gate corpus.
Move nothing by hand. The gate skips seeds in `crashers/` as `known-crasher`,
so the asan re-gate over `corpus-min` needs no exclusions. Expect them on the asan gate
when the addon's own parsing has a bug its truncations reach: one run filed nine, every
truncation of one valid sample.

A seed that kills the real side while the direct harness returns normally is
`CRASHES-REAL-ONLY`. The gate copies it to `crashers/gate-real-<orig>` with a summary
row, counts it separately, and does **not** fail on it. It is a bug above the boundary or
in the binding's own bookkeeping, which the harness does not mirror and should not: a
runtime check failure (`Check failed: ...` from V8's external-memory accounting fed by a
custom allocator), an abort in post-processing. Triage screens `crashers/`; since the
direct harness does not crash on it, it is the confirm step against the installed
package (triage skill) that classifies it. Read the
first line of the real side's stderr before calling it a finding: an `ADDON=` path or a
missing preload breaks every seed, not one.

## The harness reports facts; the gate judges

Do not encode "this input should have produced output" in the harness. Legitimate inputs
produce none, and error-recovering parsers produce output on rejection. Assert only
genuinely impossible states, and only ones you have checked against the library.

## Comparison strength

Compare the **deepest artifact** the API will give you: the serialized document, every
decoded pixel, or for a callback-driven library the **event stream** (tag, names,
attribute pairs, text bytes) hashed on both sides. A width and a height can agree while
every byte differs, and an event *count* can agree while the contents differ.

**The gate corpus size.** `mkgate.sh` multiplies: each sample gives itself, `TRUNC`
truncations and `FLIPS` corruptions (7 files at the defaults), so 20 samples write
about 150 files, well past the 15 to 40 SKILL.md asks for. More seeds cost only gate
time, but a gate that takes minutes gets skipped later: start from five or six samples
(one per format and entry point), or lower `TRUNC=` / `FLIPS=` to 1 or 2.

The gate corpus needs more than both status arms: **one seed per branch of the mirrored
dispatch** (an unsized frame for a streaming fallback, a declared size over the ceiling,
each entry point behind `MODE=`), or the gate proves nothing about the branches the
corpus skill will later exercise.

Compare against an **independently installed** copy (the `oracle/` install from step 1).
Agreeing across a version and a toolchain is far stronger than agreeing with your own
tree. A prebuilt that loads is the same kind of asset: one was GCC 10 on Debian against
a clang 21 harness, and all 42 seeds matched byte-for-byte. Check with `md5sum` that
the oracle install and the snapshotted prebuilt are not the *same file* before counting
them as two pieces of evidence.
