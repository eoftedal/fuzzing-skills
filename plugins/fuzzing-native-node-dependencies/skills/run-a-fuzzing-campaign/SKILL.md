---
name: run-a-fuzzing-campaign
description: Run the AFL++ campaigns for a harnessed native Node addon and record how each one ran, so triage needs no guesses. Sits between build-a-nan-napi-fuzzing-harness / derive-a-fuzzing-corpus-from-source and triage-fuzzing-findings. Launches one afl-fuzz per build variant and harness mode, each with its own output directory and memory ceiling, switches a low-stability persistent campaign to the fork driver, and writes a manifest the triage skill reads. Use when asked to fuzz a built NAN/N-API harness, run or drive an AFL++ campaign, or produce crashes for triage.
---

# Run a fuzzing campaign

The third skill in the chain: **harness** builds the target, **corpus** seeds it, this skill
**runs afl-fuzz**, and **triage** classifies what it finds. Its real job is not launching
afl-fuzz — that is a handful of command lines — but **recording how each campaign ran**, so
the triage skill reads the variant, harness mode, memory ceiling and stability instead of
guessing them. Every hard problem triage hit traced back to a campaign that threw this
information away. The runs behind each rule, with their figures, are in
`references/measured-cases.md`; they are what happened on other targets, not what to expect
on yours.

It steers afl-fuzz; it does not replace it. afl-fuzz fuzzes; this skill decides which binary,
which harness mode, which memory ceiling, a separate output directory each, when to switch
driver, and when to stop — and writes it all down.

```sh
cd $W && . ./fuzz.env           # $W written out as the absolute workspace path: a fresh shell has no variables
$SKILLS/run-a-fuzzing-campaign/resources/campaign.sh DETACH=1 DURATION=600
```

Run it from the fuzz workspace. `fuzz.env` (written by the harness skill) supplies `MODES`,
`ALLOC_CAP_MB` and the rest; an explicit `KEY=VALUE` argument wins, for example
`MODES="MODE=2:mime"` (modes besides the default, each `VAR=value[:entry]`, several settings
joined with commas). A `MODE` variable left set in your own shell would select one mode for
every campaign; the script detects it and warns. Defaults discover the rest: every instrumented
`out/<variant>/harness-fork`, the first of `corpus-final`/`corpus`/`corpus-min`, and a
`selftest*.txt` with a `PASS:` line. Output lands in `campaigns/<variant>[@<mode>][.fork]/`,
one `afl-fuzz -o` each, with `campaigns/manifest.tsv` beside them.

## Running it from a tool call

A tool call stops at ten minutes and kills its process group, which would orphan `afl-fuzz`
and leave the manifest without rows. So run it detached: `DETACH=1` re-execs the script
under `nohup`, logs to `campaigns/campaign.log`, prints its pid and returns at once. Each
call is a fresh shell, so start every poll the same way:

```sh
cd $W && . ./fuzz.env
tail -n 20 campaigns/campaign.log; cat campaigns/manifest.tsv
```

The run is finished when `campaigns/campaign.log` ends with the script's `DONE:` line, the
one thing to wait on (`grep -q '^DONE:' campaigns/campaign.log`); every planned manifest
row then has a `status`, and the summary is in the lines above it. The log's heartbeat repeats `fuzzer_stats` values
between afl-fuzz's periodic updates of that file, so the same numbers for a minute are not
a stall; a stall is a heartbeat that stops. To stop early, `kill -TERM <the printed pid>`: the
script stops every live `afl-fuzz` and records each as `interrupted`.

## What it records, and why each line matters

One manifest row per campaign, with the columns triage was reconstructing by hand:

| column | triage used it for | what went wrong without it |
|---|---|---|
| `variant` + `harness` | pair crashes with the build that made them | a campaign directory with no build of the same name (`asan2/`, no `out/asan2/`) was skipped whole |
| `mode_env` + `entry` | screen under the right mode, confirm through the matching npm call | bugs found in a non-default mode filed "does not reproduce" until the mode was named by hand |
| `alloc_cap_mb` | screen at the ceiling the bug needs | crashes screened at a different ceiling from the campaign's did not reproduce |
| `map_size` | afl-fuzz needs it per binary or it segfaults | afl-fuzz segfaults |
| `stability` | decide whether reproduction is deterministic | `RETRY` was a blind guess |
| `crash_files` (and `saved_crashes`) | the crash count, and detecting two fuzzers sharing one `-o` | `saved_crashes` and the files on disk disagreed, silently. The files are the truth; `fuzzer_stats` is periodic and lags a stopped campaign |
| `selftest` | tell "found nothing" from "detects nothing" | a clean result with no self-test means nothing |
| `status` | whether the campaign ran its full duration | a campaign that aborted at startup was recorded as `completed` and read as "found nothing" |
| `seeds_loaded` / `seeds_total` | how much of the corpus actually ran | `AFL_IGNORE_SEED_PROBLEMS` silently dropped seeds |
| `dict` | which dictionary afl-fuzz had; a token-driven finding is reproducible only with it | |

