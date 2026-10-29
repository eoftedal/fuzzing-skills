---
name: triage-fuzzing-findings
description: Triage the crashes and hangs an AFL++ campaign produced against a Ruby C extension harness (a gem's native extension and the C library behind it). Screens them, buckets the raw reproducers by root cause, minimizes one representative per bucket with afl-tmin, and confirms each one against the real gem installed fresh with `gem install --platform ruby`, through every entry point the gem exposes. That shows whether a crash is a real native crash, an exception that escapes `rescue => e`, a hang, or an error the gem's own Ruby rescues. Sits after run-a-fuzzing-campaign. Stops at a classified, minimized reproducer for the maintainer and does no exploit development. Use after fuzzing a gem's C extension, when asked to triage, dedup or minimize AFL++ crashes or hangs, decide which crashes are real, or check whether a crash reaches a Ruby caller or is rescued.
---

# Triage fuzzing findings

Turn a directory of crashing inputs into a short list of distinct, minimized, confirmed
findings. **Classify crashes; do not develop exploits.**

The pipeline is automated. You do three things by hand, and only three:

1. **Fill in the consumer calls**: the `ENTRIES` arms in the workspace's copy of `confirm.rb`.
2. **Run the driver.**
3. **Judge severity and write the report** from the skeleton it produces.

```sh
cd $W && . ./fuzz.env
# 1  cp $SKILLS/triage-fuzzing-findings/resources/confirm.rb $W/confirm.rb, then paste
#    real_harness.rb's ENTRIES hash into $W/confirm.rb UNCHANGED (->(b) arms, same keys =
#    the harness MODE values = the manifest's `entry` column), with the helpers the arms
#    call (Step 1).  Never edit the plugin's own copy.
# 2  PKG = the harness skill's oracle/ install, built from source and pinned (fuzz.env's PKG).
#    No second install.
# 3  one command, run from the fuzz workspace: screens every campaign on the build that made
#    it, buckets the raw reproducers, confirms one per bucket, minimizes those, writes REPORT.md
$SKILLS/triage-fuzzing-findings/resources/triage_all.sh GOOD=corpus/<a gate seed with status=0>
```

Every command block starts with `cd $W && . ./fuzz.env` (`$W` spelled out): each tool call
is a fresh shell, and `fuzz.env` (the harness skill wrote it; if missing, run its
`init_workspace.sh`) supplies `PKG`, the ASAN extension (`EXT_ASAN`), `ASAN_RT`, `MODES`,
`ALLOC_CAP_MB` and `ADDON_MATCH` (the default `EXT_MATCH`, for a gem with several
extensions) as defaults below explicit arguments. With `campaigns/manifest.tsv` in
the workspace (the campaign skill writes it), that is the whole command. See "Manifest
mode" in Step 2. Without a manifest, also pass `ENTRIES` by hand. Add `REQUIRE=<feature>`
when the gem's `require` name differs from its gem name, and `TIMEOUT_MS=` (confirm.rb's
own answer budget, default 10000) if needed.

Without `PKG` it skips confirmation and says so. The confirm step is the only one that
answers whether a crash reaches a user.

**The scripts steer the tools; they do not replace them.** afl-tmin minimizes, the
sanitizers find and name the bugs, and the installed gem answers whether a user is reached.
The scripts decide how each tool is fed and check its result, never its exit code.

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

Copy the template into the workspace and edit it there, never the plugin's own file (an
installed plugin is shared, and two workspaces would overwrite each other's arms):

```sh
cd $W && . ./fuzz.env
cp $SKILLS/triage-fuzzing-findings/resources/confirm.rb $W/confirm.rb
```

`triage_all.sh` and `confirm.sh` use `$W/confirm.rb` when it exists; `CONFIRM=<path>`
points them elsewhere.

**Paste the `ENTRIES` hash from the harness skill's `real_harness.rb` unchanged.** The keys
are the harness `MODE` values, which is what the campaign manifest's `entry` column holds
(`MODE=file` maps to `file`, the default mode to `default`). Each arm keeps its `->(b)`
form: `confirm.rb` calls it as `arm.call(RAW)`, with `RAW` the input as a BINARY String,
and `as_file(b, ext)` has the same signature on both sides. A lambda checks its arity, so
an arm rewritten to `-> { }` raises ArgumentError and every cell reads CAUGHT. The arms
were written once, where the gate proved they reach the native code: do not rewrite them.

