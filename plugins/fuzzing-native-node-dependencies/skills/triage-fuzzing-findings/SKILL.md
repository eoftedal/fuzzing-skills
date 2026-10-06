---
name: triage-fuzzing-findings
description: Triage the crashes and hangs an AFL++ campaign produced against a native Node addon: screen them, bucket the raw reproducers by root cause, minimize one representative per bucket with afl-tmin, and confirm each one against the package installed fresh from npm — through every entry point the binding exposes — to see whether it is a real native crash or an error the package's own try/catch and handlers absorb. The goal is to separate real crashes from artifacts and already-caught errors, not to develop exploits. Use after fuzzing a NAN/N-API dependency, when asked to triage findings, minimize or dedup crashes, decide which crashes are real, or check whether a crash is caught by the package's error handling.
---

# Triage fuzzing findings

Turn a directory of crashing inputs into a short list of distinct, minimized, confirmed
findings. **Classify crashes; do not develop exploits.**

The pipeline is automated. You do three things by hand, and only three:

1. **Fill in the consumer calls** — the `ENTRIES` arms in `resources/confirm.mjs`.
2. **Run the driver.**
3. **Judge severity and write the report** from the skeleton it produces.

```sh
# 1  resources/confirm.mjs: ENTRIES = the ENTRIES object from the harness skill's
#    real_harness.mjs, pasted unchanged (same keys = the harness MODE values = the
#    manifest's `entry` column; the gate already proved those calls reach the native code)
# 2  PKG = the harness skill's oracle/ install: a fresh, pinned `npm install <pkg>` of the
#    published package (built from source where that skill said so).  No second install.
# 3  one command, run from the fuzz workspace: screens every campaign on the build that made
#    it, buckets the raw reproducers, confirms one per bucket, minimizes those, writes REPORT.md
resources/triage_all.sh \
    PKG=$PWD/oracle/node_modules/<pkg> \
    GOOD=corpus/<a gate seed with status=0> \
    ASAN_RT=$(../build-a-nan-napi-fuzzing-harness/resources/find_asan_rt.sh)
```

With `campaigns/manifest.tsv` in the workspace (written by the campaign skill) that is the
whole command — see "Manifest mode" in Step 2. Without one, also pass `ENTRIES`, `MODES` and
`ALLOC_CAP_MB` by hand.

Without `PKG` it skips confirmation and says so — and the confirm step is the only one that
answers whether a crash reaches a user.

**The scripts steer the tools; they do not replace them.** afl-tmin minimizes, the
sanitizers find and name the bugs, the npm package answers whether a user is reached. The
scripts decide how each tool is fed, how strict it is, and what counts as success, and they
check every tool's result rather than trusting its exit code.

The one question this skill exists to answer, and the harness cannot: **does the crash reach
a user, or does the package's JavaScript catch it first?** The fuzzer crashed a C++ boundary
with node deleted. A consumer reaches it through the package's JS, which may wrap the call
in `try/catch`, reject a Promise, or convert a native error into a thrown `Error`. A crash a
user cannot trigger, or one a one-line `try/catch` stops, is not the same finding as a
segfault.

---

## Step 1 — Fill in the consumer calls

Open `resources/confirm.mjs` and set `ENTRIES` to the `ENTRIES` object from the harness
skill's `real_harness.mjs`: the same arms, keyed by the harness `MODE` value, which is what
the campaign manifest's `entry` column holds (`MODE=file` → `file`; the default mode →
`default`). They were written once, where the gate proved they reach the native code, so do
not rewrite them. Check two things as you paste: **no options and no error listener you
would not expect a user to add** (an added `.on('error')` manufactures a CAUGHT verdict),
and that every `entry` the manifest names has an arm. Helpers provided here: `asFile(ext)`
for a path argument, `errback`/`okback` for callback-property APIs.

**Confirm every entry point the binding exposes.** Highest-value rule in this skill.
A stylesheet-compiler binding has a string entry point and a file-path entry point, and **25
of its 111 confirmed crashes were reachable only through the file-path one** — the string
entry point replaces invalid UTF-8 with U+FFFD before the library sees a byte. One entry point reports those 25 as artifacts.

**A harness mode is an entry point too.** Buckets found under `MODES` need an arm that
selects the same mode through the npm API — confirm.sh says so above any such table. The two
bugs found under harness `MODE=2` in the image-decoding binding's next major version (a zig
build) read CLEAN through its promise-based loader and **segfault the npm install** through
an arm that sets the image object's MIME data mode, which is what `MODE=2` sets. Without both the mode and the arm they would have been filed "does not reproduce" twice.

