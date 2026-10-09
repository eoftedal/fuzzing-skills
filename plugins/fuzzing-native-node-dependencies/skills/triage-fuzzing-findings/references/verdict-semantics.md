# What each verdict means, and how to adapt the confirm harness

Read this when a verdict is surprising, when the package has a streaming or callback API
rather than a one-shot call, or when you are deciding how severe a finding is.

## Why a native crash outranks everything

A SIGSEGV, SIGABRT, SIGBUS, or an ASAN abort tears down the process from C++, below the
JavaScript engine. Nothing in JS runs afterward: not a `try/catch` around the call, not
`process.on('uncaughtException')`, not a `domain`, not an `unhandledRejection` handler.
That is precisely why it is the finding that matters: no amount of defensive JavaScript a
consumer writes can contain it. `confirm.sh` sees it as node exiting on a signal
(`rc >= 128`), exiting with the ASAN exit code (86), or printing a `Sanitizer:` report, and
`confirm.mjs` never gets to print a verdict.

The three build columns are different severities:

* **`npm-install(plain)` NATIVE-CRASH** — the binary a user installs crashes on this input
  with no instrumentation. Critical: reachable by any consumer, trivially a denial of
  service, and if it is a write it may be worse. This is the strongest possible result.
* **`npm-js + asan-addon` NATIVE-CRASH while the install was CLEAN or CAUGHT** — the bug is
  real (an over-read, a small overflow, a use-after-free) but the release build does not
  fault on it today; it reads or writes memory it should not and happens to survive. Still
  a vulnerability, lower urgency, and fragile: a compiler change or a different allocator
  can turn it into the first case.
* **`npm-js + pristine-addon` NATIVE-CRASH** — the sanitizer without the fuzzer's coverage
  instrumentation. This is the control that answers the first question a maintainer asks:
  *did your instrumentation invent this bug?* A finding that reproduces here is not an
  instrumentation artifact, and that sentence belongs in the report. A finding that
  reproduces **only** on the instrumented ASAN build is suspect and goes back to the
  harness skill. Note that inlining differs between the two builds, so the pristine build
  may name a different frame #0 for the identical bug — compare the allocation and the
  access, not the frame text.

## CAUGHT vs UNCAUGHT: both are JS errors, only one is defensible

Once node is still alive to report a verdict, the question is whether a consumer who writes
ordinary defensive code is safe.

* **CAUGHT** — the call threw synchronously, or it returned a Promise that rejected. A
  `try { await lib.call(x) } catch {}` stops it. This is the package doing its job: it
  turned a bad input into a catchable error. Report it as a robustness note, not a crash.
* **UNCAUGHT** — the error reached the process only through `uncaughtException` or
  `unhandledRejection`. Two common shapes: an `EventEmitter` that emits `'error'` with no
  listener (node rethrows it), and a throw from an async callback (a `setImmediate`, a libuv
  completion) that the package never tied to the Promise it handed you. A call-site
  `try/catch` does not catch either. The consumer survives only if they installed a global
  `process.on('uncaughtException')` handler, which crashes the process by default and which
  most programs do not have. Treat it as a denial of service.

The distinction is real and worth getting right: it is the difference between "wrap it in
try/catch" advice that works and advice that does not.

## HANG: a timeout is not a clean run

The call neither returned nor errored within `TIMEOUT_MS`. That is an algorithmic denial of
service through the public API, and no `try/catch` or global handler stops it — the event
loop never comes back. Raise `TIMEOUT_MS` once to separate "infinite" from "merely slow on
a 200-byte input", then report it with the time it took and the input size. `confirm.sh`
also reports `HANG(cell-timeout)` when node outlives `CELL_TIMEOUT` seconds entirely, which
is the case where the native code is spinning with the loop blocked.

Distinguish where it hangs, because the two have different owners:

* **The bare harness hangs** (`triage/screen` shows `rc=124`, and the bucket is
  `NO-REPORT hang`). The native code loops with node deleted from the picture — the
  library's own bug, reachable by any consumer who reaches that boundary. This is the
  stronger claim and it needs no JavaScript at all to demonstrate.