**Paste the helpers the arms use above the hash too**: a handler class the callback arms
instantiate, a tree walker, a global handler object. A name the arms call that
`confirm.rb` does not define reads as a wiring error. The helpers `real_harness.rb`'s
template itself provides (`as_file`, `fnv1a`, `over_ceiling?`, `over_work?`) are already
in `confirm.rb` with the same names and signatures. For a callback arm, check whether
`confirm.rb` already defines `COLLECTED` (the buffer the arm appends events to and
returns); paste its one line only if it does not.

A `nil` return is reported as `CLEAN evidence=type=nil`, which the liveness check flags.
Check two things while you paste:

* **No `rescue` and no options you would not expect a user to write.** A `rescue` inside
  an arm manufactures a CAUGHT verdict. A `Thread#join`/`#value` the README does not show
  turns a silent thread death into a raise at the call site.
* **Every `entry` the manifest names has an arm.** The template's `default` arm raises
  `NotImplementedError`, which is a ScriptError, not a StandardError. An unfilled arm
  therefore reads **UNCAUGHT on every cell**, not ERROR.

**One known-good input per entry point when they differ.** `GOOD=` feeds every arm's
liveness check; an entry point with another encoding or input shape (a UTF-16 arm, an IO
arm) reads NO-EVIDENCE on a UTF-8 seed. Pass `GOOD_<entry>=<seed>` for it (characters
outside `[A-Za-z0-9_]` become `_`).

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
loader and **segfault the npm install** through an arm that set the matching mode.

---

## Step 2: Run the driver

**Build `out/pristine/` first whenever campaigns saved crashes**: only the pristine column
earns "reproduces without instrumentation", and `triage_all.sh` notes crashes with no
`out/pristine/`. The harness skill's two commands, linked as plain was:

```sh
cd $W && . ./fuzz.env
(cd $X && $R/build_ext.sh VARIANT=pristine OUT=$W/out ORACLE=$PKG GEM_PATH=$W/oracle EXTCONF_ARGS="$EXTCONF_ARGS")
$R/link_harness.sh VARIANT=pristine MK=out/pristine/Makefile SRCDIR=$X OUT=$W/out <plain's LIB=/EXT_OBJS=/SHIM=>
```

### Manifest mode (the default)

If `campaigns/manifest.tsv` exists, `triage_all.sh` drives from it. Run it from the
workspace with nothing but `GOOD` (the rest comes from `fuzz.env`). `NO_MANIFEST=1` forces discovery,
and `MANIFEST=<path>` points elsewhere.

