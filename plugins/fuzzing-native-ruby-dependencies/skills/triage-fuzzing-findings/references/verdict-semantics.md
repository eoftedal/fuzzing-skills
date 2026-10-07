# What each verdict means, and how to adapt the confirm harness

Read this when a verdict is surprising, when the gem has a block, handler, IO or threaded API
instead of a one-shot call, or when you are deciding how severe a finding is.

## Measured: the verdict ladder, end to end

This was run on Ruby 3.3.8 / clang 21 / AFL++ 4.33c / aarch64 Linux, against a **fabricated
fixture gem**. Its C extension misbehaves on purpose, once per input byte. It is not a real
target: it shows that each misbehaviour lands in the verdict this file says it does.

| fixture misbehaviour | `gem-install(plain)` | `gem+asan-ext` | `gem+pristine-ext` |
|---|---|---|---|
| segfault | NATIVE-CRASH(bug-Segmentation-fault) | NATIVE-CRASH(bug-Segmentation-fault) | NATIVE-CRASH(bug-Segmentation-fault) |
| C loop holding the GVL | HANG(cell-timeout) | HANG(cell-timeout) | HANG(cell-timeout) |
| `rb_memerror()` | UNCAUGHT | SKIPPED | SKIPPED |
| 1-byte heap over-read of a `malloc(16)` block | CLEAN | NATIVE-CRASH(heap-buffer-overflow) | NATIVE-CRASH(heap-buffer-overflow) |
| `rb_raise(rb_eArgError, …)` | CAUGHT | CAUGHT | CAUGHT |
| Ruby-level infinite recursion (SystemStackError) | UNCAUGHT | UNCAUGHT | UNCAUGHT |
| exception in a thread the gem started | UNCAUGHT | UNCAUGHT | UNCAUGHT |

Liveness on a good input: `CLEAN evidence=bytes=12`. Nothing in this file has yet been
measured on crashes from a real gem campaign. Anything attributed to "the Node sibling" was
measured on Node bindings and is kept here because the mechanism carries over.

## Why a native crash outranks everything

A SIGSEGV, SIGBUS, SIGABRT or an ASAN abort tears the process down from C, below the
interpreter. Ruby installs its own SIGSEGV/SIGBUS handler, but only to print a `[BUG]`
report (`x.rb:8: [BUG] Segmentation fault at 0x…`, the C backtrace and the Ruby backtrace)
and then `abort()`. No `rescue` runs, not even `rescue Exception`. No `ensure` runs and no
`at_exit` runs. No defensive Ruby a caller writes can contain it. `confirm.rb` never prints a
verdict, so `confirm.sh` reads the crash from the output and the exit status, in this order:

1. a full sanitizer report: `ERROR: AddressSanitizer: heap-buffer-overflow …` gives
   `NATIVE-CRASH(heap-buffer-overflow)`;
2. Ruby's `[BUG]` line gives `NATIVE-CRASH(bug-Segmentation-fault)`. This names the signal
   Ruby reported, not the SIGABRT that ended the process;
3. a bare `AddressSanitizer:DEADLYSIGNAL` gives `NATIVE-CRASH(deadlysignal)`;
4. a signal exit status gives `NATIVE-CRASH(sigN)`, and the ASAN exit code 86 gives
   `NATIVE-CRASH(asan)`.

Under the preloaded ASAN runtime, Ruby's handler replaces ASAN's SIGSEGV handler. A wild
pointer therefore still reads `bug-Segmentation-fault` in the sanitized columns, as it did in
all three columns of the fixture. Only an *instrumented* bad access, which ASAN catches
before any signal, gets a named report.

The three build columns carry different severities:

* **`gem-install(plain)` NATIVE-CRASH**: the extension a user builds with `gem install`
  crashes on this input with no instrumentation. This is critical and the strongest
  possible result. Any caller can reach it, it is trivially a denial of service, and it may
  be worse if it is a write.
* **`gem+asan-ext` NATIVE-CRASH while the install was CLEAN or CAUGHT**: the bug is real
  (an over-read, a small overflow, a use-after-free), but the release build happens to
  survive it today. This is still a vulnerability, at lower urgency, and it is fragile: a
  compiler change or a different allocator can turn it into the first case. The fixture's
  1-byte over-read is exactly this row: CLEAN / heap-buffer-overflow / heap-buffer-overflow.
