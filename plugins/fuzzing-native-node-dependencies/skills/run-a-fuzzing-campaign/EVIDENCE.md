# Evidence behind the rules in SKILL.md

Not loaded with the skill. Marked **[measured]** (observed in this workspace), **[tool]**
(the installed AFL++ 4.33c's own output), or **[carried]** (established by the sibling
skills). AFL++ 4.33c, aarch64, container kernel 6.12, bash 5.3, 14 cores.

Validated on **a stylesheet-compiler binding** in a recorded evaluation run: campaigns of
`asan` and `asan` under a harness mode variable (e.g. `MODE=file`) selecting the binding's
file-path entry point, then handed to the triage skill with no hand-supplied `MODES`,
`DIRS`, `ENTRIES` or `ALLOC_CAP_MB`.

## Review corrections

A review of the first version found that several things this file used to call validated
were not. The corrections are kept because each is easy to reintroduce.

| what was claimed | what a test showed | fix |
|---|---|---|
| the stability fallback "stops and relaunches" | **[measured]** it did not stop anything: the script kept the pid of a wrapper subshell, so `kill` hit the wrapper. 10 of the persistent campaign's 36 crashes were written after the "switch", and its `fuzzer_stats` was still updating 38 s later. Both campaigns ran. My earlier "mechanism works" came from reading manifest rows, not the process | `afl-fuzz` is a direct child (`env` exec()s it, so `$!` is its pid); `stop_one` sends TERM, waits, then KILL. After the fix: 0 crash files written after the switch, no process left |
| every campaign recorded `completed-<DURATION>s` | **[measured]** the first run's `afl-fuzz` aborted at startup (`PROGRAM ABORT: ... results in a timeout`) and the manifest said `completed-40s` with no stats and 0 crashes. With a passing self-test the summary would have printed "found nothing" | `status` is decided from afl-fuzz's exit status, the `PROGRAM ABORT` line, `fuzzer_stats` and elapsed time; the summary refuses "found nothing" unless every campaign `completed` |
| an interrupted run is harmless | **[measured]** SIGTERM to `campaign.sh` killed the script, left `afl-fuzz` running, and wrote 0 manifest rows while 30 crash files sat on disk, so triage would never see them | INT/TERM trap stops every campaign and records each as `interrupted`; after the fix 0 orphans and both rows present (28 + 18 crash files) |
| re-running is safe | **[measured]** two runs in one workspace gave two rows for one campaign; triage would process the directory twice under one tag | a row replaces any earlier row of the same name |
| `saved_crashes` from `fuzzer_stats` is the crash count | **[measured]** `saved_crashes=0` against 24 files on a stopped campaign (stats are periodic): a false "two fuzzers sharing one -o" warning, and summary totals that could read 0 | files on disk are the truth; the stats are a diagnostic and warn only after a normal finish |
| the `-` sentinel for "default mode" was harmless | **[measured]** it leaked into `launch()` on the fork relaunch: the campaign was named `asan@.fork`, and `-` as an `env` argument means "start with an empty environment" | state is kept in arrays in the main shell, with no sentinel round-trip |
| prefer `corpus-min` | **[carried]** the corpus skill says the greedy cover is "a stop signal, not a reason to ship only the cover" and to ship the union | default `corpus-final`, then `corpus`; `corpus-min` last |
| "found 26 crashes that the default mode does not surface the same way" | unsupported; removed. What was measured: triage under the file-path mode bucketed to 2 groups (22 in the error reporter, 4 in an unchecked UTF-8 decoder) while the default mode gave 6 groups, so the two modes reach different code | — |
| "14 cores [measured]" for `JOBS` | that is `nproc`; `cores - 1` is a choice, not a measurement | reworded |

## Rules

