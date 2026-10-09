# When the gate mismatches: ceiling, bug, or your harness?

Read this when `gate.sh` reports MISMATCH on some seeds and not others. Work through the
causes in this order; the first two are cheap to check and the third is the one you
actually want to find.

## 1. The target reads out-of-bounds or uninitialised memory, so neither arm is wrong

The reported value then depends on whatever follows the allocation, or on whatever was
on the stack, which differs between an exactly sized `malloc` and the runtime's String buffer,
and between two processes. Chasing it as a fidelity problem wastes real time. Two tells:

* run **each arm twice**: stable within an arm, different between arms. (An uninitialised
  *heap* read can also differ between two runs of one arm; an uninitialised *stack* read
  is usually deterministic per binary. Both shapes are this case.)
* run the mismatching seed through the **ASAN variant**. For an out-of-bounds read it
  names the bug in one run. It does **not** see an uninitialised read: for that, build
  the library objects and the harness once with plain `clang -fsanitize=memory` (no AFL;
  a 5-minute side build; the ruby side cannot practically be MSan'd, it would need an
  MSan-built libruby) and run the seed --
  `WARNING: MemorySanitizer: use-of-uninitialized-value` with the frame is the proof.

Do this before adjusting any mirroring. Both cases here are from Node bindings (the Node
sibling plugin); the lesson is about the library, not the runtime. Case: four
mismatching seeds were an unchecked read callback. The library's read function received no buffer length at all, so a
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

## 2. The oracle's ceiling: the gem cannot report the library's bytes faithfully

**What ASAN on the Ruby side cannot see (measured, Ruby 3.3 / aarch64).** A String shorter
than about 616 bytes is stored inside its GC heap slot, not in a malloc block of its own,
and every String keeps a NUL terminator after its bytes. An over-read of a small INPUT
String therefore lands in a neighbouring GC slot or on the terminator, and the sanitized
real side reports nothing; the direct harness, which copies the input into an exactly
sized malloc block, does. Ruby has no way to hand a gem an exactly sized external buffer
as a String. So an input over-read that fires on the direct harness and is silent here is
expected, not a harness error -- confirm it from the direct side's stack (the read is of
the input buffer) and report it as such. Over-reads of the library's OWN heap buffers are
unaffected: those are malloc blocks on both sides.

A seed whose ASAN report is an over-read just past the harness's input copy, clean on the
sanitized real side, is that ceiling, not a fidelity failure. Name it in the write-up and
in triage; do not "fix" the harness to match.

**In the smoke test** it shows up as `DIRECT-ONLY`, and `smoke.sh` has no class for it.
Before fixing the harness, read the report: an over-read of the input block `run_one`
allocated, on an input under ~616 bytes, is that case; hand it to triage as a candidate
finding with that reasoning, and fix the harness only for anything else.

The gem reports through its own transformations. On the Node sibling the causes of
fake mismatches were a JS-string round trip replacing invalid UTF-8 with U+FFFD on input
*or* output, and a colour transform in a pipeline. A Ruby String keeps invalid bytes, so
the round trip itself is lossless; the Ruby equivalents are a wrapper or extension that
transcodes (`encode`, `rb_str_conv_enc`), scrubs (`scrub`, `invalid: :replace` puts in
U+FFFD or `?`), or refuses an input that is not `valid_encoding?`. Have the real side hash
the String's *bytes* (`b`, `bytes`), never its characters, and set `lossy=1`
for those inputs and let the gate drop the affected fields (`SOFT_FIELD=lossy
SOFT_DROP="out_len out_hash"`: name every field the loss changes, and a U+FFFD
substitution changes the length too) and count them separately. Never silently pass or
fail.

**Re-run the gate once the corpus skill has produced a real corpus.** A gate corpus
sized to populate both arms is too small to find the ceiling: one Node target (Node
sibling plugin) gated 70/70 clean and then reported `oracle-limited=1` on 353 seeds,
because the library accepts a byte sequence whose string form the runtime replaces with
U+FFFD. Without the soft-field mechanism already in place that would have surfaced as a flat mismatch and sent you
hunting a mirroring bug that does not exist.