* **Only the node stack hangs** (`HANG` in step 3, bare harness fine). The loop is in the
  binding or the package's JS, or it depends on setup the harness does not mirror.

Either way it is a denial of service, and the reason it outranks "the package threw" is
that there is no consumer-side mitigation for the synchronous case: a native call that
loops cannot be interrupted from JavaScript — not by `try/catch`, not `Promise.race`, not
`AbortController` — because the event loop never regains control. The async case costs one
libuv threadpool thread per input, and the pool is 4 by default, so a handful of such
inputs stalls every other async operation in the process.

AFL's own `hangs/` directories are a separate pile that is often larger than `crashes/`
(one stylesheet-compiler binding campaign: 13 crashes, 49 hangs). The driver screens them with `HANGS=1`,
buckets them by where the loop runs (stack samples taken by interrupting the sanitized
harness with SIGABRT), and minimizes one representative per bucket with `afl-tmin -H` and a
short `-t`, re-checking the result at the full timeout.

## SKIPPED: do not launder your own ceiling into an acquittal

`confirm.mjs` caps `Buffer.alloc*` at `ALLOC_CEIL` so a declared-huge input fails the same
bounded way here as in the direct harness instead of OOM-killing node. `confirm.sh` sets it
to the same number as the sanitizer's `max_allocation_size_mb` for the bucket, so the JS
layer and the addon hit one limit, not two (an earlier fixed 64 MiB default here made the
JS layer SKIP inputs the ASAN column reported as `allocation-size-too-big`). That cap is
**ours, not the package's**, so when it fires the verdict is `SKIPPED`, not `CAUGHT`. Reporting it
as CAUGHT would say "a careful consumer is safe" about a limit this script imposed —
exactly the false acquittal the next section forbids. Re-run with `ALLOC_CEIL=` raised, or
confirm that the package's own declared-size check is what refused the input.

## Resource exhaustion: the one class where the ASAN column acquits and the install convicts

A whole campaign can be one declared-size bug. Measured on a block-compression binding: **all 17 saved crashes
are `sig:09`** — SIGKILL from the OOM killer — with *no sanitizer finding at all*, from a
five-byte input (`d8 e5 f2 ff 0c`) that declares a huge uncompressed length. The real stack
is OOM-killed after allocating ~2 GiB, or aborts on `std::bad_alloc`.

This class inverts the usual reading of the table, so recognise it before you dismiss it:

* It lands in the **`NO-REPORT signal-only sig9`** bucket, because there is nothing for a
  sanitizer to report — no memory is accessed out of bounds, the allocation simply succeeds
  and is enormous. That bucket is not noise.
* The **ASAN column acquits it**. `allocator_may_return_null=1`, which every step here sets
  deliberately so an oversized request takes the library's own failure path instead of
  aborting on every large input, is exactly what turns an OOM abort into a catchable error:
  the cell reads `CAUGHT`. The **install column** is the one that convicts, by being
  OOM-killed (`NATIVE-CRASH(sig9)`).
* `confirm.mjs`'s `ALLOC_CEIL` caps `Buffer.alloc*` only. It cannot bound an allocation the
  **C++ side** makes from a size the input declared, so for this class the ceiling neither
  protects the run nor explains the verdict.

**Quote the amplification, not the ceiling.** `minimize.sh` records, per input, the bytes
the library demanded (ASAN prints `allocator is trying to allocate 0x<hex>`) over the bytes
of input. Measured on a block-compression binding: **5 bytes in, 3,758,096,257 bytes demanded — 751,619,251x**.
That ratio is the finding and it is ceiling-independent; the ceiling only determines whether
your harness noticed. State both, because a reader needs to know the bug is real (the ratio)
and how to reproduce it (the ceiling).

The ratio also tells you how bad it is **without node**: the bare harness has no GC and no
heap limit, so a declared size the allocator accepts is simply taken, and a handful of such
inputs is an out-of-memory kill of whatever process embeds the library. Through node the JS
heap limit may turn the same input into an abort instead — still uncatchable, since the
failure is a C++ exception escaping an N-API callback.