* **`gem+pristine-ext` NATIVE-CRASH**: the sanitizer without the fuzzer's coverage
  instrumentation. This is the control for the first question a maintainer asks: *did your
  instrumentation invent this bug?* A finding that reproduces here is not an instrumentation
  artifact, and that sentence belongs in the report. A finding that reproduces **only** on
  the instrumented ASAN build is suspect and goes back to the harness skill. Inlining
  differs between the two builds, so compare the allocation and the access, not frame #0.

## CAUGHT vs UNCAUGHT: both are Ruby exceptions, and only one is defensible

When ruby is still alive to report a verdict, the question is whether a caller who writes
ordinary defensive Ruby is safe. Ordinary defensive Ruby is `rescue => e`, which rescues
**StandardError** and nothing else.

* **CAUGHT**: the call raised a StandardError. Usually that is the extension's own
  `rb_raise(rb_eArgError, …)`, or the gem's error class, which is a StandardError when it
  follows convention. `rescue => e` stops it. That is the gem doing its job, so report it as
  a robustness note, not a crash. One caveat applies: `rb_raise` **longjmps** out of the C
  frames between the raise and the nearest Ruby `rescue`. Unless the extension wrapped them
  in `rb_ensure`/`rb_protect`, their cleanup never runs. A CAUGHT on an error path can
  still leak a library context per call, or leave a half-built object whose `dfree` runs
  later in GC. This was not measured here; read the error path before calling a CAUGHT
  harmless.
* **UNCAUGHT**: the exception escapes `rescue => e`. `confirm.rb` reports four shapes,
  marked by `via=`:
  * **an Exception that is not a StandardError** (`via=<class>`): `NoMemoryError` (`rb_memerror`, or an
    allocation Ruby could not satisfy even after a GC), `SystemStackError`, `ScriptError`
    (including `NotImplementedError`, which is what the template's unfilled `default` arm
    raises), `Interrupt`/`SignalException`. It propagates to the top of its thread; in the
    main thread, that ends the program.
  * **`via=thread`**: an exception killed a Thread the gem started. `confirm.rb` records
    thread deaths by prepending `Thread#initialize` and deliberately does **not** join the
    thread, because joining would be adding a handler the user does not write. The caller's
    rescue never sees the exception, and the work that thread was doing is lost. Whether
    the process dies depends on `Thread.abort_on_exception`; whether the caller hangs
    depends on whether it waits for a result that never comes.
  * **`via=fatal`**: `rb_fatal`. This cannot be rescued at all.
  * **`via=SystemExit`**: the gem called `exit` from inside the call. (`via=exit` is the
    same thing when it happens outside the rescued call, for example in a gem thread.)

  The caller survives only with `rescue Exception` or the specific class, which most code
  does not write and style guides discourage. Treat UNCAUGHT as a denial of service and name
  the shape.

The distinction is the difference between "wrap it in `rescue => e`" advice that works and
advice that does not.

## HANG: a timeout is not a clean run

The call neither returned nor raised within `TIMEOUT_MS` (default 10000). That is an
algorithmic denial of service through the public API. Raise `TIMEOUT_MS` once to separate
"infinite" from "merely slow on a 200-byte input", then report it with the time it took and
the input size.

There are two forms, and the difference is diagnostic:

* **`HANG`**: `confirm.rb`'s own watchdog thread answered. Ruby was still switching threads,
  so the loop either released the GVL (`rb_thread_call_without_gvl`) or runs in Ruby code.
* **`HANG(cell-timeout)`**: the watchdog never ran. A C loop that holds the GVL never reaches
  an interrupt check, so no other Ruby thread is scheduled. Ruby also defers signal handling
  to interrupt checks, so **SIGTERM is ignored**. Measured: a cell ran 10 minutes past an
  8 s `timeout`. `confirm.sh` therefore runs each cell under `timeout -k 2 $CELL_TIMEOUT`
  (default 30 s), so SIGKILL follows 2 s after TERM, and reports a 137 at the full timeout as
  `HANG(cell-timeout)`. A 137 *before* the timeout is a real SIGKILL from outside, for
  example the OOM killer, and reads `NATIVE-CRASH(sig9)`.

