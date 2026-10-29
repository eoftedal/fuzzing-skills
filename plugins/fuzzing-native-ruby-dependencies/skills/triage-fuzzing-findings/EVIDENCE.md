# Evidence behind the rules in SKILL.md

Not loaded with the skill. Tags: **[measured]** observed in a run listed here; **[tool]**
the installed tool's own output; **[carried]** established on the Node sibling plugin
(`fuzzing-native-node-dependencies/skills/triage-fuzzing-findings/EVIDENCE.md`) and not
re-measured on Ruby. Platform: the `sectainer` image (Ubuntu 26.04 aarch64, Ruby 3.3.8,
clang 21, AFL++ 4.33c), 2026-10-06.

`screen.sh`, `bucket.sh` and `minimize.sh` are code-identical to the Node plugin's except
for message text (`scripts/check_shared.sh`); `confirm.rb`, `confirm.sh` and the
discovery/entry logic in `triage_all.sh` are Ruby-specific and were measured here.

Targets (as in the harness EVIDENCE): A, a gem over a system library; B, a gem with vendored
libraries (mini_portile2); C, a gem whose parser is the extension's own C.

## The verdict ladder, on a fabricated fixture gem

A fabricated fixture gem: a C extension that misbehaves per input byte, installed with
`gem install --platform ruby` and built plain/asan/pristine with `build_ext.sh`. All 21
cells correct [measured]:

| input | gem-install(plain) | gem+asan-ext | gem+pristine-ext |
|---|---|---|---|
| NULL dereference | NATIVE-CRASH(bug-Segmentation-fault) | same | same |
| C loop holding the GVL | HANG(cell-timeout) | same | same |
| `rb_memerror()` | UNCAUGHT | SKIPPED | SKIPPED |
| 1-byte heap over-read of malloc(16) | CLEAN | NATIVE-CRASH(heap-buffer-overflow) | NATIVE-CRASH(heap-buffer-overflow) |
| `rb_raise(rb_eArgError)` | CAUGHT | same | same |
| Ruby infinite recursion (SystemStackError) | UNCAUGHT | same | same |
| exception in a gem-started Thread | UNCAUGHT | same | same |

Liveness on a good input: CLEAN `evidence=bytes=12`; swap liveness `swap=swapped` in both
sanitized columns, and `swap=NOT-SWAPPED` with a WARN when EXT_MATCH misses [measured].

## A real campaign: target C

One evaluation run (Sonnet), the 5-minute campaign in the campaign skill's EVIDENCE
[measured, eval run; re-checked by hand]:
* 8 asan crashes -> **1 bucket**: one real low-severity memory-safety bug (an ASAN-only
  1-byte read), found and confirmed on target C.