A ceiling low enough to catch the bug must still permit the library's normal work, or the
"finding" is an artifact of the ceiling. That is what `GOOD=` checks, differentially: the
reference input's exit status at the candidate ceiling against its status with the ceiling
lifted. Demanding `rc=0` would be wrong — a corpus is full of inputs the library correctly
rejects, and those are perfectly good references.

So: for a `sig:09` bucket, read the install column, not the sanitized ones, and report it as
a resource-exhaustion denial of service with the declared size and the input length. It is a
real finding — a five-byte input that costs 2 GiB is as good a DoS as a segfault — and it is
the shape most likely to be mis-filed as "the package handled it".

## Do not manufacture a CAUGHT verdict

`confirm.mjs` deliberately registers **no** `.on('error')` on an emitter and passes **no**
options. Adding an error listener, or a mode flag that routes errors differently, converts
an honest UNCAUGHT into CAUGHT and hides the finding. Mirror exactly the call a user makes
from the README, the same one `real_harness.mjs` used for the gate.

## Do not believe a bare CLEAN

Two independent failure modes both present as a column of CLEANs, and the skill's own advice
("CLEAN on every entry point is not a finding") would then throw away real bugs:

1. **The consumer call is mis-wired.** It returns successfully while doing nothing.
   an image-decoding binding's first JS harness exited 0 for 18 files that had all failed,
   because the image object's `complete` getter it checked is hardcoded `return true`. Every CLEAN therefore
   carries `evidence=` of what the call produced, and `confirm.sh` runs a known-good seed
   (`GOOD=`) through each column first. No evidence on a seed that works ⇒ the column is
   not measuring anything.
2. **The ASAN addon never got swapped in, or got swapped into the wrong one.** `confirm.mjs` hooks `process.dlopen` rather than
   the module loader, because every native addon load funnels through it whichever way the
   package resolves its binary — `bindings`, `node-gyp-build`, node-pre-gyp, a relative
   require, or the package's own environment variable. A stylesheet-compiler binding is the
   case that breaks a loader-name interception: it `require()`s a path its own code computes,
   honouring the package's own environment variable for its binary path, so a hook on `'bindings'` never fires, the ASAN column silently
   becomes a copy of the install column, and every memory bug disappears. The verdict
   `ADDON-NOT-SWAPPED` is an error to fix, not a result to report. A package that loads
  **several** addons (a parser-runtime binding that loads a separate grammar addon) would have one `ADDON` swapped
  into all of them, so that case reports `ADDON-AMBIGUOUS` instead of a verdict; fix it with
  `ADDON_MATCH=<regex>` or `ADDON_MAP='regex=path;regex=path'`.

## Every entry point, not just the first one

Harness and confirm **every entry point the binding exposes over the same engine**. They
are not interchangeable:

* **Different byte spaces.** A JS-string argument carries bytes as
  `Buffer -> toString('utf8') -> UTF-8`, so invalid UTF-8 becomes U+FFFD and everything
  after the first NUL is cut off. A path or Buffer argument carries raw bytes. A stylesheet-compiler
  binding: 68 of 111 confirmed crashes reachable through the binding's string entry point,
  **25 only through its file-path entry point**, 18 through neither. A string-only confirm would have mis-filed all
  25 as harness artifacts.
* **Different threads.** A sync API runs the native work on the main thread; an AsyncWorker
  or callback API runs it on a libuv threadpool thread with its own, usually smaller, stack.

`confirm.mjs` computes `expressible=0|1` for each input (does it survive the UTF-8/NUL round
trip?) and prints it with every verdict, so "explained by the byte space" is a measured fact
rather than an assertion. A CLEAN/CLEAN row with `expressible=0` and no raw-byte entry point
tried is **not** a dropped finding — it is an untested one. A CLEAN/CLEAN row with
`expressible=1` is a harness defect and goes back to the harness skill's gate.

## Stack exhaustion is a special case

Its threshold is the stack limit, not the input, so the verdict is environment-sensitive in
a way no other class is. `confirm.sh` prints `ulimit -s` in its header for exactly this
reason; quote it beside any depth-sensitive verdict.

