# Evidence behind the rules in SKILL.md

Not loaded with the skill. Tags: **[measured]** observed in a run listed here; **[tool]**
AFL++ 4.33c's own output; **[carried]** established on the Node sibling plugin
(`fuzzing-native-node-dependencies/skills/run-a-fuzzing-campaign/EVIDENCE.md`, including
its review-corrections table) and not re-measured on Ruby. Platform: the `sectainer` image
(Ubuntu 26.04 aarch64, 14 cores, Ruby 3.3.8, clang 21, AFL++ 4.33c), 2026-10-06.

`campaign.sh` is byte-identical in code to the Node plugin's (`scripts/check_shared.sh`).
It drives `out/<variant>/harness[-fork]`, which is a plain native binary whatever the
runtime behind the extension, so its rules are **[carried]** unless a row below says
otherwise.

Targets (as in the harness EVIDENCE): B, a gem with vendored libraries
(mini_portile2); C, a gem whose parser is the extension's own C.

## The Ruby run

Target C, one evaluation run (Sonnet) following the skill as written, `DURATION=300`,
default variants and modes, seeds `corpus-final` (213) [measured, eval run]:

| variant | mode | driver | execs | stability | crashes | hangs | status | selftest |
|---|---|---|---|---|---|---|---|---|
| asan | default | persistent | 20,161,020 | 98.63 % | 8 | 0 | completed-300s | passed |
| plain | default | persistent | 32,410,502 | 98.68 % | 0 | 0 | completed-300s | passed |

* Wall time 5 min 01 s for the two campaigns side by side; `alloc_cap_mb` 1024;
  `entry=default` recorded for both; the manifest was read by triage with no hand-supplied
  MODES, ENTRIES or ALLOC_CAP_MB.
* **seeds_loaded 212 of 213** -- the column did its job (a dropped seed is visible), but
  the manifest does not say which seed was dropped. [measured; not yet addressed]
* Stability > 90 % on both, so the fork fallback was not exercised on Ruby.
* The crashes appeared only in the asan campaign and were all one real low-severity
  memory-safety bug (an ASAN-only 1-byte read; triage EVIDENCE): the plain build at 32 M execs saw nothing, which is
  why an asan campaign runs beside the throughput one. [measured]

## Two 10-minute runs (DURATION=600), side by side on one host

| target | variant | mode | execs | stability | crashes | status |
|---|---|---|---|---|---|---|
| B | asan | default | 1,912,119 | 95.89 % | 0 | completed |
| B | plain | default | 4,337,146 | 95.98 % | 0 | completed |
| C | plain | default | 27.6 M | 92.87 % | 0 | completed |
| C | plain | load | 60.1 M | 93.03 % | 0 | completed |
| C | asan | default | 15.2 M | 93.22 % | 6 | completed |
| C | asan | load | 16.0 M | 93.92 % | 10 | completed |

[measured, eval runs] Six campaigns on 14 cores at once: throughput is contended (target
B plain fell from 45.6k execs/s in smoke to 7.2k/s with a 597-seed corpus; target C's two
plain campaigns differ 2x). Every manifest loaded all seeds but one (`seeds_loaded`
n-1/n); the empty seed is the likely skip, not confirmed. No campaign switched to the fork
driver.

## Not yet measured on Ruby

The fork-driver switch on low stability, the interrupt trap, the status decision on an
aborted start, and one-output-directory-per-campaign are **[carried]** with their Node
review corrections. The Ruby record is the three campaigns above (target C 5 and 10 min,
target B 10 min), all at stability above 90 %.