Raise the ceiling when you cheaply can:

* if a *single library call with a documented default* explains the difference (one
  colourspace conversion), mirror it; stop as soon as it becomes the gem's own logic;
* if the field you wanted is simply not exposed, **swap it for one that is** rather than
  dropping it. One Node binding exposed the error *message* but no numeric code, so compare
  a hash of the message, which is strictly stronger than comparing nothing;
* if the binding's own conversion is lossy, **mirror the loss**. One Node binding did
  `if (standalone) True else False`, a C truthiness test that collapses the library's
  -1 ("absent") and 1 ("yes") into the same `true`; in an extension the same shape is
  `x ? Qtrue : Qfalse`. The harness has to collapse them
  too: the oracle can only compare what the gem reports. It is also a finding:
  through that API a consumer cannot distinguish the two.

## 3. Your harness is wrong

Only after the two above. The usual culprits, in order of frequency: a layer from
`four-layers.md` not mirrored (post-boundary processing, a registered handler, a Ruby-side
dispatch), a `-D` feature macro missing from the harness TU so a decoder is compiled out
of the harness but not the extension (use `lift_flags.sh` on the mkmf `Makefile`; mkmf
also writes `have_*` results to `extconf.h`, which the harness must include), a macro the **compiler wrapper**
injected into the library build (`FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION`; see
`build-traps.md`, and note the mismatch then runs the other way: the *harness* accepts
what the extension rejects), a NUL terminator added or omitted, an option default read
from documentation instead of from the Ruby wrapper.

A fourth shape is not a mismatch the soft field can absorb: a delivery mode whose
transcoding flips **acceptance** (on the Node sibling, a JS-string argument replacing
invalid UTF-8 with U+FFFD turned an invalid pattern into a valid one; in Ruby, a wrapper
that `scrub`s or `encode(..., invalid: :replace)`s before the call does the same).
`SOFT_DROP` only drops output fields. Gate the lossless delivery (a binary, ASCII-8BIT
String argument) and state that the transcoding mode is not gateable for invalid input.

## Two mismatches that are neither a bug nor your harness

* **The compiler is part of the message.** The oracle is built by `gem install` with
  Ruby's compiler (gcc on Ubuntu); your variants with clang. A library that puts
  `__FILE__:__LINE__` into its error text (a `[file.c:N]` suffix) gets a different line
  for a macro call that spans several lines: gcc and clang disagree on which line of the
  call `__LINE__` names. Measured on one target: a few derived seeds mismatched with equal
  output lengths, invisible to the small gate corpus and caught by the corpus re-gate. Normalise the location out of the message on BOTH sides before hashing (strip
  `" [file.c:N]"`), and say so.
* **The output is not deterministic.** A library may iterate a table in hash-seed order:
  with several declarations of one kind, the serialisation order changed from run to run,
  on the direct side and the real side alike (measured, on one target, for a rare seed). Re-running the same seed on the same binary shows it; the
  corpus skill's `nondet.sh` finds such seeds. Quarantine them out of the gate corpus
  (`corpus-nondet/`), or canonicalise the order in the artifact on both sides -- never
  loosen the gate fields to absorb it. Mutants of such a seed stay nondeterministic in
  the campaign; expect them in `stability`.
* **A single NO-OUTPUT under CPU contention.** The real side runs under a 30 s timeout
  per seed; on a host shared with other campaigns one asan gate run reported
  `no-output=1` and two re-runs were clean (measured). Re-run before debugging a
  lone NO-OUTPUT; a reproducible one is real.

## Over a system library the sanitized real side is blind inside it