A recursive-descent parser will hand you stack exhaustion sooner or later. It shows up as a
bare `SIGSEGV` with no sanitizer frame (`NO-REPORT signal-only sig11`), it reproduces
without a sanitizer at all, and it is a real DoS: a stylesheet-compiler binding's was 170 bytes
of ordinary, valid, all-ASCII stylesheet source, and all 13 crashes from its instrumented-only campaign were this one
bug. Do not read the `NO-REPORT` bucket as noise.

Two traps. First, the ASAN build's larger frames reach the limit at a different depth than
the release build, so a marginal input can crash one and not the other for reasons that have
nothing to do with the finding. Second, if the package's native work runs on a libuv
threadpool thread, that thread has its own stack size: confirm the sync entry point too if
one exists, and say which thread the confirmed call ran on.

## The ASAN column is authoritative only over memory the instrumented build allocated

A CLEAN ASAN cell is not proof of absence. Two mechanisms:

* **The faulting allocation belongs to an uninstrumented dependency.** An image-processing binding
  over system codec libraries uses the distro's JPEG and PNG codecs, with no redzones around their scratch buffers: a hard
  crash inside a codec still shows, a 1-byte over-read does not. The same holds when the
  harness linked an instrumented **static archive** of a library the package loads as a
  system `.so`: the asan harness sees inside the library, the sanitized confirm column
  (sanitized addon, uninstrumented system `.so`) does not. A memory-safety bucket inside
  that library can read CLEAN there; it is not an artifact. Say so on the report's
  "Instrumented:" line.
* **The binding replaced the library's allocator with one that cushions the block.**
  A DOM XML-parser binding puts an 8-byte header in front of every allocation its XML
  library makes, which hides *every* under-read from ASAN — measured on an identical
  injected fault: mirrored allocator rc=0 and silent, the library's own default allocator rc=86 `heap-buffer-overflow`. Same code, same fault,
  opposite verdicts, decided entirely by who allocated the block.

The second one cuts the other way and is worth stating plainly: because the ASAN column runs
the **real** binding, the real allocator is installed, so a class of harness crash is
*correctly* CLEAN there and is genuinely unobservable in production. That is the finding —
not a false negative. Say which of the two you are looking at.

## Over-minimization: a CLEAN minimized input is not the end

`afl-tmin` shrinks against the harness it was given. Under a sanitizer that means redzones
right after each allocation, so the smallest input that trips it is the one that reads or
writes one byte past the end. The release install has no redzones: the same one-byte
over-read lands on valid heap and does not fault, and may need the original, longer input to
reach an unmapped page and segfault. So a minimized input can be CLEAN on
`npm-install(plain)` while the crash is entirely real.

`minimize.sh` names each `triage/min/<name>` after the `triage/pool/<name>` it came from,
which holds the pre-tmin bytes, and `confirm.sh` falls back to them: when the minimized
input is CLEAN on a column it re-runs the original there and reports
`CLEAN->NATIVE-CRASH(...)(orig)` if the original crashes. Only when both are CLEAN on every
entry point is the finding dropped. Report and reproduce such a finding with the original
bytes, and note that the minimized input does not reproduce on the release build.

## Artifact patterns worth recognising by name

Two shapes come from the harness rather than the library, and both are identifiable from the
bucket alone — which saves filing them and saves counting them.

* **The fabricated object.** A bucket that is CLEAN on every column whose SUMMARY points
  into a constructor, an assignment operator, or a `std::string`/`std::vector` member is
  almost certainly the harness's zeroed object, not a bug: `memset`-zeroed memory is not a
  valid `std::string`, so every *error* path crashes inside it while valid inputs pass
  perfectly. That was **43 of an image-decoding binding's 70 crash files, 0 reproduced**. Send it back to
  the harness skill (placement-new the member); do not file it and do not count it.
* **The mirrored teardown.** A `double-free`, or `attempting free on address which was not
  malloc()-ed`, inside the harness's copy of a cleanup function is a harness artifact — but
  the asymmetry it exposes is usually a real bug in the library. An image-decoding binding's SVG
  failure paths `g_object_unref()` the renderer handle without nulling it, so a faithful copy
  of its cleanup function double-frees on exactly the inputs a fuzzer produces best. Guard the harness, and report
  the asymmetry as a correctness note with the code, not as a crash.

## Adapting confirm.mjs for non-one-shot APIs