The reach follows from the same mechanism. A GVL-holding loop cannot be interrupted from
Ruby: `Timeout.timeout` and `Thread#raise`/`#kill` are delivered at interrupt checks, like
the signal, so neither can stop it. The loop also stalls **every** Ruby thread in the
process, which for a threaded server means every request, and only SIGKILL ends it. A loop
that released the GVL leaves the other threads running but holds its own thread
indefinitely, unless the extension registered an unblocking function.

Find where it hangs, because the two cases have different owners:

* **The bare harness hangs** (`triage/screen` shows `rc=124`, and the bucket is a
  `hang in …` or `NO-REPORT hang`). The C code loops with Ruby removed from the picture.
  That is the library's own bug, reachable by any caller who reaches that boundary, and it
  is the stronger claim.
* **Only the ruby stack hangs** (`HANG` in step 3, bare harness fine). The loop is in the
  extension glue or the gem's Ruby, or it depends on setup the harness does not mirror.

AFL's own `hangs/` directories are a separate pile that is often larger than `crashes/`
(Node sibling, one campaign: 13 crashes, 49 hangs). The driver screens them with `HANGS=1`
and buckets them by where the loop runs, using stack samples taken by interrupting the
sanitized harness with SIGABRT. It minimizes one representative per bucket with
`afl-tmin -H` and a short `-t`, re-checking the result at the full timeout.

## SKIPPED: do not launder your own ceiling into an acquittal

In the sanitized columns, `confirm.sh` runs with `allocator_may_return_null=1` and the
bucket's own `max_allocation_size_mb`, the ceiling the input reproduced at (`cap.tsv`, else
`ALLOC_CAP_MB`). An allocation over that ceiling then returns NULL. Ruby's `xmalloc` runs a
GC, retries, and raises `NoMemoryError`. That ceiling is **ours, not the gem's**. So in a
sanitized column (`ALLOC_CEIL` set, which `confirm.rb` uses only as the "a cap is on" flag),
`NoMemoryError` reads `SKIPPED`, not CAUGHT and not UNCAUGHT. In the plain column there is
no cap, so the same NoMemoryError is the gem's real behaviour and reads `UNCAUGHT`. The
fixture's `rb_memerror` row is exactly UNCAUGHT / SKIPPED / SKIPPED. Re-run with the ceiling
raised, or confirm that the gem's own declared-size check is what refused the input.

## Resource exhaustion: the one class where the sanitized columns acquit and the install convicts

A whole campaign can be one declared-size bug. On the Node sibling (a block-compression
binding), **all 17 saved crashes were `sig:09`**: SIGKILL from the OOM killer, with *no
sanitizer finding at all*, from a five-byte input that declares a huge uncompressed length.

This class inverts the usual reading of the table, so recognise it before you dismiss it:

* It lands in the **`NO-REPORT signal-only sig9`** bucket, because nothing is accessed out
  of bounds and there is nothing for a sanitizer to report. The allocation simply succeeds
  and is enormous. That bucket is not noise.
* **The sanitized columns acquit it.** `allocator_may_return_null=1` turns the oversized
  request into NULL, so the cell reads `SKIPPED` when Ruby raises NoMemoryError. It reads
  `CAUGHT` if the extension checks the NULL and raises its own StandardError.
* **The plain column convicts**, in one of three ways. Linux overcommit hands out the
  memory, the extension touches it, and the OOM killer ends ruby early
  (`NATIVE-CRASH(sig9)`). Or malloc refuses and Ruby raises NoMemoryError (`UNCAUGHT`). Or
  the extension dereferences the NULL it got back (`NATIVE-CRASH(bug-Segmentation-fault)`).
  For an `out-of-memory` or `sig9` bucket, read the plain column, not the sanitized ones.