An arm that returns `undefined` **must** answer from its own callbacks. If it forgets, every
input runs into the timeout and reads `HANG` — a denial of service that does not exist.

---

## Step 2 — Run the driver

### Manifest mode (the default)

If `campaigns/manifest.tsv` exists, `triage_all.sh` drives from it; run it from the
workspace with nothing but `PKG`/`GOOD`/`ASAN_RT`. `NO_MANIFEST=1` forces discovery;
`MANIFEST=<path>` points elsewhere.

| from the manifest | how |
|---|---|
| campaign list, `variant`, `out_dir` | one run per campaign with `crashes/` or `hangs/` files, on that campaign's own build |
| `mode_env` | the harness mode for that campaign (`default` = none); the non-default values also become `MODES` for `crashers/` |
| `entry` | every distinct value becomes `ENTRIES` for confirm, unless you pass `ENTRIES` |
| `alloc_cap_mb` | the screening ceiling per campaign (the largest becomes the default `ALLOC_CAP_MB`) |
| `selftest`, `status` | noted, never gating: a self-test other than `passed` and any `status` other than `completed`/`switched` print a NOTE |

Still discovered, not read: the crash and bucket contents, the `GOOD` guard and the
ceiling ladder. It warns about any `crashes/`/`hangs/` directory with files that the manifest
does not list (they are not triaged; re-run the campaign or use `NO_MANIFEST=1`); the
harness skill's `smoke/` tree is skipped in that check. The corpus skill's `crashers/` and
`hangs/` (seeds that crash or hang the harness) are triaged too: against every variant, then
under each recorded non-default mode. A non-`completed` campaign's crashes are real; the absence of more
is not evidence.

Applied per campaign, with a timestamped line each: `exec_timeout_ms` sets its hang screen
(2 × it in ms, plus 1 s start-up; `HANG_MULT`/`HANG_PAD_S`), and `stability` < 90 % sets
`RETRY=5`. An explicit `TIMEOUT=` or `RETRY=` wins.

### Discovery mode (no manifest)

`triage_all.sh` finds every `crashes/` and `hangs/` under the workspace, infers the build
variant from the path, pairs it with `out/<variant>/harness-fork` (falling back to a
digit-stripped name, then to probing, because a second run of one build is routinely called
`asan2` and has no `out/asan2/`), and runs, in this order:

| step | script | does | cost on a stylesheet-compiler binding, 111 crashes |
|---|---|---|---|
| screen | `screen.sh` | what reproduces, on which build, at which allocation ceiling | 14 s |
| bucket | `bucket.sh` | group the **raw** reproducers by root cause; one representative each | 27 s → 4 bugs |
| confirm | `confirm.sh` | each representative, on its **original** bytes, through the npm package | ~0.1 s per cell |
| minimize | `minimize.sh` | **only the representatives**, with afl-tmin | 7 s for 6 |
| re-confirm | `confirm.sh` | the minimized reproducers, which are what a reader will run | ~0.1 s per cell |

The order is the point. Bucketing needs only a sanitizer report, so it runs on the raw
crashes and does the collapsing; minimization, the expensive step, then runs once per bug
instead of once per crash. On an image-decoding binding the whole pipeline including both confirmations takes
61 s; the earlier "cmin, then minimize every survivor" design ran past 20 minutes. Confirming
the original bytes before minimizing is also the safer test: the image-decoding binding's GIF
bug reads CLEAN on the npm install once minimized and crashes it only as the original. Confirm verdicts
**rank** buckets — a representative that is CLEAN on every column and entry point keeps its
original bytes instead of being minimized (`MINIMIZE_ALL=1` to minimize it anyway) — but
never remove one: a node CLEAN only means "not reachable through the arms written so far".

Per campaign you get `triage/<campaign>[.on-<build>][@<mode>]/` with `pool/ repro/ screen
buckets/ min/ keys.tsv verdicts.tsv` and the logs, plus a consolidated `triage/REPORT.md`.

Pass `ONLY=<variant>`, `SKIP_HANGS=1`, or run the scripts individually — each takes
`KEY=VALUE` arguments and documents them in its own header.

**Every phase and every slow loop prints a timestamp and elapsed seconds**, so a stall is
distinguishable from slow work and you can name the step it stalled in.
`PROGRESS_EVERY=<seconds>` sets the heartbeat interval inside long loops (default 20).

