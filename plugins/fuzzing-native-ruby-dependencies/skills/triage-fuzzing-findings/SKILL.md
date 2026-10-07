---
name: triage-fuzzing-findings
description: Triage the crashes and hangs an AFL++ campaign produced against a Ruby C extension harness (a gem's native extension and the C library behind it). Screens them, buckets the raw reproducers by root cause, minimizes one representative per bucket with afl-tmin, and confirms each one against the real gem installed fresh with `gem install --platform ruby`, through every entry point the gem exposes. That shows whether a crash is a real native crash, an exception that escapes `rescue => e`, a hang, or an error the gem's own Ruby rescues. Sits after run-a-fuzzing-campaign. Stops at a classified, minimized reproducer for the maintainer and does no exploit development. Use after fuzzing a gem's C extension, when asked to triage, dedup or minimize AFL++ crashes or hangs, decide which crashes are real, or check whether a crash reaches a Ruby caller or is rescued.
---

# Triage fuzzing findings

Turn a directory of crashing inputs into a short list of distinct, minimized, confirmed
findings. **Classify crashes; do not develop exploits.**

The pipeline is automated. You do three things by hand, and only three:

1. **Fill in the consumer calls**: the `ENTRIES` arms in `resources/confirm.rb`.
2. **Run the driver.**
3. **Judge severity and write the report** from the skeleton it produces.

```sh
# 1  resources/confirm.rb: ENTRIES = the harness skill's real_harness.rb ENTRIES, same keys
#    (= the harness MODE values = the manifest's `entry` column), each arm rewritten from
#    ->(b) { ... } to -> { ... } over RAW (Step 1).  The gate already proved they reach the C.
# 2  PKG = the harness skill's oracle/ install, built from source and pinned:
#      gem install --install-dir oracle --platform ruby <gem> -v <ver>
#    No second install.
# 3  one command, run from the fuzz workspace: screens every campaign on the build that made
#    it, buckets the raw reproducers, confirms one per bucket, minimizes those, writes REPORT.md
resources/triage_all.sh \
    PKG=$PWD/oracle/gems/<gem>-<ver> \
    GOOD=corpus/<a gate seed with status=0> \
    ASAN_RT=$(../build-a-ruby-c-extension-fuzzing-harness/resources/find_asan_rt.sh)
```

With `campaigns/manifest.tsv` in the workspace (the campaign skill writes it), that is the
whole command. See "Manifest mode" in Step 2. Without a manifest, also pass `ENTRIES`, `MODES` and
`ALLOC_CAP_MB` by hand. Add `REQUIRE=<feature>` when the gem's `require` name differs
from its gem name, and `TIMEOUT_MS=` (confirm.rb's own answer budget, default 10000) if
needed. Both reach `confirm.rb` through the environment.

Without `PKG` it skips confirmation and says so. The confirm step is the only one that
answers whether a crash reaches a user.

**The scripts steer the tools; they do not replace them.** afl-tmin minimizes, the
sanitizers find and name the bugs, and the installed gem answers whether a user is reached.
The scripts decide how each tool is fed, how strict it is, and what counts as success. They
check every tool's result instead of trusting its exit code.

The one question this skill exists to answer, and the harness cannot: **does the crash reach
a Ruby caller, and can a `rescue` stop it?** The fuzzer crashed a C boundary with Ruby
deleted. A user reaches it through the gem's Ruby, which may validate the input first,
rescue the native error, or turn it into its own exception class. A crash a user cannot
trigger, or one that a `rescue => e` stops, is not the same finding as a segfault.

**Status.** The verdict ladder (`confirm.rb` + `confirm.sh`) was measured end to end on
Ruby 3.3.8 / clang 21 / AFL++ 4.33c / aarch64 Linux against a fabricated fixture gem whose
C extension misbehaves on purpose, once per input byte (`references/verdict-semantics.md`
has the table). The chain around it (`screen.sh`, `bucket.sh`, `minimize.sh`,
`triage_all.sh`) is carried from the Node sibling plugin and has since been run on real
Ruby campaigns; `EVIDENCE.md` lists them. Numbers marked "Node" were measured there. This
file does not quote what earlier campaigns found: your findings are yours to establish.

---

## Step 1: Fill in the consumer calls

Set `ENTRIES` in `resources/confirm.rb` from the `ENTRIES` hash in the harness skill's
`real_harness.rb`. Use the same keys: the harness `MODE` value, which is what the campaign
manifest's `entry` column holds (`MODE=file` maps to `file`, the default mode to
`default`). The arms were written once, where the gate proved they reach the native code,
so do not rewrite what they call. Transfer them mechanically:

| in `real_harness.rb` | in `confirm.rb` |
|---|---|
| `"default" => ->(b) { MyGem.parse(b).inspect }` | `"default" => -> { MyGem.parse(RAW).inspect }` |
| `as_file(b, ".dat")` | `as_file(".dat")` (writes RAW to a temp file) |
| an `over_ceiling?` / `over_work?` guard before the call | **drop it**: those ceilings are the gate's, and no user has them |

`RAW` is the input as a BINARY String, the exact bytes. A `nil` return is reported as
`CLEAN evidence=type=nil`, which the liveness check flags. Check two things while you
transfer:

* **No `rescue` and no options you would not expect a user to write.** A `rescue` inside
  an arm manufactures a CAUGHT verdict. A `Thread#join`/`#value` the README does not show
  turns a silent thread death into a raise at the call site.
* **Every `entry` the manifest names has an arm.** The template's `default` arm raises
  `NotImplementedError`, which is a ScriptError, not a StandardError. An unfilled arm
  therefore reads **UNCAUGHT on every cell**, not ERROR.

**Confirm every entry point the gem exposes.** This is the highest-value rule in this skill.
A Ruby String carries arbitrary bytes, so the Node trap does not carry over as-is: on the
Node sibling, 25 of a stylesheet-compiler binding's 111 confirmed crashes were reachable
only through its file-path entry point, because a JS-string argument replaces invalid UTF-8
before the library sees a byte. The rule still holds for Ruby because entry points reach
different code: a String, an IO and a path; event callbacks vs a built tree; push vs one-shot. Byte space still
narrows wherever the extension takes the String with `StringValueCStr` (an embedded NUL
raises ArgumentError) or the gem transcodes. `confirm.rb` prints `nul=` and `utf8=` for
every input, so you can explain such a row instead of guessing.

**A harness mode is an entry point too.** Buckets found under `MODES` need an arm that
selects the same mode through the gem's API. confirm.sh prints a NOTE above any such table.
On the Node sibling, two bugs found under harness `MODE=2` read CLEAN through the default
loader and **segfault the npm install** through an arm that set the matching mode. Without
both the mode and the arm, they would have been filed as "does not reproduce" twice.

---

## Step 2: Run the driver

### Manifest mode (the default)

If `campaigns/manifest.tsv` exists, `triage_all.sh` drives from it. Run it from the
workspace with nothing but `PKG`, `GOOD` and `ASAN_RT`. `NO_MANIFEST=1` forces discovery,
and `MANIFEST=<path>` points elsewhere.

| from the manifest | how |
|---|---|
| campaign list, `variant`, `out_dir` | one run per campaign with `crashes/` or `hangs/` files, on that campaign's own build |
| `mode_env` | the harness mode for that campaign (`default` means none); the non-default values also become `MODES` for `crashers/` |
| `entry` | every distinct value becomes `ENTRIES` for confirm, **plus every other arm defined in `confirm.rb`** (a load-method arm beside the campaign's parse-method arm was silently never run before this; measured), unless you pass `ENTRIES` |
| `alloc_cap_mb` | the screening ceiling per campaign (the largest becomes the default `ALLOC_CAP_MB`) |
| `selftest`, `status` | noted, never gating: a self-test other than `passed`, and any `status` other than `completed`/`switched`, prints a NOTE |

These are still discovered, not read: the crash and bucket contents, the `GOOD` guard, the
ceiling ladder, and the extension `.so` files (the first `*.so` at the top of
`out/asan/` and `out/pristine/`; pass `EXT=`/`PRISTINE=`, or `EXT_MAP`/`PRISTINE_MAP` when
the gem loads several). With no `out/pristine/` build the driver says so up front: build
`VARIANT=pristine` as soon as there are crashes, or the column that rules out an
instrumentation artifact stays empty. The driver warns about any `crashes/`/`hangs/` directory with files
that the manifest does not list. Those are not triaged: re-run the campaign or use
`NO_MANIFEST=1`. The harness skill's `smoke/` tree is skipped in that check. The corpus
skill's `crashers/` and `hangs/` are triaged too: against every variant, then under each
recorded non-default mode. A non-`completed` campaign's crashes are real; the absence of
more crashes is not evidence.

Each campaign gets these settings, with a timestamped line each: `exec_timeout_ms` sets its
hang screen (2 × the value in ms, plus 1 s of start-up; tune with `HANG_MULT`/`HANG_PAD_S`),
and `stability` < 90 % sets `RETRY=5`. An explicit `TIMEOUT=` or `RETRY=` wins.

### Discovery mode (no manifest)

`triage_all.sh` finds every `crashes/` and `hangs/` under the workspace and infers the build
variant from the path. It pairs each with `out/<variant>/harness-fork`, falling back to a
digit-stripped name and then to probing, because a second run of one build is routinely
called `asan2` and has no `out/asan2/`. It runs these steps in this order:

| step | script | does | cost on the Node sibling (stylesheet-compiler binding, 111 crashes) |
|---|---|---|---|
| screen | `screen.sh` | what reproduces, on which build, at which allocation ceiling | 14 s |
| bucket | `bucket.sh` | group the **raw** reproducers by root cause; one representative each | 27 s, 4 bugs |
| confirm | `confirm.sh` | each representative, on its **original** bytes, through the installed gem | one `ruby` process per cell |
| minimize | `minimize.sh` | **only the representatives**, with afl-tmin | 7 s for 6 |
| re-confirm | `confirm.sh` | the minimized reproducers, which are what a reader will run | one `ruby` process per cell |

The order is the point. Bucketing needs only a sanitizer report, so it runs on the raw
crashes and does the collapsing. Minimization, the expensive step, then runs once per bug
instead of once per crash. On the Node sibling (an image-decoding binding) the whole
pipeline, including both confirmations, took 61 s. The earlier "cmin, then minimize every
survivor" design ran past 20 minutes. Confirming the original bytes before minimizing is
also the safer test: that binding's GIF bug read CLEAN on the package install once
minimized and crashed it only as the original. Confirm verdicts **rank** buckets but never
remove one. A representative that is CLEAN on every column and entry point keeps its
original bytes instead of being minimized (`MINIMIZE_ALL=1` minimizes it anyway). A ruby
CLEAN only means "not reachable through the arms written so far".

Per campaign you get `triage/<campaign>[.on-<build>][@<mode>]/` containing `pool/ repro/
screen buckets/ min/ keys.tsv verdicts.tsv` and the logs, plus a consolidated
`triage/REPORT.md`.

Pass `ONLY=<variant>` or `SKIP_HANGS=1`, or run the scripts individually. Each one takes
`KEY=VALUE` arguments and documents them in its own header.

**Every phase and every slow loop prints a timestamp and elapsed seconds**, so you can tell a
stall from slow work and name the step it stalled in. `PROGRESS_EVERY=<seconds>` sets the
heartbeat interval inside long loops (default 20).

**In discovery mode, each campaign starts on the harness of the build that produced it.
Whatever does not reproduce there is offered to the other builds, then to each harness
mode.** The risk of using the wrong build runs one way. Measured on the Node sibling over
161 real crashes:

| campaign (Node bindings) | both builds | ASAN only | plain only | neither |
|---|---|---|---|---|
| stylesheet-compiler binding, plain (13) | 13 | 0 | 0 | 0 |
| stylesheet-compiler binding, ASAN (111) | 0 | **111** | 0 | 0 |
| image-decoding binding, plain (37) | 25 | **2** | 0 | 10 |

An ASAN campaign minimized against the plain build loses everything, because 1-2 byte
over-reads are invisible without the sanitizer. Not one input crashed the plain build
alone. The two crashes that only ASAN reproduces came from the *plain* campaign, which is
why stopping at the producing build was not enough. The 10 that reproduce nowhere are
fork-mode non-reproducers (persistent-mode artifacts), not crashes of the other variant.

**Harness modes.** Manifest mode takes them from `mode_env`. Otherwise, list the non-default
settings of the harness's mode variable yourself (`MODES="MODE=file"`). A crash found in one mode
does not reproduce in another. On the Node sibling, two crashers were `rc=0` by default and
`rc=134` under `MODE=2`: a heap over-read and a 67 MB `memcpy` over-read that a mode-blind
screen filed as non-reproducing. The driver cannot discover modes; you name them, the same
way you name the gem's entry points.

### Reading the output

`triage/<campaign>/screen` has the per-input `rc` and milliseconds. Read it before believing
any drop:

| in `screen` / the log | means | the driver's response |
|---|---|---|
| inputs left in `nonrepro/` | reproduced on no build and in no mode tried | listed in REPORT.md with what was tried; usually persistent-mode artifacts |
| `AMPLIFICATION` lines | a small input demanded huge memory | **a DoS by itself**: report the ratio (below) |
| stability < 90 % warning | nondeterministic reproduction | pass `RETRY=5` |
| `ms` over `TIMEOUT` | slower than the tool's timeout | raise `TIMEOUT=` (ms, default 5000) |
| `ignored because of crashing the target` | `afl-showmap` captured no trace | still a finding; it is in `screen` |

### Memory amplification is a finding on its own

The allocation ceiling (`ALLOC_CAP_MB`, **default 1024 MB**, the same number the gate and
the campaign used) decides whether a declared-size bug is visible at all. The library
allocates a size the input declared *before* validating it, and the process dies only if
the request exceeds the ceiling. A ceiling of 4 GB sits above the whole 32-bit range a
declared length can express, so it acquits every bug of this class by construction. On the
Node sibling that was the old default, and it hid a real bug.

So `screen.sh` walks a `CAP_LADDER` (default `1024 256 64`) **per input**. Each rung
re-screens only what has not reproduced yet. Every input carries the ceiling it reproduced
at through bucketing, confirmation and minimization (`cap.tsv`). The screen reports the
**amplification**, the bytes the library demanded divided by the bytes of input
(Node-sibling example):

```
0008-...-id_000008_sig_09_src: 5 B in -> 3758096257 B demanded  (751619251x amplification)
=> RESOURCE EXHAUSTION / DoS
```

Report that ratio and the ceiling, not just `out-of-memory`. A five-byte input that makes the
library ask for 3.7 GB is a denial of service whatever ceiling catches it. The C heap
the extension allocates from sits outside Ruby's GC, and Ruby sets no limit on it.

**Pass `GOOD=` so the ladder cannot cry wolf.** It separates "this input demands absurd
memory" from "this ceiling is too small for the library's normal work". The test is
differential: `GOOD`'s exit status at the candidate ceiling versus with the ceiling lifted.
A reference input the library legitimately *rejects* is therefore still a usable guard.
Without `GOOD`, the lower rungs are still tried but flagged unverified. If `GOOD` shows the
normal work needs more than 1024 MB, the ladder walks **up** (`CAP_UP`, to 16 GB) to the
first ceiling `GOOD` tolerates and screens only there.

**Minimization is afl-tmin, steered.** `references/afl-tool-reliability.md` has the evidence
(AFL++'s behaviour, measured on the Node sibling). Fed through `@@`, afl-tmin's temp file
reached the harness empty, and it minimized every input to zero bytes with exit 0.
`minimize.sh` passes `/dev/stdin` as the harness's file argument instead, lets afl-tmin
minimize freely, and retries with `AFL_TMIN_EXACT=1` only if the sanitizer key drifted to a
different bug. Hangs use `afl-tmin -H` with a short `-t` (`HANG_S`, default 2 s) and a
re-check at the full timeout. A result that does not verify is discarded and the original
bytes are kept. There is no homemade fallback.

**Do not hand-minimize further.** On the Node sibling, a stack-exhaustion reproducer
resisted manual reduction. The obvious mechanism (deep nesting) was guarded; the real one
was unbounded recursion during evaluation, past the guard.

### Buckets

Buckets are keyed on the sanitizer **SUMMARY** line: kind + `file:line` + function + access
(`READ-1`, `WRITE-8`). Never on stack frames: C++ frame text starts with the return type,
so half the crashes file under `char`.

**Report the second grouping, merged on function.** The SUMMARY key over-separates. On the
Node sibling, a 25-crash over-read in an unchecked UTF-8 decoder was reported at three lines
of one header: the exact key gave 6 buckets, and the merged key gave **4**, the published
answer. To judge whether two reports are one bug, compare the **allocation and the access**,
not the frame text, because inlining differs between the instrumented and pristine builds.

| bucket | meaning | action |
|---|---|---|
| `NO-REPORT signal-only sigN` | crashed, no sanitizer frame | usually **stack exhaustion**: a real DoS needing no sanitizer, not noise. **First** run the representative on the harness and grep stderr for `AFL-HARNESS-STUB: entered Ruby runtime:`. A stub trap (SIGTRAP/SIGILL) is the harness wandering into Ruby glue it did not mirror. That is a harness defect for the harness skill, not a finding |
| `hang in <function>` | the bare harness never returned | **DoS in the native code itself.** Keyed by interrupting the sanitized harness with SIGABRT at several points and taking the innermost frame that is common to every sample and never recurs. Approximate: a loop inside a recursive walk can land in a coarser bucket on another run |
| `out-of-memory` | declared-size allocation | resource exhaustion; read the **plain** column |
| `NO-CRASH (rc=N)` | did not reproduce here | wrong build or mode, or a persistent-mode artifact |

Counts are distribution, not severity. An out-of-bounds **write** outranks a 1-byte read
regardless of count, which is why the access is in the key.

---

## Step 3: Read the confirm tables

Three build columns answer three questions:

| column | runs | a crash there means |
|---|---|---|
| `gem-install(plain)` | the extension `gem install --platform ruby` built | **critical**: no rescue stops it, any caller |
| `gem+asan-ext` | the gem's published Ruby, ASAN `.so` swapped in, ASAN runtime preloaded | a real memory bug the release build hides |
| `gem+pristine-ext` | sanitizer, **no** coverage instrumentation | reproduces here, so it is not an artifact of your instrumentation |

Verdict ladder, most severe first:

1. **NATIVE-CRASH(...)**: a signal, Ruby's own `[BUG]` report, or a sanitizer report. Ruby's
   SIGSEGV/SIGBUS handler prints `[BUG] Segmentation fault at 0x…` and aborts, so no
   `rescue` runs, not even `rescue Exception`. That cell reads
   `NATIVE-CRASH(bug-Segmentation-fault)`. A full ASAN report gives the kind, for example
   `NATIVE-CRASH(heap-buffer-overflow)`. `NATIVE-CRASH(sig9)` means ruby was SIGKILLed
   *before* the cell timeout, for example by the OOM killer.
2. **UNCAUGHT**: escapes `rescue => e`. It is an Exception that is not a StandardError
   (NoMemoryError, SystemStackError, ScriptError), an exception that killed a Thread the
   gem started (the caller's rescue never sees it), or `fatal`/`exit`. Stopping it needs
   `rescue Exception` or the specific class.
3. **HANG**: no answer within `TIMEOUT_MS`. `HANG(cell-timeout)` means ruby did not even
   answer its own watchdog, so the C loop holds the GVL (see the hang section below).
4. **CAUGHT**: raised a StandardError. A `rescue => e` at the call site is enough.
5. **CLEAN**: no error, with `evidence=` of what the call returned.
6. **SKIPPED**: NoMemoryError in a sanitized column. The ceiling `confirm.sh` set there
   (the bucket's `cap.tsv` ceiling, else `ALLOC_CAP_MB`) refused the allocation, not the
   gem, so the cell proves nothing. It is deliberately not CAUGHT. In the plain column, a
   NoMemoryError is the gem's real behaviour and reads UNCAUGHT.

Four kinds of cell are not verdicts. Fix them; do not report them:

* **`EXT-NOT-SWAPPED`**: the ASAN extension never loaded, so that column duplicates the
  install column and hides every memory bug. `confirm.rb` intercepts `require` and
  `require_relative`, then believes `/proc/self/maps`, not the hook. Every verdict line
  carries `swap=` and `loaded=` (which `.so` actually loaded). Keep the extension's
  original file name, because Ruby calls `Init_<basename>`.
* **`EXT-AMBIGUOUS`**: the gem loads several extensions, and one `EXT` replaced all of
  them. Set `EXT_MATCH=`, or `EXT_MAP='regex=path;regex=path'` (`PRISTINE_MAP` for the
  pristine column).
* **`ERROR`**: a bare `ERROR` means `confirm.rb` refused to run (`no-such-entry`,
  `PKG-NOT-A-GEM`, `LOAD-FAILED`, `EXT-MISSING`; exit 40). `ERROR(rc=N)` means ruby died
  without a verdict line. A `PKG` that will not load usually means it is not a fresh
  `oracle/` install.
* **A column of all-CLEAN**: the signature of a mis-wired call, not a clean gem. `GOOD=` runs
  a working seed through the **plain** column first and prints its `evidence=`. A
  `type=nil`, `bytes=0` or `…=0` result means the column measures nothing. The fixture's
  liveness line read `CLEAN evidence=bytes=12`. On the Node sibling, a JS harness
  "confirmed" success for 18 files that had all failed, because the getter it checked was
  hardcoded `return true`.

The liveness run does not prove the ASAN swap. Every non-NATIVE cell proves it per cell
(`swap=swapped`), but a NATIVE-CRASH pre-empts that check. Prove the swap once by hand:
`LD_PRELOAD=$ASAN_RT ASAN_OPTIONS=detect_leaks=0 PKG=… EXT=out/asan/<name>.so ruby resources/confirm.rb <GOOD>`
should print `swap=swapped loaded=<name>.so`.

When a minimized input is CLEAN, it is re-tested against the pre-tmin bytes automatically
and reported as `CLEAN->NATIVE-CRASH(...)(orig)` if those crash. Minimizing happened against
the harness's redzones, which the release install lacks. Reproduce such a finding with the
original bytes.

`references/verdict-semantics.md` has the long form of every verdict and why each is
Ruby-specific: the GVL, Ruby's SIGSEGV handler, `rb_raise`'s longjmp, gem threads, and the
ORACLE CEILING (an over-read of a small input String is invisible to the ASAN column). It
also covers stack exhaustion, resource exhaustion, the artifact patterns to recognise, how
to adapt arms for block, handler, IO and threaded APIs, and the measured fixture table.

---

## Step 4: Judge and write the report

`triage/REPORT.md` has one row per bucket with the facts and a "still to do by hand" list.
Fill in, per bug (the **merged** bucket):

* the SUMMARY: kind, `file:line`, function, `READ`/`WRITE` and size;
* which build variant found it, and the reproducer's path and size, with the bytes inline
  for a native crash (`od -An -tx1`);
* the verdict in every column **and every entry point**, with `nul=`/`utf8=` where a row is
  CLEAN;
* the entry point a reader should use ("reachable via `Gem.parse_file`" is the actionable
  half of the finding);
* a one-line repro.

Severity:

| verdict | severity |
|---|---|
| gem install natively crashes | **critical** |
| only a sanitized build crashes | **memory-safety bug** |
| hangs the bare harness, or `HANG` through ruby | **denial of service** |
| the input sets the work factor (a cost or rounds field, an iteration count) and the gem does not bound it | **denial of service, time amplification**: quote the field and the time at its minimum and at the largest value accepted. A hang bucket whose inputs differ only in that field is this, not a loop bug |
| `UNCAUGHT` | **denial of service** for the usual `rescue => e` caller; say which shape (class, thread death, fatal) |
| the gem raises a StandardError (`CAUGHT`) | **low** |
| CLEAN on every entry point | **not a finding**: say so and why, do not drop it silently; check the oracle ceiling first |

An out-of-bounds write outranks a 1-byte read either way. Add the sentence the pristine
column earns: *this reproduces without the coverage instrumentation.*

**A hang is a reportable denial of service.** Do not leave it in a `NO-REPORT hang` bucket
as if it were noise. Say which of two cases it is:

* **The bare harness hangs**: `screen` shows `rc=124`. The C code loops with Ruby deleted.
  It is the library's bug, and any caller can reach it.
* **It hangs through ruby**: `HANG` in the confirm table.

Give the input size and the budget you allowed. State the reach. A C call that loops
**holding the GVL** cannot be interrupted from Ruby at all. Ruby delivers `Timeout`,
`Thread#raise`/`#kill` and even SIGTERM only at an interrupt check, which the loop never
reaches; the same mechanism starves `confirm.rb`'s own watchdog thread. The loop stalls
every Ruby thread in the process, which for a threaded server means everything, and only
SIGKILL ends it. Measured: a cell ran 10 minutes past an 8 s `timeout`. A loop that released the GVL costs one thread instead.
`HANG(cell-timeout)` vs plain `HANG` tells you which case you have. Raise `TIMEOUT_MS`
once to separate "infinite" from "merely slow", and report the figure.

For an `out-of-memory` bucket, say which `max_allocation_size_mb` made it visible, because a
declared-size bug is invisible at a ceiling above the size it declares.

State what was instrumented. "I fuzzed the gem" and "I fuzzed its vendored C library through
the extension" are different claims. A bucket pointing inside an uninstrumented dependency
(a system library the extension links) is a hard-crash-only result.

Do not quote crash counts as a measure of anything. Do not state a mechanism you have not
read the code for.

**If nothing is confirmed, including when there are no crash files at all**, cite the
harness skill's detection self-test and the campaign's execs and stability. Without them,
"nothing found" is indistinguishable from "the harness detects nothing", and is not a result.

Hard crashes and memory-safety bugs in a widely installed gem are sensitive. Report to the
maintainer through the gem's security policy before posting anywhere public, with the
minimized input and the sanitizer trace. Do not post a working reproducer in a public issue
ahead of a fix.