| rule in SKILL.md | how it was established |
|---|---|
| one `afl-fuzz -o` per (variant × mode), never shared | **[carried]** two fuzzers in one `-o` left `fuzzer_stats` claiming 112 saved crashes over 64 files |
| record the build variant and harness per campaign | **[carried]** `campaign/asan2/` had no `out/asan2/`, so name-based pairing skipped the largest crash set (111 of 188) |
| record `mode_env` and the `entry` it maps to | **[measured]** see the correction above: the two modes reach different code, and triage read `entry=file` from the manifest and screened under the file-path mode with no manual `MODES=` |
| the `entry` must be supplied by a human | the harness mode → npm call mapping (`MODE=2` ↔ the image object's MIME data mode; the file-path harness mode ↔ the stylesheet-compiler binding's file-path entry point) is not derivable from the binary |
| persistent first, fork below `MIN_STABILITY` | **[carried]** below ~90 % an iteration sees the previous one's state; **[measured]** with `MIN_STABILITY=101` forced, the switch happened at +10 s, the old campaign stopped, and `asan.fork` completed with stability 100.00 vs 99.94 |
| a memory ceiling, the same number triage screens at first | **[measured]** a block-compression binding: 17 crashes, all `sig:09`, reproduce 0 of 10 at 4096 MB and 10 of 10 at 1024 |
| sanitized → `max_allocation_size_mb`, plain → `afl-fuzz -m` | **[tool]** a sanitizer build cannot take `-m`. **[measured]** the plain path, never run in the first version, works: `-m 1024`, 99.03 % stability, 2 crashes and 2 hangs in 30 s on the stylesheet-compiler binding |
| decide "sanitized" by looking in the binary | the first version matched the variant NAME (`*asan*`); triage greps for `__asan_report_load`, and the two could disagree |
| `AFL_IGNORE_SEED_PROBLEMS=1` | **[measured]** `corpus-final` holds a looping seed; without the flag afl-fuzz aborted at startup. `AFL_SKIP_CRASHES` covers crashes only |
| record seeds loaded vs total | **[measured]** `Loaded a total of 454 seeds` for a 455-seed directory: the flag silently dropped one, and nothing recorded it |
| `AFL_MAP_SIZE` dumped from the exact binary | **[measured]** stylesheet-compiler binding: persistent 197449 vs fork 197424 |
| the detection self-test is a precondition, and must be fresh | **[carried]** "found no crashes" and "detects nothing" print the same. **[measured]** no self-test and no `SELFTEST=skip`: exit 1, nothing created. A self-test older than the harness binary is flagged `stale` and the summary says it cannot vouch |
| `WALL`: a wall-clock ceiling, because `-V` is fuzz time | **[measured]** the image-decoding binding's next major version (a zig build), plain build, `-V 40`: `fuzzer_stats` showed 268 s between `start_time` and `last_update` after the campaign saved a hang. With `DURATION=300 WALL=15` on the stylesheet-compiler binding the campaign was stopped at 15 s, recorded `walled`, left no process, and the summary said "did not run to completion" |
| `-V <seconds>` to bound each campaign | **[tool]** afl-fuzz exits cleanly after that much fuzz time, which lets the script reap and record it |
| triage warns about crash directories not in the manifest, and still triages `crashers/` | **[measured]** a planted `stray/old/default/crashes` was listed as "NOT in the manifest and will not be triaged"; a hand-saved crasher was screened, bucketed and minimized through the manifest-driven path |

Two bugs worth keeping in mind:

* **`grep -c ... || echo 0`** prints `0` twice (grep -c prints 0 *and* exits 1); the extra
  line shifted every manifest column.
* **A background `( cd X && cmd ) &`** backgrounds the whole AND-list, so `$!` is the wrapper
  and signals sent to it never reach `cmd`. The first version of this script had this bug,
  and so did the first test of the fix.

Scope: this skill runs campaigns and records them. It does not build the harness
(`build-a-nan-napi-fuzzing-harness`), derive the corpus (`derive-a-fuzzing-corpus-from-source`)
or decide which crashes are real (`triage-fuzzing-findings`).