When the harness links the library as an instrumented static archive (SKILL.md step 3b),
the real stack still loads the **system** shared library. `REAL_ASAN` (the asan gate's and
smoke's host side) and triage's `gem+asan-ext` column swap in only the sanitized
**extension**; the process still maps the uninstrumented, unsanitized system `.so`
(`/proc/self/maps` shows it). So:

* an overflow **inside the library** fires in the direct harness and in nothing on the
  real side but a hard crash: a smoke crash there can read `DIRECT-ONLY`, and a triage
  bucket there can read CLEAN or CAUGHT on the asan column. Read the frame before calling
  it a harness bug: a frame in the library's source is the library's, and the plain
  column (a real segfault) is the only real-stack evidence it can get;
* the gate still proves fidelity: the comparison is of results, which the uninstrumented
  library computes identically;
* the write-up and triage's report must say it: "the sanitized real-stack column runs
  against the uninstrumented system `<lib>`; memory errors inside it are visible only in
  the direct harness". Both evaluation runs on this shape had to work this out.

To give triage a sanitized real-side column for such a bucket, build the same source as an
ASAN shared library (`AFL_USE_ASAN=1`, or plain clang `-fsanitize=address`,
`--enable-shared`) and put its directory first in `LD_LIBRARY_PATH` for that column only;
check `/proc/self/maps` that it is the one mapped. Do this per finding, not up front.

## The five checks

1. **Every seed reaches the library.** Exit 0 licenses nothing.
2. **Byte-exact agreement on the deepest artifact the API gives you**: the serialized
   document, every pixel, or for a callback-driven library the hashed event stream. This
   is what proves the *option* mirroring, not just the parse.
3. **Both arms populated.** The corpus must contain inputs the library rejects; truncate
   and bit-flip a few seeds. `MIN_ARMS=1` only for a target that cannot reject (per mode:
   `:min_arms=1` in `MODES=`). The gate corpus also needs **one seed per branch of the
   mirrored dispatch** (a declared size over a ceiling, each entry point behind `MODE=`),
   or the gate proves nothing about the branches the corpus skill will later exercise.
   Write one valid sample per entry point and branch, then `$R/mkgate.sh OUT=./corpus
   SAMPLES="..." [TRUNC=3] [FLIPS=3] [EMPTY=1]` writes truncations and flips of each (and
   an empty file), which populates the rejecting arm; 15 to 40 seeds in all.
4. **Coverage discriminates.** If a trivial input scores nearly as many tuples as a real
   one you are measuring init. **Unless** the decoders are in an uninstrumented system
   `.so` (`nm -D <lib.so> | grep -c sancov` is 0): then rejects out-score successes and the
   rule inverts. Check that before interpreting the numbers.
5. **The stubs stayed unreachable.** The gate reads `AFL-HARNESS-STUB` and
   `AFL-HARNESS-RUBYPATH` from stderr per seed.

A seed that crashes **both** sides is classed `CRASHES-BOTH`: not a fidelity failure but a
finding, so move it to `crashers/` with a row in `crashers.summary.tsv`, where triage picks
it up. The gate skips seeds already in `crashers/` as `known-crasher`, which is what lets
the asan re-gate over the corpus skill's `corpus-min` run without removing them first.

`JOBS` runs seeds in parallel because ruby startup dominates the gate's time.

## The real side's extension swap

With `EXT=<abs .so>`, `real_harness.rb` swaps in a sanitized extension. It intercepts
**both** `require` and `require_relative` (a gem with precompiled builds first tries
`require_relative "3.3/<name>"`, then `require "<gem>/<name>"`), then **proves** the swap
from `/proc/self/maps`, and refuses to print a result (`EXT-NOT-SWAPPED`) if the gem's own
`.so` is mapped or no load was redirected. A non-matching `EXT_MATCH` was refused that
way, and plain and ASAN-swapped runs printed identical result lines (both measured). Set
`EXT_MATCH=` (a regex on the resolved path) when the gem loads several extensions and one
is yours, `EXT_MAP='<re>=<path>;...'` for several.

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
tree. A precompiled platform gem (`<gem>-<ver>-x86_64-linux`) that loads is the same
kind of asset; on the Node sibling a prebuilt built with GCC 10 on Debian, against a
clang 21 harness, matched all 42 seeds byte-for-byte. `gem install` picks the platform
gem when one exists; `--platform ruby` forces a source build. Check with `md5sum` that
the `.so` under `oracle/` and the snapshotted `out/<v>/<name>.so` are not the *same
file* before counting them as two pieces of evidence.
