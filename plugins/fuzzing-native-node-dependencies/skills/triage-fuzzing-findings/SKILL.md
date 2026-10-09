---
name: triage-fuzzing-findings
description: Triage the crashes and hangs an AFL++ campaign produced against a native Node addon: screen them, bucket the raw reproducers by root cause, minimize one representative per bucket with afl-tmin, and confirm each one against the package installed fresh from npm — through every entry point the binding exposes — to see whether it is a real native crash or an error the package's own try/catch and handlers absorb. The goal is to separate real crashes from artifacts and already-caught errors, not to develop exploits. Use after fuzzing a NAN/N-API dependency, when asked to triage findings, minimize or dedup crashes, decide which crashes are real, or check whether a crash is caught by the package's error handling.
---

# Triage fuzzing findings

Turn a directory of crashing inputs into a short list of distinct, minimized, confirmed
findings. **Classify crashes; do not develop exploits.**

The pipeline is automated. You do three things by hand, and only three:

1. **Fill in the consumer calls**: the `ENTRIES` arms in `$W/confirm.mjs`, your copy of
   the template.
2. **Run the driver.**
3. **Judge severity and write the report** from the skeleton it produces.

```sh
# 0  any crash saved? build out/pristine first (Step 2)
# 1  cp $SKILLS/triage-fuzzing-findings/resources/confirm.mjs $W/confirm.mjs, then in the copy
#    ENTRIES = the ENTRIES object from the harness skill's real_harness.mjs, pasted unchanged
#    (same keys = the harness MODE values = the manifest's `entry` column; the gate already
#    proved those calls reach the native code)
# 2  one command, run from the fuzz workspace: screens every campaign on the build that made
#    it, buckets the raw reproducers, confirms one per bucket, minimizes those, writes REPORT.md
cd $W && . ./fuzz.env           # $W written out as the absolute workspace path: a fresh shell has no variables
$SKILLS/triage-fuzzing-findings/resources/triage_all.sh \
    GOOD=corpus/<a gate seed with status=0> \
    ASAN_RT=$($R/find_asan_rt.sh)
```

`fuzz.env` (written by the harness skill) supplies `PKG` (the `oracle/` install: a fresh,
pinned `npm install` of the published package, no second install), the ASAN addon,
`MODES` and `ALLOC_CAP_MB`; an explicit `KEY=VALUE` wins. `ASAN_RT` is the runtime the
sanitized confirm columns preload; pass it as above unless `triage_all.sh`'s header lists it
among the `fuzz.env` defaults. With `campaigns/manifest.tsv` in the workspace (written by the
campaign skill) that is the whole command; see "Manifest mode" in Step 2. Without one, also
pass `ENTRIES` by hand.

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

Copy the template into the workspace and edit the copy, never the plugin's file (a
plugin update would overwrite it, and every workspace would share one set of arms):

```sh
cd $W && . ./fuzz.env
cp $SKILLS/triage-fuzzing-findings/resources/confirm.mjs $W/confirm.mjs
```

`triage_all.sh` and `confirm.sh` use `$W/confirm.mjs` when it exists; `CONFIRM=<path>`
points them elsewhere (arms for other API shapes: `references/verdict-semantics.md`,
"Adapting confirm.mjs"). In the copy, set `ENTRIES` to the `ENTRIES` object from the harness
skill's `real_harness.mjs`: the same arms, keyed by the harness `MODE` value, which is what
the campaign manifest's `entry` column holds (`MODE=file` → `file`; the default mode →
`default`). They were written once, where the gate proved they reach the native code, so do
not rewrite them. The paste really is unchanged: each arm takes the input buffer on both
sides, and `asFile(b, ext)` (bytes to a temp file path) has the same signature in both files.
Helper functions the arms call are pasted above the object too, skipping any name
`confirm.mjs` already defines; that includes `const collected = [];` when a callback arm
pushes onto it, since `confirm.mjs` does not define `collected`.
Two helpers exist only in `confirm.mjs`: `errback` and `okback`, the consumer's error and
success callbacks for callback-property APIs. Check two things as you paste: **no options and
no error listener you would not expect a user to add** (an added `.on('error')` manufactures
a CAUGHT verdict), and that every `entry` the manifest names has an arm.

`GOOD=` is the known-good input every entry's liveness check runs. An entry that needs a
different one (it takes another encoding or input shape, a file-path entry beside a
string one) gets `GOOD_<entry>=<seed>` (characters outside `[A-Za-z0-9_]` in the entry
name become `_`), or its CLEAN cells read as unverified.

**Confirm every entry point the binding exposes.** Highest-value rule in this skill.
One entry point can transform the input before the library sees a byte (a string entry
point that replaces invalid UTF-8 with U+FFFD), so crashes reachable only through another
(the file-path one) read as artifacts through the first.