* Verdicts: CAUGHT on the release install (the gem's namespaced exception class),
  NATIVE-CRASH on the asan and pristine extensions -- through both its parse and load
  methods once all `confirm.rb` arms ran. Reproducing on the pristine build rules out an
  instrumentation artifact.
* Machine time: triage ~4 s per run.
* Classification: low severity, read-only, ASAN-only; for the maintainer, not reported
  elsewhere.

## Two 10-minute campaigns

* Target C: 16 crashes over two modes -> 2 bucket rows, one bug (the same one), CAUGHT /
  NATIVE-CRASH / NATIVE-CRASH through its parse and load methods; triage 13 s [measured, eval run].
* Target B: no crashes or hangs. The driver wrote no REPORT.md, so a negative result had
  no record of what supported it; it now writes a no-findings report (campaign table with
  seconds, execs, stability, self-test line, scope), checked on that run [measured].

## Rules, and the run that produced each

| rule | run | what was measured |
|---|---|---|
| `timeout -k`: a GVL-holding C loop ignores SIGTERM | fixture | one cell ran 10 min past an 8 s timeout; ruby defers signals to interrupt checks [measured] |
| exit 137 before the timeout is a real SIGKILL, after it is timeout's own | fixture | separated by elapsed time [measured] |
| a full sanitizer report before `[BUG]`, then `[BUG]`, then bare DEADLYSIGNAL | fixture | Ruby's [BUG] abort under ASAN prints `AddressSanitizer:DEADLYSIGNAL` without a report; the old order gave an empty label [measured] |
| `use_sigaltstack=0` for ruby under ASAN (re-exec) | fixture, A | every Ruby thread exit died in "CHECK failed ... unable to unmmap"; a thread-using gem read NATIVE-CRASH(CHECK) [measured] |
| NoMemoryError: SKIPPED under the cap, UNCAUGHT without | fixture | as in the table [measured] |
| run every arm `confirm.rb` defines, not only the manifest's entries | C | the run's load-method arm was never executed because the manifest named only `default`; after the change both arms ran and both reproduce [measured] |
| build the pristine variant once there are crashes | C | the first triage had an empty pristine column; the driver now says so up front [measured, eval run] |
| a liveness run per sanitized column | fixture | a crashing cell exits before it can report its swap state [measured] |
| the ASAN column cannot see over-reads of a small INPUT String | Ruby 3.3 | Strings under ~616 bytes live in their GC slot (harness EVIDENCE) [measured] |
| fixture over-reads must keep the pointer opaque | fixture | clang -O2 elided the malloc/free pair and the read; the row read CLEAN until `asm volatile` [measured] |
| screening ceilings, bucket keys, tmin steering, the AFL tool caveats | Node sibling | [carried]; on target C the chain ran without hand input and produced one bucket from 8 crashes |

## Not yet measured on Ruby

Hangs and memory-amplification entries from a real campaign (target C had none), a gem
that loads several extensions (`EXT_MAP`), non-default harness modes (`MODES`), and
non-reproducers are **[carried]**.

## Chain review mirrored from the Node plugin (2026-10-08)

| change | tag | evidence |
|---|---|---|
| `triage_all.sh`/`confirm.sh` default `PKG`, `EXT`, `MODES`, `ALLOC_CAP_MB` and `ASAN_RT` from `fuzz.env`; `confirm.rb` arms take the input, `as_file(b, ext)`, version-mismatch cell, flushed `die` | [measured, synthetic] | stub gem under Ruby 3.3 in the container (see the harness skill's EVIDENCE for the arity bug this fixed) |

## Second evaluation round (2026-10-08)

Four fresh agents (Opus and Sonnet, a gem whose parser is the extension's own C and a gem
over a system library) ran the chain end to end; the per-run friction and the fixes are
tabulated in the harness skill's EVIDENCE.md under the same heading, including the rows
that belong to this skill. Corpus phases took 3 to 6 minutes, campaigns were
`DURATION=300 JOBS=2` and all completed, triage ran in 1 to 13 minutes.

## Mirrored from the Node plugin's evaluation round (2026-10-08)

The shared scripts changed identically in both plugins (`check_shared.sh`: 0 drift) after
four Node runs; the rows are in the Node plugin's EVIDENCE.md files under the same heading.
On this plugin they are **[carried]** except where the Ruby-side templates and text were
adjusted to match (the empty-output hash rule, the framing-not-a-mode rule, `mkgate.sh`,
`CRASHES-BOTH` and `known-crasher`, the `DONE:` marker, pristine before triage, the caller
grouping and `DRIFT`).

## Mirrored from the Node plugin's round 3 fixes (2026-10-09)

**[carried]**, not yet run on a gem; the Node rows are in the Node plugin's triage EVIDENCE.md
under the same heading. Shared code changed identically (`bucket.sh`: the
`hang in harness code (<frame>)` key; `triage_all.sh`: real-stack-only confirmation of
unresolved `crashers/`, liveness of every arm on a run with no bucket, REPORT rows deduplicated
on (minimized sha1, key) with `report_rows.tsv`, Scope pre-filled from the manifest and
`real_harness.rb`; `confirm.sh`: `RUNTIME-ABORT(sigN)` for a signal with `Check failed:` or
`Fatal error` and no sanitizer report, `LIVENESS_ONLY=1`, `EXT_MATCH` defaulting to
`fuzz.env`'s `ADDON_MATCH`). `confirm.rb` does not get the Node settle wait: Ruby has no event
loop to deliver a throw after the call returns (a gem thread that dies later ends the process
only under `Thread.abort_on_exception`, and `exit!` skips `at_exit`). To make room, the
minimization and pipeline-order paragraphs moved from SKILL.md to
`references/afl-tool-reliability.md` ("In short"), and a stale sentence saying the liveness run
does not prove the swap was replaced: `confirm.sh` already runs a liveness cell per sanitized
column and prints its `swap=` state.

## Mirrored from the Node plugin's round 4 fixes (2026-10-09)

| change | tag | evidence |
|---|---|---|
| `triage_all.sh`/`screen.sh` read every instance's `*/crashes` and `*/hangs` (`default/`, `main/`, `s<i>/`), dedup by content across them, and keep the instance in the pool name; every REPORT cell has a value (`(not minimized...)`, `(not confirmed...)`); a hang row whose worst cell is `CAUGHT` reads `SLOW (not a hang: real stack answers in <t> s)` from the install cell's seconds (new 6th `verdicts.tsv` column, also in this plugin's `confirm.sh`); a hang representative that is `NATIVE-CRASH` on the real stack is re-keyed as a crash with `bucket.sh HANGS=0`; not-minimized rows hash their original bytes (they hashed nothing and merged) | **[carried]** | measured on a Node workspace (the Node EVIDENCE.md, same heading). Identical shared code here (`check_shared.sh`: 0 drift); the `confirm.sh` column was added by the same edit to the Ruby copy, `bash -n` only. Not yet run on a gem. SKILL.md: the bucket-section paragraph and the manifest row; to fit under 30,000 bytes, three sentences were shortened (scripts check results, smoke's crashers, the modes example's last sentence, a `TIMEOUT_MS` aside) |
