# When the gate mismatches: ceiling, bug, or your harness?

Read this when `gate.sh` reports MISMATCH on some seeds and not others. Work through the
causes in this order; the first two are cheap to check and the third is the one you
actually want to find.

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

A fourth shape is not a mismatch the soft field can absorb: a delivery mode whose
transcoding flips **acceptance** (a JS-string argument replacing invalid UTF-8 with
U+FFFD turns an invalid pattern into a valid one). `SOFT_DROP` only drops output
fields. Gate the lossless delivery (a Buffer argument) and state that the string mode
is not gateable for invalid input.

## The harness reports facts; the gate judges

Do not encode "this input should have produced output" in the harness. Legitimate inputs
produce none, and error-recovering parsers produce output on rejection. Assert only
genuinely impossible states, and only ones you have checked against the library.

## Comparison strength

Compare the **deepest artifact** the API will give you: the serialized document, every
decoded pixel, or for a callback-driven library the **event stream** (tag, names,
attribute pairs, text bytes) hashed on both sides. A width and a height can agree while
every byte differs, and an event *count* can agree while the contents differ.

Compare against an **independently installed** copy (the `oracle/` install from step 1).
Agreeing across a version and a toolchain is far stronger than agreeing with your own
tree. A prebuilt that loads is the same kind of asset: one was GCC 10 on Debian against
a clang 21 harness, and all 42 seeds matched byte-for-byte. Check with `md5sum` that
the oracle install and the snapshotted prebuilt are not the *same file* before counting
them as two pieces of evidence.