**In discovery mode, each campaign starts on the harness of the build that produced it, and
whatever does not reproduce there is offered to the other builds, then to each harness mode.** The risk of the
wrong build runs one way, measured over 161 real crashes:

| campaign | both builds | ASAN only | plain only | neither |
|---|---|---|---|---|
| stylesheet-compiler binding, plain (13) | 13 | 0 | 0 | 0 |
| stylesheet-compiler binding, ASAN (111) | 0 | **111** | 0 | 0 |
| image-decoding binding, plain (37) | 25 | **2** | 0 | 10 |

An ASAN campaign minimized against the plain build loses everything — 1-2 byte over-reads
are invisible without the sanitizer. Not one input crashed the plain build alone. And the image-
decoding binding's two crashes that only ASAN reproduces came from the *plain* campaign, which is why
stopping at the producing build was not enough. The 10 that reproduce nowhere are fork-mode
non-reproducers (persistent-mode artifacts), not crashes of the other variant.

**Harness modes.** Manifest mode takes them from `mode_env`. Otherwise, if the harness reads a
mode variable (`MODE=`, `HARNESS_MODE=`), list the non-default settings in `MODES="MODE=2 MODE=3"`. A crash found in one mode does not
reproduce in another: two crashers from the image-decoding binding's next major
version are `rc=0` by default and `rc=134` under `MODE=2` — they are a heap over-read in the
EXIF-orientation rotation and a 67 MB `memcpy` over-read, and a mode-blind screen filed both as non-reproducing. The driver
cannot discover modes; you name them, the same way you name the npm entry points.

### Reading the output

`triage/<campaign>/screen` has the per-input `rc` and milliseconds. Read it before believing
any drop:

| in `screen` / the log | means | the driver's response |
|---|---|---|
| inputs left in `nonrepro/` | reproduced on no build and in no mode tried | listed in REPORT.md with what was tried; usually persistent-mode artifacts |
| `AMPLIFICATION` lines | a small input demanded huge memory | **a DoS by itself** — report the ratio (below) |
| stability < 90 % warning | nondeterministic reproduction | pass `RETRY=5` |
| `ms` over `TIMEOUT` | slower than the tool's timeout | raise `TIMEOUT=` (default 5000) |
| `ignored because of crashing the target` | `afl-showmap` captured no trace | still a finding; it is in `screen` |

### Memory amplification is a finding on its own

The allocation ceiling (`ALLOC_CAP_MB`, **default 1024 MB**) decides whether a declared-size
bug is visible at all: the library allocates a size the input declared *before* validating
it, and the process only dies if the request exceeds the ceiling. 1 GB is already generous
for a native dependency handling a fuzz-sized input — and a ceiling of 4 GB is worse than
generous, it sits above the whole 32-bit range a declared length can express, so it acquits
every bug of this class by construction. That was the old default, and it hid a real bug.

So `screen.sh` walks a `CAP_LADDER` (default `1024 256 64`) **per input**: each rung
re-screens only what has not reproduced yet, and every input carries the ceiling it
reproduced at through bucketing, confirmation and minimization (`cap.tsv`). An
earlier version stopped at the first rung that reproduced *anything*, and a 600 MB
declared-size input sharing a pool with heap over-reads was silently dropped. It reports the
**amplification** — the bytes the library demanded divided by the bytes of input:

```
0008-...-id_000008_sig_09_src: 5 B in -> 3758096257 B demanded  (751619251x amplification)
=> RESOURCE EXHAUSTION / DoS
```

Report that ratio and the ceiling, not just `out-of-memory`. A five-byte input that makes
the library ask for 3.7 GB is a denial of service whatever absolute ceiling happens to catch
it, and it is worse on the bare harness than through node: no GC, no heap limit, nothing
between the declared size and the allocator.

**Pass `GOOD=` so the ladder cannot cry wolf.** It is what separates "this input demands
absurd memory" from "this ceiling is too small for the library's normal work". The test is
differential — `GOOD`'s exit status at the candidate ceiling versus with the ceiling lifted —
so a reference input the library legitimately *rejects* is still a usable guard. Without
`GOOD` the lower rungs are still tried but flagged unverified. If `GOOD` shows the library's
normal work needs more than 1024 MB, the ladder walks **up** (`CAP_UP`, to 16 GB) to the
first ceiling `GOOD` tolerates and screens only there.