The `entry` field names the `confirm.mjs` ENTRIES arm that reaches the same code through the
npm API. By the chain's convention it is the **mode's value**: the harness skill's
`real_harness.mjs` keys its consumer calls by MODE value (`MODE=file` → the `file` arm) and
triage's `confirm.mjs` ENTRIES is that same object, so `MODES="MODE=file"` records
`entry=file` by itself. Pass `MODE=2:mime` only when the mode's value is not the arm's name
(a numeric mode selecting the image object's MIME data mode). Either way it is written down
once, here, instead of triage rediscovering it.

## How it steers afl-fuzz

* **One output directory per (variant × mode).** Never shared — the `saved_crashes`/files
  mismatch that corrupts a count comes from two fuzzers in one `-o`.
* **Persistent first, fork on low stability.** It starts the persistent binary, reads
  `stability` from `fuzzer_stats` after `STAB_CHECK` seconds, and if it is below
  `MIN_STABILITY` (90%) **stops it for real** and relaunches on `harness-fork`. Both
  campaigns stay in the manifest (`switched`, then `completed`): below ~70% the feedback is
  noise and every crash is suspect. "Stops for real" is a requirement, not a detail:
  `afl-fuzz` is launched as a direct child so the pid is its own, because an earlier version
  signalled a wrapper subshell and the unstable campaign kept fuzzing the same cores.
  A variant with only `harness-fork` runs on the fork driver from the start (`driver=fork`).
* **Ctrl-C and SIGTERM are handled.** Every live campaign is stopped and recorded as
  `interrupted`, so no `afl-fuzz` is orphaned and no crash directory is left without a
  manifest row.
* **`status` is observed, not assumed.** From afl-fuzz's exit status, its `PROGRAM ABORT`
  line, `fuzzer_stats` and the elapsed time: `completed`, `switched`, `interrupted`,
  `walled`, `aborted`, `failed` or `early`. `DURATION` is fuzz time, not wall-clock (AFL
  leaves trimming and calibration out of `-V`), so a campaign that has saved a hang can run
  several times its `DURATION`. `WALL=<seconds>` stops a campaign at a wall-clock ceiling and records
  it `walled`; its crashes are real, but it is never a "found nothing" result. The end-of-run summary says "found nothing" only if the
  self-test passed AND every campaign `completed`; otherwise it says the result is not one.
* **Seeds in, seeds run.** The corpus defaults to `corpus-final` (the union), not
  `corpus-min`: the corpus skill calls the greedy cover "a stop signal, not a reason to ship
  only the cover". `seeds_loaded` vs `seeds_total` records what `AFL_IGNORE_SEED_PROBLEMS`
  dropped, and `campaigns/<name>.dropped` names those seeds (typically a zero-byte one,
  which afl-fuzz cannot use).
* **A memory ceiling, the same number triage screens at first** (`ALLOC_CAP_MB`, 1024 MB):
  `max_allocation_size_mb` for a sanitized build, `afl-fuzz -m` for a plain one. A
  declared-size bug found here reproduces in triage because both use this number. Without a
  cap a plain build is OOM-killed (`sig:09`) and the bug looks like nothing reproducible.
* **`AFL_IGNORE_SEED_PROBLEMS=1`**, so a corpus seed that crashes or *hangs* in the dry run
  is skipped rather than aborting the whole campaign. The corpus skill leaves ASAN-only
  crashers in on purpose; this also covers a hanging or plain-crashing seed that slipped
  through (a looping seed otherwise aborts afl-fuzz at startup). The log lists those
  crashers as "crashed in the dry run" (loaded, not fuzzed): afl-fuzz never mutates them,
  so their neighbourhood is reached only through mutation of neighbouring seeds; triage
  still screens them from `crashers/`.
* **`AFL_MAP_SIZE` dumped from the exact binary** (persistent and fork builds of one target
  differ), or afl-fuzz segfaults on a large-map target.
* **The detection self-test is a precondition, and must be fresh.** No `PASS:` self-test and
  no `SELFTEST=skip` → it refuses to run, because a campaign that finds nothing against a
  harness that detects nothing is not a result. A self-test older than the harness binary is
  recorded as `stale` (it proved a different binary). `SELFTEST=skip` records the gap in
  every row.
* **Sanitized is read from the binary**, as triage does, not guessed from the variant's name.
* **Re-running replaces a campaign's row** rather than adding a second one for the same
  directory.

## Hand-off to triage

Run the triage skill from the same workspace with nothing else: `triage_all.sh` finds
`campaigns/manifest.tsv`, and takes the variant, harness, `mode_env`→`entry` map and ceiling
from it. No hand-supplied `MODES`, `DIRS`, `ENTRIES` or `ALLOC_CAP_MB`: a campaign per build
and mode, interrupted or not, is screened against its own build and mode.

Triage does not trust the manifest blindly. It notes any campaign whose `status` is not
`completed` (its crashes are real; the absence of more is not), **warns about any crash or
hang directory on disk that the manifest does not list** (they would otherwise be silently
missed), and still triages `crashers/` and `hangs/` (the corpus skill's seed policy and
the harness skill's smoke run fill them) under every recorded mode, even when no campaign
saved a crash.
Fill in the `confirm.mjs` ENTRIES arms the manifest's `entry` values name before triage's
confirm step, as the triage skill already requires.

## Knobs

`WORKSPACE CAMPAIGNS CORPUS VARIANTS MODES DEFAULT_ENTRY DURATION WALL STAB_CHECK
MIN_STABILITY ALLOC_CAP_MB TIMEOUT_MS SELFTEST POLL JOBS SCREEN DETACH DICT` — each documented in `resources/campaign.sh`'s
header. `DURATION` is fuzz-time per campaign; `JOBS` (default cores−1) is how many run at
once. `DICT=` is passed as `afl-fuzz -x`: by default `$W/dict.afl` (the corpus skill's
merged dictionary), else the variant's `out/<variant>/dict.afl` from its build; `DICT=none`
runs without one. The harness skill's smoke runs pick the same default. `SCREEN=1` runs each afl-fuzz inside a detached GNU `screen` session (`afl-<campaign>`)
with its UI on, so a person can watch it live with `screen -r afl-<name>` (detach with
`C-a d`; `C-c` would kill the campaign) while the script keeps owning the pid, the
stability fallback and the manifest. The evidence behind the choices is in `EVIDENCE.md`.