**A harness mode is an entry point too.** Buckets found under `MODES` need an arm that
selects the same mode through the npm API; confirm.sh says so above any such table. A bug
found under a non-default harness mode can read CLEAN through the package's usual call and
**segfault the npm install** through an arm that sets what the mode sets. Without both the
mode and the arm it is filed "does not reproduce" twice.

An arm that returns `undefined` **must** answer from its own callbacks. If it forgets, every
input runs into the timeout and reads `HANG` — a denial of service that does not exist.

---

## Step 2 — Run the driver

### First, build `out/pristine` if any crash was saved

Whenever a campaign, the smoke run or the corpus skill saved a crash, build the
`pristine` variant (ASAN, no AFL instrumentation) before the driver, with the harness
skill's two commands:

```sh
cd $W && . ./fuzz.env && cd <package dir>
$R/build_addon.sh VARIANT=pristine OUT=$W/out
cd $W && $R/link_harness.sh VARIANT=pristine MK=out/pristine/<target>.target.mk SRCDIR=<package dir> \
    LIB="$(find out/pristine/Release/obj.target/<dep> -name '*.o')"
```

The driver finds `out/pristine/` by itself and fills the `npm-js+pristine-addon` column,
the only one that earns "reproduces without the coverage instrumentation" (Step 4).
Without it that column reads `(no PRISTINE)`, and `triage_all.sh` says so.

### Manifest mode (the default)

If `campaigns/manifest.tsv` exists, `triage_all.sh` drives from it; run it from the
workspace with nothing but `GOOD` (and `ASAN_RT`). `NO_MANIFEST=1` forces discovery;
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
harness skill's `smoke/` tree is skipped in that check. The workspace's `crashers/` and
`hangs/` (the corpus skill's seed policy and the smoke run's `REAL` and `PERSISTENT-ONLY`
crashes) are triaged too, even when no campaign saved a crash: against every variant, then
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

| step | script | does | cost |
|---|---|---|---|
| screen | `screen.sh` | what reproduces, on which build, at which allocation ceiling | cheap |
| bucket | `bucket.sh` | group the **raw** reproducers by root cause; one representative each | cheap |
| confirm | `confirm.sh` | each representative, on its **original** bytes, through the npm package | cheap per cell |
| minimize | `minimize.sh` | **only the representatives**, with afl-tmin | the expensive step |
| re-confirm | `confirm.sh` | the minimized reproducers, which are what a reader will run | cheap per cell |

The order is the point. Bucketing needs only a sanitizer report, so it runs on the raw
crashes and does the collapsing; minimization, the expensive step, then runs once per bug
instead of once per crash (the earlier "cmin, then minimize every survivor" design was far
slower). Confirming the original bytes before minimizing is also the safer test: a minimized
input can read CLEAN on the npm install where the original crashes it. Confirm verdicts
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
wrong build runs one way: ASAN crashes do not reproduce on the plain build (1-2 byte
over-reads are invisible without the sanitizer), so an ASAN campaign screened against it
loses everything; plain crashes do reproduce on ASAN. A *plain* campaign can still hold
crashes only ASAN reproduces, which is why stopping at the producing build is not enough.
Inputs that reproduce nowhere are fork-mode non-reproducers (persistent-mode artifacts), not
crashes of the other variant.

**Harness modes.** Manifest mode takes them from `mode_env`. Otherwise, if the harness reads a
mode variable (`MODE=`, `HARNESS_MODE=`), list the non-default settings in `MODES="MODE=2 MODE=3"`
(`fuzz.env` carries them). A crash found in one mode does not reproduce in another: it is
`rc=0` by default and crashes under its own mode, so a mode-blind screen files it as
non-reproducing. The driver cannot discover modes; you name them, the same way you name the
npm entry points.

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
earlier version stopped at the first rung that reproduced *anything*, and a declared-size
input sharing a pool with heap over-reads was silently dropped. It reports the
**amplification** — the bytes the library demanded divided by the bytes of input:

```
<input>: <N> B in -> <M> B demanded  (<M/N>x amplification)
=> RESOURCE EXHAUSTION / DoS
```

Report that ratio and the ceiling, not just `out-of-memory`. A few-byte input that makes
the library ask for gigabytes is a denial of service whatever absolute ceiling happens to catch
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

**Do not hand-minimize further.** A reproducer that resists manual reduction usually does so
because the obvious mechanism (deep nesting) is guarded and the real one (unbounded recursion
during evaluation) lies past the guard.

### Buckets

Keyed on the sanitizer **SUMMARY** line — kind + `file:line` + function + access (`READ-1`,
`WRITE-8`). Never on stack frames: template-heavy C++ frame text starts with the return
type, so half the crashes file under `char`.