**Minimization is afl-tmin, steered** (`references/afl-tool-reliability.md` has the
evidence). Fed through `@@`, afl-tmin's temp file reached the harness empty, so it saw every
input "terminate normally" and minimized to zero bytes with exit 0. `minimize.sh` passes
`/dev/stdin` as the harness's file argument instead, which arrives intact; lets afl-tmin
minimize freely; and retries with `AFL_TMIN_EXACT=1` only if the result's sanitizer key
drifted to a different bug. Hangs use `afl-tmin -H` with a short `-t` (`HANG_S`, default
2 s) and a re-check at the full timeout. A result that does not verify is discarded and the
original bytes kept — there is no homemade fallback.

**Do not hand-minimize further.** A stylesheet-compiler binding's stack-exhaustion reproducer resisted manual
reduction because the obvious mechanism (deep nesting) is guarded and the real one is
unbounded recursion during evaluation, past the guard.

### Buckets

Keyed on the sanitizer **SUMMARY** line — kind + `file:line` + function + access (`READ-1`,
`WRITE-8`). Never on stack frames: template-heavy C++ frame text starts with the return
type, so half the crashes file under `char`.

**Report the second grouping, merged on function.** The SUMMARY key over-separates:
a stylesheet-compiler binding's 25-crash over-read in an unchecked UTF-8 decoder is
reported at three lines of one header (`:76`, `:82` and `:84`). Exact → 6
buckets; merged → **4**, the published answer. When judging whether two reports are one bug,
compare the **allocation and the access**, not the frame text — inlining differs between the
instrumented and pristine builds.

| bucket | meaning | action |
|---|---|---|
| `NO-REPORT signal-only sigN` | crashed, no sanitizer frame | usually **stack exhaustion** — a real DoS needing no sanitizer. Not noise. |
| `hang in <function>` | the bare harness never returned | **DoS in the native code itself.** Keyed by interrupting the sanitized harness with SIGABRT at several points and taking the innermost frame common to every stack that never recurs. Approximate: a loop inside an interpreter's recursive walk (a stylesheet compiler's evaluate/expand passes) can land in a coarser bucket on another run |
| `out-of-memory` | declared-size allocation | resource exhaustion; read the **install** column |
| `NO-CRASH (rc=N)` | did not reproduce here | wrong build or mode, or a persistent-mode artifact |

Counts are distribution, not severity. An out-of-bounds **write** outranks a 1-byte read
regardless of count, which is why the access is in the key.

---

## Step 3 — Read the confirm tables

Three build columns, three questions:

| column | runs | a crash there means |
|---|---|---|
| `npm-install(plain)` | the binary a user installs | **critical**: uncatchable, any consumer |
| `npm-js+asan-addon` | published JS, ASAN addon swapped in | a real memory bug the release build hides |
| `npm-js+pristine-addon` | sanitizer, **no** coverage instrumentation | reproduces here ⇒ not an artifact of your instrumentation |

Verdict ladder, most severe first:

1. **NATIVE-CRASH** — a signal or sanitizer report. No JS handler catches a signal: not
   `try/catch`, not `uncaughtException`, not a domain.
2. **UNCAUGHT** — surfaced only through the process handlers. A call-site `try/catch` does
   **not** stop it. DoS unless the consumer installed a global handler.
3. **HANG** — no answer within `TIMEOUT_MS`. Algorithmic DoS.
4. **CAUGHT** — threw, rejected, or reached the consumer's own callback. A
   `try/catch`/`.catch()` is enough.
5. **CLEAN** — no error, with `evidence=` of what the call produced.
6. **SKIPPED** — the JS layer wanted more than `ALLOC_CEIL`, which `confirm.sh` sets to the
   bucket's own sanitizer ceiling (`cap.tsv`, else `ALLOC_CAP_MB`); proves nothing either way.
   Deliberately not CAUGHT: absorbing our own ceiling into "a careful consumer is safe"
   would be a false acquittal.

Four cells that are not verdicts — fix them, do not report them:

* **`ADDON-NOT-SWAPPED`** — the ASAN addon never loaded, so that column duplicates the
  install column and hides every memory bug. `confirm.mjs` hooks `process.dlopen`, the one
  funnel every addon load passes through, so the swap survives packages that resolve their
  binary by their own env var (a stylesheet-compiler binding honours the package's own
  environment variable for its binary path; a hook on `'bindings'` never fires). `loaded=` says which `.node` actually loaded.
* **`ADDON-AMBIGUOUS`** — several addons, one `ADDON` swapped into all of them. Set
  `ADDON_MATCH=` or `ADDON_MAP='regex=path;regex=path'`.