Edit the workspace copy (`$W/confirm.mjs`, copied from this skill's `resources/`), never
the plugin's file; `triage_all.sh` and `confirm.sh` use it by default, `CONFIRM=` points
elsewhere. The `ENTRIES` arms assume `lib.doTheThing(buf)` returns a value or a Promise. Replace or add
arms for other shapes; keep the handler scaffolding, the `evidence=`, and the timeout.

* **AsyncWorker / Promise** — already handled: return the Promise and the `.then(resolve,
  reject)` arms map to CLEAN / CAUGHT. A throw from inside the worker that the binding does
  not forward to the Promise becomes UNCAUGHT, which is correct. Remember this arm runs on a
  threadpool thread (see stack exhaustion above).
* **A path or file argument**: use the provided `asFile(b, ext)` helper, which writes the exact
  bytes to a temp file. This is the raw-byte entry point and it is where the inputs your
  string entry point cannot express become real findings.
* **Streaming (compression, parsers fed in chunks)** — create the stream, write the crash
  bytes, end it, and let the handlers and the timeout decide:
  ```js
  const s = lib.createStream(...);          // NO .on('error') unless a user always adds one
  s.on('data', () => {});                   // drain, or backpressure stalls the test
  s.on('end', () => finish('CLEAN', 0, ' evidence=stream-end'));
  s.end(buf);
  ```
  Whether to attach `.on('error')` is the whole question: attach it and you measure the
  careful consumer (CAUGHT); leave it off and you measure the default (UNCAUGHT when the
  stream emits an unhandled `error`). Run it both ways, as two `ENTRIES` arms, if the README
  shows both.
* **Callback properties (`obj.onload` / `obj.onerror`)** — the commonest NAN/N-API idiom,
  and the one shape with no natural slot in the ladder, because the call returns
  `undefined` and the error is delivered to a handler the *consumer* supplied. Use the
  provided `errback`/`okback`:
  ```js
  callback: () => { const obj = new lib.Thing();
                    obj.onerror = errback;            // -> CAUGHT via=callback
                    obj.onload  = () => okback(obj);  // -> CLEAN evidence=...
                    obj.src = buf; },                 // returns undefined
  ```
  An error that reaches `onerror` is **CAUGHT**: a consumer who wires the handler the README
  shows is safe. Getting this wrong is not a harmless mislabel — an arm that returns
  `undefined` and never calls `finish()` runs into the HANG timeout, so every input the
  package *correctly* rejects is reported as an algorithmic denial of service. Verified on
  an image-decoding binding: unrecognised bytes give `CAUGHT via=callback err=<its
  unsupported-format error>` through this arm and the same `CAUGHT err=...` through its
  promise-based loader —
  the two arms agree, which is the check that the arm is wired right.
* **Callback-driven (SAX)** — register the handlers the package documents, feed the buffer,
  and let an unhandled throw from a handler surface through the process handlers.

An arm that returns `undefined` must answer through its own handlers or the HANG timeout.
`confirm.mjs` deliberately does **not** print CLEAN for an undefined return, because that is
the mis-wired-call trap.

## The npm version pin

Install `<pkg>@<version>` matching the version you harnessed. If the current version is
CLEAN where your pinned version crashes, the bug was fixed upstream: report that (the fix
commit, the version) instead of filing it. If you harnessed a git clone whose version is
unpublished, install the nearest published version and say the confirmation is against that,
not against the exact tree. The column is labelled `npm-install`, not `npm-prebuilt`,
because on a platform with no prebuilt npm compiles from source and the column is then your
own compiler — worth saying in the report.

## When the harness and the npm stack disagree

A crash the harness produces but the npm stack reports CLEAN on **every** entry point is
usually one of:

* an input the public API cannot express (`expressible=0`, and no raw-byte entry point
  exists) — out of scope and legitimate;
* a path the harness reached by mirroring a dispatch the JS does differently;
* a feature compiled into your build but not into the install;
* the harness's heap differing from the real one because the binding installs its own
  allocator (see the ASAN-authority section).

The first is a result. The others mean the harness or its mirroring reached code a user
cannot, and belong back in the harness skill's gate (step 5) rather than in the report as
findings.