**Report the second grouping, merged on function.** The SUMMARY key over-separates: one
over-read in an inlined decoder is reported at several lines of one header. The merged
grouping is the one to report. `bucket.sh` also prints a third, **merged on caller**, for a
root cause visible only in frame #1: one missing bounds check in a shared caller that
overflows in a dozen per-format callees files a dozen functions, and that grouping
collapses them into one bug. When judging whether two reports are one bug,
compare the **allocation and the access**, not the frame text — inlining differs between the
instrumented and pristine builds.

**A bucket keyed on a `harness.cc` line is copied package code** (the harness copied a
method body, so the bug is the package's). The report line is the
package file and line named in the copy's source comment, not the `harness.cc` line.

| bucket | meaning | action |
|---|---|---|
| `NO-REPORT signal-only sigN` | crashed, no sanitizer frame | usually **stack exhaustion** — a real DoS needing no sanitizer. Not noise. |
| `hang in <function>` | the bare harness never returned | **DoS in the native code itself.** Keyed by interrupting the sanitized harness with SIGABRT at several points and taking the innermost frame common to every stack that never recurs. Approximate: a loop inside an interpreter's recursive walk (its evaluate/expand passes) can land in a coarser bucket on another run |
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

Cells that are not verdicts; fix them, do not report them:

* **`ADDON-NOT-SWAPPED`** — the ASAN addon never loaded, so that column duplicates the
  install column and hides every memory bug. `confirm.mjs` hooks `process.dlopen`, the one
  funnel every addon load passes through, so the swap survives packages that resolve their
  binary by their own environment variable (a hook on `'bindings'` never fires). `loaded=`
  says which `.node` actually loaded.
* **`ADDON-AMBIGUOUS`** — several addons, one `ADDON` swapped into all of them. Set
  `ADDON_MATCH=` or `ADDON_MAP='regex=path;regex=path'`.
* **`ERROR`** — bare `ERROR`: `confirm.mjs` rejected the `ENTRY` name. `ERROR(rc=N)`: node
  died without a verdict, usually a `PKG` that will not load — classically because your
  fuzzing build overwrote the npm prebuilt, which is why `PKG` must be a fresh install.
* **`NO-VERDICT`** — node exited 0 without a verdict: the `ENTRIES` arm returned `undefined`
  and nothing kept the event loop alive (a callback that never fires, an arm that forgot
  `okback`/`errback`). The arm is mis-wired; it is not CLEAN.
* **`version-mismatch`**: the package under `PKG` is not `fuzz.env`'s `PKG_VERSION`, so
  the confirm ran a different release from the one the harness was built from. Reinstall
  the pinned version in `oracle/`.
* **A column of all-CLEAN** — the signature of a mis-wired consumer call, not a clean
  package. `GOOD=` runs a working seed first; no `evidence=` on it means the column measures
  nothing. A JS harness once "confirmed" success for inputs that had all failed, because
  the property it checked was a getter hardcoded to `return true`.

A CLEAN cell on the minimized input is re-tested against the pre-tmin bytes automatically
and reported as `CLEAN->NATIVE-CRASH(...)(orig)` if those crash — minimizing happened
against the harness's redzones, which the release install lacks. This recovers critical
findings a naive pipeline drops; reproduce them with the original bytes.

Long form of every verdict, the cases where a CLEAN ASAN column proves nothing, stack-depth
sensitivity, resource exhaustion, and the artifact patterns to recognise:
`references/verdict-semantics.md`. The runs and figures behind this skill's rules are in
`references/measured-cases.md`: other targets' results, not what to expect on yours.

---

## Step 4 — Judge and write the report

`triage/REPORT.md` has one row per bucket with the facts and a "still to do by hand" list.
The bucket table shows the minimized input's own sanitizer key beside the original's, and
**`DRIFT`** when they differ: afl-tmin reduced the input onto another bug. `minimize.sh`
keys drift on the first non-interceptor frame (a key of `__asan_memcpy` would hide it) and
retries exact, but when `DRIFT` survives, report that bucket's **original** bytes as its
reproducer; the minimized file belongs to the other bucket.
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
indistinguishable from "the harness detects nothing", and is not a result. The no-findings
`REPORT.md` has a Scope section whose "Instrumented:" line you fill in: which library code
carried coverage and sanitizers in the harness. For a library the package loads as a
system `.so` (the harness linking an instrumented static archive of it), write that the
sanitized confirm column ran the sanitized addon against the uninstrumented system library,
so it cannot see an overflow inside the library; only the direct harness could
(`references/verdict-semantics.md`, "The ASAN column is authoritative only...").

Hard crashes and memory-safety bugs in a widely installed package are sensitive. Report to
the maintainer through the package's security policy before anywhere public, with the
minimized input and the sanitizer trace. Do not post a working reproducer in a public issue
ahead of a fix.
