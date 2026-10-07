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