| from the manifest | how |
|---|---|
| campaign list, `variant`, `out_dir` | one run per campaign with `crashes/` or `hangs/` files, on that campaign's own build; every instance's directory (`default/`, or `main/` and `s<i>/`), deduplicated by content |
| `mode_env` | the harness mode for that campaign (`default` means none); the non-default values also become `MODES` for `crashers/` |
| `entry` | every distinct value becomes `ENTRIES` for confirm, **plus every other arm defined in `confirm.rb`** (a load-method arm beside the campaign's parse-method arm was silently never run before this; measured), unless you pass `ENTRIES` |
| `alloc_cap_mb` | the screening ceiling per campaign (the largest becomes the default `ALLOC_CAP_MB`) |
| `selftest`, `status` | noted, never gating: a self-test other than `passed`, and any `status` other than `completed`/`switched`, prints a NOTE |

These are still discovered, not read: the crash and bucket contents, the `GOOD` guard, the
ceiling ladder, and the extension `.so` files (the first `*.so` at the top of
`out/asan/` and `out/pristine/`; pass `EXT=`/`PRISTINE=`, or `EXT_MAP`/`PRISTINE_MAP` when
the gem loads several). The driver warns about any `crashes/`/`hangs/` directory with files
that the manifest does not list. Those are not triaged: re-run the campaign or use
`NO_MANIFEST=1`. The harness skill's `smoke/` tree is skipped in that check. The corpus
skill's `crashers/` and `hangs/` are triaged too, even when no campaign saved a crash:
against every variant, then under each recorded non-default mode. The harness skill's
`smoke.sh` files its `REAL` and `PERSISTENT-ONLY` crashes there itself. A non-`completed`
campaign's crashes are real; the absence of more is not evidence.

With `PKG`, also on a run with nothing to bucket: **liveness** (`GOOD=` through every
`confirm.rb` arm, printed and copied into REPORT.md), and **real-stack-only crashers**: a
`crashers/` input no instrumented build reproduces is confirmed under the mode its
`crashers.summary.tsv` row or name records (every arm when none), into `triage/real-only/`
and REPORT.md's "Real-stack-only" section. Not minimized.

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

The order is the point: bucketing collapses the raw crashes, so minimization, the expensive
step, runs once per bug; and the original bytes are confirmed first, the safer test (why:
`references/afl-tool-reliability.md`, "In short"). Confirm verdicts **rank** buckets but never
remove one. A representative that is CLEAN on every column and entry point keeps its
original bytes instead of being minimized (`MINIMIZE_ALL=1` minimizes it anyway). A ruby
CLEAN only means "not reachable through the arms written so far".

Per campaign you get `triage/<campaign>[.on-<build>][@<mode>]/` containing `pool/ repro/
screen buckets/ min/ keys.tsv verdicts.tsv` and the logs, plus a consolidated
`triage/REPORT.md`.

Pass `ONLY=<variant>` or `SKIP_HANGS=1`, or run the scripts individually. Each one takes
`KEY=VALUE` arguments and documents them in its own header.

**Every phase and slow loop prints a timestamp and elapsed seconds** (a stall vs slow work);
`PROGRESS_EVERY=<seconds>` sets the heartbeat inside long loops (default 20).

**In discovery mode, each campaign starts on the harness of the build that produced it.
Whatever does not reproduce there is offered to the other builds, then to each harness
mode.** The risk of using the wrong build runs one way: an ASAN campaign minimized against
the plain build loses everything (the measured table: `references/afl-tool-reliability.md`,
"Which build reproduces").

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

**Minimization is afl-tmin, steered** (`references/afl-tool-reliability.md`, "In short").
A `DRIFT` row in REPORT.md means minimization wandered to another bug: report the original
bytes. Do not hand-minimize further.

### Buckets

Buckets are keyed on the sanitizer **SUMMARY** line: kind + `file:line` + function + access
(`READ-1`, `WRITE-8`). Never on stack frames: C++ frame text starts with the return type,
so half the crashes file under `char`.

**Report the second grouping, merged on function.** The SUMMARY key over-separates. On the
Node sibling, a 25-crash over-read in an unchecked UTF-8 decoder was reported at three lines
of one header: the exact key gave 6 buckets, and the merged key gave **4**, the published
answer. To judge whether two reports are one bug, compare the **allocation and the access**,
not the frame text, because inlining differs between the instrumented and pristine builds.
A third grouping, **merged on caller**, catches a root cause visible only in frame #1 (one
bad length into a shared helper from several sites). A bucket keyed on a `harness.cc` or
`shim.c` line is copied code: name the extension's line from the copy's source comment.

| bucket | meaning | action |
|---|---|---|
| `NO-REPORT signal-only sigN` | crashed, no sanitizer frame | usually **stack exhaustion**: a real DoS needing no sanitizer, not noise. **First** run the representative on the harness and grep stderr for `AFL-HARNESS-STUB: entered Ruby runtime:`. A stub trap (SIGTRAP/SIGILL) is the harness wandering into Ruby glue it did not mirror. That is a harness defect for the harness skill, not a finding |
| `hang in harness code (<frame>)` | only harness frames on the stacks | the loop is in the gem's Ruby dispatch the harness **mirrors**; the real stack decides (`HANG` there is a DoS in the gem's Ruby; CLEAN, a mirroring error) |
| `hang in <function>` | the bare harness never returned | **DoS in the native code itself.** Keyed by interrupting the sanitized harness with SIGABRT at several points and taking the innermost frame that is common to every sample and never recurs. Approximate: a loop inside a recursive walk can land in a coarser bucket on another run |
| `out-of-memory` | declared-size allocation | resource exhaustion; read the **plain** column |
| `NO-CRASH (rc=N)` | did not reproduce here | wrong build or mode, or a persistent-mode artifact |