**Quote the amplification, not the ceiling.** `screen.sh` and `minimize.sh` record, per
input, the bytes the library demanded (from ASAN's `allocator is trying to allocate
0x<hex>`) divided by the bytes of input. On the Node sibling: **5 bytes in, 3,758,096,257
bytes demanded, 751,619,251x**. That ratio is the finding and it does not depend on the
ceiling; the ceiling only decides whether your harness noticed. State both: the ratio shows
the bug is real, and the ceiling shows how to reproduce it. The C heap is outside Ruby's GC
and Ruby sets no limit on it, so a handful of such inputs is an out-of-memory kill of
whatever process embeds the gem.

A ceiling low enough to catch the bug must still permit the library's normal work, or the
"finding" is an artifact of the ceiling. `GOOD=` checks that differentially: the reference
input's exit status at the candidate ceiling against its status with the ceiling lifted. A
reference the library correctly rejects is a perfectly good reference.

## Do not manufacture a CAUGHT verdict

The arms in `confirm.rb` contain **no** `rescue` and pass **no** options. Adding a
`rescue` inside an arm, an `on_error:` option, a `Thread#join`/`#value` the README does
not show, or `Thread.abort_on_exception = true` changes what is measured. Each converts an
honest UNCAUGHT or thread death into CAUGHT, or into a raise the caller would not get, and
hides the finding. Mirror exactly the call a user makes from the README, the same call
`real_harness.rb` used for the gate. Do not carry over `real_harness.rb`'s opt-in
`over_ceiling?`/`over_work?` refusals either: they are the gate's ceilings, and they would
turn a declared-size bug into a refusal a user never gets.

## Do not believe a bare CLEAN

Two independent failure modes both look like a column of CLEANs. The skill's own advice
("CLEAN on every entry point is not a finding") would then throw away real bugs:

1. **The consumer call is mis-wired.** It returns successfully while doing nothing. Every
   CLEAN therefore carries `evidence=` (`bytes=N`, `array=N`, `<Class>.to_s=N`,
   `type=nil`), and `confirm.sh` runs `GOOD=` through the plain column first. It warns when
   the seed is not CLEAN or its evidence is `type=nil`, `bytes=0` or `…=0`. On the Node
   sibling, a JS harness "confirmed" success for 18 files that had all failed, because the
   getter it checked was hardcoded `return true`. Ruby has no Node-style "returned
   undefined and the loop went idle" case, because the call is synchronous. A `nil`-returning
   arm is the equivalent trap, and the liveness warning is where it shows.
2. **The ASAN extension was never swapped in, or was swapped into the wrong one.**
   `confirm.rb` intercepts both `require` and `require_relative`: a source build loads
   `x/x` from the extension dir on `$LOAD_PATH`, while a precompiled layout uses
   `require_relative`. It then believes `/proc/self/maps`, not the hook. `swap=` reports
   `absent` (no EXT for this column), `swapped`, `NOT-SWAPPED` (the gem's own `.so` is
   mapped or the replacement is not) or `AMBIGUOUS-SWAP` (one `EXT` replaced two different
   extensions). `confirm.sh` turns the last two into `EXT-NOT-SWAPPED`/`EXT-AMBIGUOUS`,
   which are errors to fix, not results. A NATIVE-CRASH pre-empts the check, so prove the
   swap once with `GOOD` by hand (SKILL.md, Step 3). Keep the replacement's file name: Ruby
   calls `Init_<basename>`.

## Every entry point, not just the first one

Harness and confirm **every entry point the gem exposes over the same engine**. They are not
interchangeable, but the reasons differ from Node:

* **Byte space is mostly not the reason in Ruby.** A Ruby String carries arbitrary bytes. On
  the Node sibling, 25 of a stylesheet-compiler binding's 111 confirmed crashes were
  reachable only through its file-path entry point, because a JS string replaces invalid
  UTF-8 with U+FFFD and stops at NUL. A BINARY Ruby String loses nothing on the way in. The
  byte space narrows only where the extension takes the String with `StringValueCStr` (an
  embedded NUL raises ArgumentError, so CAUGHT) or uses it as a C string, or where the gem
  or the arm transcodes (`encode`, `scrub`, a UTF-8-only API that checks
  `valid_encoding?`). `confirm.rb` prints `nul=0|1` and `utf8=0|1` with every verdict, so
  "explained by the byte space" is a measured fact instead of an assertion. A CLEAN row
  with `nul=1` on a NUL-refusing entry point, and no raw-path or IO entry point tried, is
  **untested, not dropped**.
* **Different code.** A String, an IO and a path argument often reach different readers: a
  push parser fed by an IO callback, an event-callback parser and a tree-building parser, an `mmap` of the path.
* **Different threads.** A gem that runs the work in a Thread of its own runs it on that
  thread's machine stack, which is much smaller than the main thread's. See the stack
  section below.

## The oracle ceiling: the ASAN column cannot see an over-read of a small input String

Measured on Ruby 3.3 / aarch64: a String shorter than **~616 bytes lives inside its GC heap
slot**, not in a malloc block of its own, and **every String keeps a NUL terminator** after
its bytes. An over-read of the *input* String therefore lands in the terminator or in a
neighbouring GC slot, and ASAN has no redzone there. The direct harness copies the input
into an exactly sized malloc block, so it does see the over-read. A crash that is an
over-read **of the input buffer** on the direct harness can thus read CLEAN in the `gem+asan`
column for no other reason. Ruby offers no way to hand a gem an exactly sized external
buffer as a String, so do not try to fix this in `confirm.rb`.

Recognise it from the direct harness's ASAN report: the `allocated by thread T0 here:` stack
is the harness's own copy of the input, not a library allocation. That is a memory-safety
bug in the library, demonstrated on the direct harness (and the pristine one), whose effect
the gem's own String layout masks today. Report it that way. It is neither a harness defect
nor a dropped finding. A larger over-read can still reach unmapped memory, so the plain
column can still segfault where the ASAN column is CLEAN.

## Stack exhaustion is a special case

Its threshold is the stack limit, not the input, so the verdict is environment-sensitive in a
way no other class is. `confirm.sh` prints `ulimit -s` and `ruby -v` in its header for this
reason; quote them beside any depth-sensitive verdict. The main thread's machine stack is
`ulimit -s`. A Ruby Thread's machine stack is `RUBY_THREAD_MACHINE_STACK_SIZE`, which is much
smaller by default, so say which thread the confirmed call ran on.

On the direct harness, a recursive-descent parser's stack exhaustion shows up as a bare
signal with no sanitizer frame (`NO-REPORT signal-only sig11`). It reproduces without a
sanitizer and is a real DoS. On the Node sibling, a stylesheet compiler's stack exhaustion
was 170 bytes of ordinary, valid, all-ASCII source, and all 13 crashes from one campaign
were this single bug. Do not read the `NO-REPORT` bucket as noise. But first grep its stderr
for `AFL-HARNESS-STUB: entered Ruby runtime:` (see "Artifact patterns" below).

Through the gem, the reading is less certain. Ruby's SIGSEGV handler recognises a fault on
the current thread's stack guard and raises `SystemStackError` instead of printing `[BUG]`.
C-level recursion in an extension may therefore read **UNCAUGHT** (`via=SystemStackError`)
rather than NATIVE-CRASH. That is **not measured here**: the fixture's recursion was
Ruby-level, which read UNCAUGHT in all three columns. Either way it escapes `rescue => e`.
A SystemStackError raised by longjmp out of a half-finished C parse also leaves the
library's state wherever it was.

Two more traps. The ASAN build's larger frames reach the limit at a different depth than the
release build, so a marginal input can crash one and not the other for reasons unrelated to
the finding. And a gem thread's small stack can turn an input that is harmless on the main
thread into a crash.

## The ASAN column is authoritative only over memory the instrumented build allocated

A CLEAN ASAN cell is not proof of absence. There are four mechanisms:

* **Ruby's own heap.** GC slots are carved from Ruby's pages, not from individual `malloc`
  calls, so ASAN has no redzones between objects. That is the oracle ceiling above.
* **The faulting allocation belongs to an uninstrumented dependency.** If the extension links
  a system library (built with `--use-system-libraries` or the gem's equivalent), that
  library's buffers have no redzones. A hard crash inside it still shows; a 1-byte over-read
  does not. `--platform ruby` with the gem's vendored library avoids this only when the
  ASAN build also compiled the vendored library.
* **The extension routes the library's allocator through something else.** Check how it
  calls the library's allocator hooks. On the Node sibling, a parser binding put an
  8-byte header in front of every allocation its library made, which hid *every*
  under-read from ASAN. Measured on an identical injected fault: with the mirrored
  allocator, rc=0 and silent; with the library's default allocator, rc=86
  `heap-buffer-overflow`.
* **The compiler removed the bad access.** A dead read is elided. A fixture over-read
  written as a `malloc`/`free` pair around a read whose result was unused read CLEAN. A fixture or injected fault must keep the pointer opaque.

The allocator case also cuts the other way. Because the ASAN column runs the **real** gem, a
class of harness crash is *correctly* CLEAN there and genuinely unobservable in production.
That is the finding, not a false negative. Say which case you are looking at.

## Over-minimization: a CLEAN minimized input is not the end

`afl-tmin` shrinks against the harness it was given. Under a sanitizer, that means redzones
right after each allocation, so the smallest input that trips it reads or writes one byte
past the end. The release install has no redzones. The same one-byte over-read lands on
valid heap and does not fault, and reaching an unmapped page may need the original, longer
input. So a minimized input can be CLEAN on `gem-install(plain)` while the crash is
entirely real.

`minimize.sh` names each `triage/<run>/min/<name>` after the bucket file it came from, and
`confirm.sh` falls back to the pre-tmin bytes in `pool/`. When the minimized input is CLEAN
on a column, it re-runs the original there and reports `CLEAN->NATIVE-CRASH(...)(orig)` (or
`->UNCAUGHT`, `->HANG…`, `->CAUGHT`, `->SKIPPED`, `->ERROR…`). Only when both are CLEAN on
every entry point is the finding dropped. Report and reproduce such a finding with the
original bytes, and note that the minimized input does not reproduce on the release build.

## Artifact patterns worth recognising by name

Three shapes come from the harness rather than the library. Each can be identified from the
bucket alone, which saves filing them and saves counting them.

* **The stub hit.** The harness links trapping stubs for every Ruby runtime symbol it does not
  mirror (the harness skill's `gen_stubs.sh`). A stub prints `AFL-HARNESS-STUB: entered
  Ruby runtime: <symbol>` and traps, so `bucket.sh` files it as `NO-REPORT signal-only
  sig5`/`sig4`, the same bucket as stack exhaustion. It means the harness wandered into
  extension glue it does not mirror. Send it back to the harness skill; do not file it.
* **The fabricated object.** A bucket that is CLEAN on every column, whose SUMMARY points into
  a constructor, an assignment operator, or a `std::string`/`std::vector` member, is almost
  certainly the harness's zeroed struct, not a bug. Zeroed memory is not a valid C++
  object, so every *error* path crashes inside it while valid inputs pass perfectly. On the
  Node sibling, that was **43 of an image-decoding binding's 70 crash files, with 0
  reproduced**. Send it back to the harness skill (placement-new the member; mirror what the
  alloc function and `initialize` set); do not file it.
* **The mirrored teardown.** A `double-free`, or `attempting free on address which was not
  malloc()-ed`, inside the harness's copy of a cleanup function (`dfree`) is a harness
  artifact. The asymmetry it exposes, however, is usually a real bug in the library. On the
  Node sibling, an image decoder's failure paths released a handle without nulling it, so a
  faithful copy of the cleanup function double-freed on exactly the inputs a fuzzer produces
  best. Guard the harness, and report the asymmetry as a correctness note with the code, not
  as a crash.

## Adapting confirm.rb for non-one-shot APIs

The `ENTRIES` arms are zero-argument lambdas over `RAW` that return the result. Replace or add
arms for other shapes, keyed like the harness modes. Keep the scaffolding, the `evidence=`
and the timeout. A `nil` return is CLEAN with `evidence=type=nil`, so return what the call
produced.

* **A path argument**: `-> { MyGem.parse_file(as_file(".ext")) }`. `as_file` writes the exact
  bytes to a temp file. It is the raw-byte entry point when the String one cuts at NUL.
* **An IO argument**: `-> { MyGem.parse(StringIO.new(RAW)) }`, or `File.open(as_file)`
  when the gem treats a real File differently, for example by reading its `fileno`. These
  can reach different readers; if the README shows both, add both as arms.
* **A block-yielding API**: collect what the block yields and return it:
  `-> { evs = []; MyGem.each_event(RAW) { |e| evs << e }; evs }`, which gives
  `evidence=array=N`.
* **A handler object**: subclass the gem's handler (as `real_harness.rb` did), let it
  collect, then return the collection:
  `-> { h = Collector.new; MyGem::EventParser.new(h).parse(RAW); h.events }`. An
  exception raised inside a handler callback that the gem does not rescue propagates out of
  the call, and its class decides the verdict.
* **A push/streaming parser**: `-> { p = MyGem::PushParser.new(h); p << RAW; p.finish; h.events }`.
  Whether to wrap it in the error handling the README shows is the whole question. Leave it
  off to measure the default caller, put it on to measure the careful one, and run it both
  ways as two arms if the README shows both.
* **A gem that works in its own Thread** (a future, a Queue, a callback): call the result
  accessor the README shows (`.value`, `.wait`, `queue.pop`). `Thread#value` re-raising in
  the caller is then the user's own path, and its class decides CAUGHT vs UNCAUGHT. Do not
  join a thread the README does not join. A death the caller never observes is `via=thread`.
  Only threads created through `Thread.new` are recorded: `Thread.start`/`Thread.fork` and
  threads created from C skip `Thread#initialize`. A death that happens after the call
  returned is not recorded either. An arm that waits on a Queue the dead thread never fills
  reads HANG, and that is the correct verdict for that caller.

## The gem version pin

Install the version you harnessed: `gem install --install-dir oracle --platform ruby <gem> -v
<ver>`. `--platform ruby` forces a source build. A precompiled platform gem
(`x86_64-linux`, `aarch64-linux-gnu`) ships someone else's build of the extension and of
any vendored library, which is a different back end. The column is labelled `gem-install`
because it is then your own compiler's build of the published source; say so in the report.
If the current version is CLEAN where your pinned version crashes, the bug was fixed
upstream: report that (the fix commit and the version) instead of filing it. If you
harnessed a git checkout whose version is unpublished, install the nearest published
version and say the confirmation is against that, not against the exact tree.

## When the harness and the gem disagree

A crash the harness produces that the gem reports CLEAN on **every** entry point is usually
one of these:

* an over-read of the input buffer that the gem's String layout masks (the oracle ceiling)
  — a result, reported from the direct harness;
* an input the gem's API cannot express (`nul=1` through `StringValueCStr`, a transcoding
  arm) with no raw-byte entry point — out of scope and legitimate;
* a path the harness reached by mirroring a dispatch the gem's Ruby does differently;
* a feature compiled into your build but not into the install (compare `extconf.h` from
  both);
* the harness's heap differing from the real one because the extension installs its own
  allocator (see the ASAN-authority section).

The first two are results. The others mean the harness, or its mirroring, reached code a
user cannot, and they belong back in the harness skill's gate, not in the report as
findings.

## Traps the verdict-ladder test found (all fixed; recognise them if they come back)

* **The GVL hang ignored SIGTERM.** A GVL-holding loop starved `confirm.rb`'s watchdog
  thread and deferred SIGTERM indefinitely; one cell ran 10 minutes past an 8 s `timeout`.
  The fix is `timeout -k 2`, which reports `HANG(cell-timeout)`.
* **An empty crash label.** After Ruby's `[BUG]` abort, ASAN printed a bare
  `AddressSanitizer:DEADLYSIGNAL` with no report, and the label parser produced
  `NATIVE-CRASH()`. The fix checks `[BUG]` before `DEADLYSIGNAL`.
* **Every thread exit crashed under ASAN.** With ASAN preloaded, every Ruby thread exit died
  in `CHECK failed … unable to unmmap`, because ASAN munmaps Ruby's malloc'd per-thread
  signal stack as if it were its own. Any gem that starts a thread read `NATIVE-CRASH(CHECK)`
  in both sanitized columns. The fix is `use_sigaltstack=0`, which `confirm.rb` and
  `real_harness.rb` add by re-exec when ASAN is loaded.
* **The compiler removed the fixture's over-read.** A `malloc`/`free` pair with a dead read
  read CLEAN. A fixture must keep the pointer opaque.