* **`ERROR`** — bare `ERROR`: `confirm.mjs` rejected the `ENTRY` name. `ERROR(rc=N)`: node
  died without a verdict, usually a `PKG` that will not load — classically because your
  fuzzing build overwrote the npm prebuilt, which is why `PKG` must be a fresh install.
* **`NO-VERDICT`** — node exited 0 without a verdict: the `ENTRIES` arm returned `undefined`
  and nothing kept the event loop alive (a callback that never fires, an arm that forgot
  `okback`/`errback`). The arm is mis-wired; it is not CLEAN.
* **A column of all-CLEAN** — the signature of a mis-wired consumer call, not a clean
  package. `GOOD=` runs a working seed first; no `evidence=` on it means the column measures
  nothing. An image-decoding binding's first JS harness "confirmed" success for 18 files
  that had all failed, because the image object's `complete` getter it checked is hardcoded `return true`.

A CLEAN cell on the minimized input is re-tested against the pre-tmin bytes automatically
and reported as `CLEAN->NATIVE-CRASH(...)(orig)` if those crash — minimizing happened
against the harness's redzones, which the release install lacks. On an image-decoding binding this recovered a
critical finding a naive pipeline drops; reproduce it with the original bytes.

Long form of every verdict, the cases where a CLEAN ASAN column proves nothing, stack-depth
sensitivity, resource exhaustion, and the artifact patterns to recognise:
`references/verdict-semantics.md`.

---

## Step 4 — Judge and write the report

`triage/REPORT.md` has one row per bucket with the facts and a "still to do by hand" list.
Fill in, per bug (the **merged** bucket):

* the SUMMARY — kind, `file:line`, function, `READ`/`WRITE` and size;
* which build variant found it, and the reproducer's path, size and bytes inline for a
  native crash (`od -An -tx1`);
* the verdict in every column **and every entry point**;
* the entry point a reader should use — "reachable via its file-path entry point" is the
  actionable half of the finding;
* a one-line repro.

Severity:

| verdict | severity |
|---|---|
| npm install natively crashes | **critical** |
| only a sanitized build crashes | **memory-safety bug** |
| hangs the bare harness, or `HANG` through node | **denial of service** |
| the input sets the work factor (a cost or rounds field, an iteration count) and the package does not bound it | **denial of service, time amplification**: quote the field, and the time at its minimum and at the largest value accepted; a hang bucket whose inputs differ only in that field is this, not a loop bug |
| the package catches it | **low** |
| CLEAN on every entry point | **not a finding** — say so and why, do not drop it silently |

An out-of-bounds write outranks a 1-byte read either way. Add the sentence the pristine
column earns: *this reproduces without the coverage instrumentation.*

**A hang is a reportable denial of service.** Do not leave it in a `NO-REPORT hang` bucket
as if it were noise. Say which of the two it is — **the bare harness hangs** (`screen` shows
`rc=124`: the native code itself loops, with node deleted; the library's bug, any consumer)
or **it hangs through node** (`HANG` in the confirm table) — and give the input size and the
budget you allowed. State the reach: **a synchronous native call that loops cannot be
interrupted from JavaScript at all** — no `try/catch`, no `Promise.race`, no
`AbortController`, because the event loop never regains control. An async/AsyncWorker call
is less bad but not safe: each hung input occupies one libuv threadpool thread, and the pool
is 4 by default, so four such inputs stall every other async operation in the process.
Raise `TIMEOUT_MS` once to separate "infinite" from "merely slow", and report the figure.

For an `out-of-memory` bucket, say which `max_allocation_size_mb` made it visible — a
declared-size bug is invisible at a ceiling above the size it declares.

State what was instrumented. "I fuzzed an image-processing binding" and "I fuzzed its JPEG codec through the
binding" are
different claims, and a bucket pointing inside an uninstrumented dependency is a
hard-crash-only result.

Do not quote crash counts as a measure of anything. Do not state a mechanism you have not
read the code for.

**If nothing is confirmed** — including no crash files at all — cite the harness skill's
detection self-test and the campaign's execs and stability. Without it, "nothing found" is
indistinguishable from "the harness detects nothing", and is not a result.

Hard crashes and memory-safety bugs in a widely installed package are sensitive. Report to
the maintainer through the package's security policy before anywhere public, with the
minimized input and the sanitizer trace. Do not post a working reproducer in a public issue
ahead of a fix.