Counts are distribution, not severity. An out-of-bounds **write** outranks a 1-byte read
regardless of count, which is why the access is in the key.

**A hang bucket is AFL's verdict at its exec timeout** (auto-calibrated, tens of ms, often
under ASAN): it also files merely slow inputs, and crashes that died late. REPORT.md labels
them: a hang row whose cells all answer (worst `CAUGHT`) in the cell timeout reads
`SLOW (not a hang: real stack answers in <t> s)`; one whose original bytes are
`NATIVE-CRASH` on the real stack is re-keyed as a crash, the hang key in the note.

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
   `RUNTIME-ABORT(sigN)`: a signal with a runtime invariant message (`Check failed:`,
   `Fatal error`) and no sanitizer report: a DoS, not memory safety (carried from Node).
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

Six kinds of cell are not verdicts. Fix them; do not report them:

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
* **`ERROR(version-mismatch=<got>!=<want>)`**: the installed gem is not `PKG_VERSION`;
  reinstall the pinned version in `oracle/`.
* **`ERROR(arm-wiring)`**: a `NameError` on a `confirm.rb` line, a helper the arm needs
  that was not pasted above the hash; not CAUGHT.
* **A column of all-CLEAN**: the signature of a mis-wired call, not a clean gem. `GOOD=` runs
  a working seed through the **plain** column first and prints its `evidence=`. A
  `type=nil`, `bytes=0` or `…=0` result means the column measures nothing (a getter
  hardcoded to succeed once passed a whole column of failed files).

The liveness run also proves the swap in each sanitized column (`# liveness EXT: CLEAN
swap=swapped`, a WARN otherwise), since a NATIVE-CRASH cell exits before it can.

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

`triage/REPORT.md` has one row per (minimized bytes, bucket key), the campaigns that found it
in one cell (per-campaign rows: `triage/report_rows.tsv`), and a "still to do by hand" list.
Its Scope lines are pre-filled from the manifest (execs, edges, stability, dictionary; the
`real_harness.rb` arms no campaign fuzzed); finish the two TODO lines.
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

**Over a system library rebuilt as an instrumented static archive** (the harness skill's
step 3b), the harness fuzzed the instrumented library, but the `gem+asan-ext` column swaps
in only the sanitized extension: the process still loads the uninstrumented system `.so`,
so that column cannot see an overflow inside the library. A bucket whose frame is in the
library's source can therefore read CLEAN or CAUGHT there while being real; only the plain
column's hard crash, or a sanitized build of the library put first on `LD_LIBRARY_PATH`
for that column (the harness skill's `references/oracle-ceiling.md`), is real-stack
evidence. Say so in the bug's write-up.

Do not quote crash counts as a measure of anything. Do not state a mechanism you have not
read the code for.

**If nothing is confirmed, including when there are no crash files at all**, cite the
harness skill's detection self-test and the campaign's execs and stability. Without them,
"nothing found" is indistinguishable from "the harness detects nothing", and is not a result.
The no-findings `REPORT.md` the driver writes carries both, plus a **Scope** section for
you to finish: the public API calls the entry points correspond to, those not covered, and
an `Instrumented:` line naming what the harness instrumented and sanitized. For a gem over
a system library rebuilt as a static archive, write that the library `<lib> <version>`
(upstream source matching the distro package) was instrumented and sanitized in the
direct harness only, and that the real stack's sanitized column runs the extension
against the uninstrumented system `.so`. For a parser in the extension, name the linked
objects and say what the shim mirrors. With no findings, `confirm.rb` never runs: prove
its wiring once by hand on a few corpus seeds (`$SKILLS/triage-fuzzing-findings/resources/confirm.sh
OUT=./triage-wiring ...`), or say it is unproven.

Hard crashes and memory-safety bugs in a widely installed gem are sensitive. Report to the
maintainer through the gem's security policy before posting anywhere public, with the
minimized input and the sanitizer trace. Do not post a working reproducer in a public issue
ahead of a fix.
