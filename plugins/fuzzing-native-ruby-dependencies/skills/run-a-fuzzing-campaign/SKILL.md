---
name: run-a-fuzzing-campaign
description: Run the AFL++ campaigns for a harnessed Ruby C extension (a gem's native extension) and record how each one ran, so triage needs no guesses. Sits between build-a-ruby-c-extension-fuzzing-harness / derive-a-fuzzing-corpus-from-source and triage-fuzzing-findings. Launches one afl-fuzz per build variant and harness mode, each with its own output directory and memory ceiling, switches a low-stability persistent campaign to the fork driver, and writes a manifest the triage skill reads. Use when asked to fuzz a built Ruby C extension harness or a native gem, run or drive an AFL++ campaign, or produce crashes for triage.
---

# Run a fuzzing campaign

The third skill in the chain: **harness** builds the target, **corpus** seeds it, this skill
**runs afl-fuzz**, and **triage** classifies what it finds. Its real job is not launching
afl-fuzz (a handful of command lines) but **recording how each campaign ran**, so
the triage skill reads the variant, harness mode, memory ceiling and stability instead of
guessing them. Every hard problem triage hit traced back to a campaign that threw this
information away.

It steers afl-fuzz; it does not replace it. afl-fuzz fuzzes; this skill decides which binary,
which harness mode, which memory ceiling, a separate output directory each, when to switch
driver, and when to stop, and writes it all down.

```sh
cd $W && . ./fuzz.env
$SKILLS/run-a-fuzzing-campaign/resources/campaign.sh DETACH=1 DURATION=600 \
    [MODES="MODE=2:mime"]      # default: fuzz.env's MODES; each VAR=value[:entry], settings joined with commas
```

Run it from the fuzz workspace (`$W` spelled out, since each tool call is a fresh shell);
`fuzz.env` (written by the harness skill) supplies `MODES` and `ALLOC_CAP_MB`, and an
explicit argument wins. Defaults discover the rest: every instrumented
`out/<variant>/harness-fork`, the first of `corpus-final`/`corpus`/`corpus-min`, and a
`selftest*.txt` with a `PASS:` line. Output lands in
`campaigns/<variant>[@<mode>][.fork]/`, one `afl-fuzz -o` each, with
`campaigns/manifest.tsv` beside them.

**Running it from a tool call.** A tool call is cut off after ten minutes, and a campaign
killed with its shell can leave `afl-fuzz` orphaned on the cores with no manifest row.
`DETACH=1` runs it detached, logs to `campaigns/campaign.log`, prints its pid and returns at
once. Poll `campaigns/campaign.log` and `campaigns/manifest.tsv` in later calls (each
starting with `cd $W && . ./fuzz.env`); to stop early, `kill -TERM <the printed pid>`,
which stops every live campaign and records it `interrupted`. The log's heartbeat repeats
`fuzzer_stats` values between afl-fuzz's periodic updates (about a minute apart), so
identical numbers for a minute are not a stall. The run is finished when the log ends
with its `DONE:` line (the last thing `campaign.sh` prints), not when the pid disappears
from one `ps`:

```sh
cd $W && . ./fuzz.env
tail -n1 campaigns/campaign.log | grep '^DONE:' || echo still running
```

## What it records, and why each line matters

One manifest row per campaign, with the columns triage was reconstructing by hand:

| column | triage used it for | what went wrong without it (in the Node sibling plugin's runs) |
|---|---|---|
| `variant` + `harness` | pair crashes with the build that made them | `campaign/asan2/` had no `out/asan2/`; the largest crash set was skipped |
| `mode_env` + `entry` | screen under the right mode, confirm through the matching gem API call | an image-decoding binding's `MODE=2` bugs filed "does not reproduce" until the mode was named by hand |
| `alloc_cap_mb` | screen at the ceiling the bug needs | a block-compression binding's 17 crashes reproduced 0 of 10 at the wrong ceiling |
| `map_size` | afl-fuzz needs it per binary or it segfaults | (none recorded) |
| `stability` | decide whether reproduction is deterministic | `RETRY` was a blind guess |
| `crash_files` (and `saved_crashes`) | the crash count, and detecting two fuzzers sharing one `-o` | 112 saved vs 64 files on disk, silently. The files are the truth; `fuzzer_stats` is periodic and lags a stopped campaign |
| `selftest` | tell "found nothing" from "detects nothing" | a clean result with no self-test means nothing |
| `status` | whether the campaign ran its full duration | a campaign that aborted at startup was recorded as `completed` and read as "found nothing" |
| `seeds_loaded` / `seeds_total` | how much of the corpus actually ran | `AFL_IGNORE_SEED_PROBLEMS` silently dropped one of 455 seeds |
| `dict` (last column) | which `-x` dictionary the campaign mutated with, or `none` | (none recorded) |

The `entry` field names the `confirm.rb` ENTRIES arm that reaches the same code through the
gem's Ruby API. By the chain's convention it is the **mode's value**: the harness skill's
`real_harness.rb` keys its consumer calls by MODE value in its `ENTRIES` hash (`MODE=file` →
the `file` arm) and triage's `confirm.rb` ENTRIES is that same hash, so `MODES="MODE=file"` records
`entry=file` by itself. Pass `MODE=2:mime` only when the mode's value is not the arm's name
(a numeric mode selecting the image object's MIME data mode). Either way it is written down
once, here, instead of triage rediscovering it.

## How it steers afl-fuzz

* **One output directory per (variant × mode).** Never shared: the `saved_crashes`/files
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
  leaves trimming and calibration out of `-V`): a campaign on an image-decoding Node
  binding with `-V 40` ran 268 s once it had saved a hang. `WALL=<seconds>` stops a campaign at a wall-clock ceiling and records
  it `walled`; its crashes are real, but it is never a "found nothing" result. The end-of-run summary says "found nothing" only if the
  self-test passed AND every campaign `completed`; otherwise it says the result is not one.
* **Seeds in, seeds run.** The corpus defaults to `corpus-final` (the union), not
  `corpus-min`: the corpus skill calls the greedy cover "a stop signal, not a reason to ship
  only the cover". `seeds_loaded` vs `seeds_total` records what `AFL_IGNORE_SEED_PROBLEMS`
  dropped, and `campaigns/<name>.dropped` names those seeds (a 0-byte file is always one).
* **A memory ceiling, the same number triage screens at first** (`ALLOC_CAP_MB`, 1024 MB):
  `max_allocation_size_mb` for a sanitized build, `afl-fuzz -m` for a plain one. A
  declared-size bug found here reproduces in triage because both use this number. Without a
  cap a plain build is OOM-killed (`sig:09`) and the bug looks like nothing reproducible.
* **`AFL_IGNORE_SEED_PROBLEMS=1`**, so a corpus seed that crashes or *hangs* in the dry run
  is skipped rather than aborting the whole campaign. The corpus skill leaves ASAN-only
  crashers in on purpose; this also covers a hanging or plain-crashing seed that slipped
  through (a looping seed otherwise aborts afl-fuzz at startup). On a sanitized variant an
  ASAN-only crasher seed is loaded but not fuzzed (the dry run skips it), so the code past
  it is reached only by mutation of other seeds; its bug is already in `crashers/`.
* **`AFL_MAP_SIZE` dumped from the exact binary** (persistent and fork differ: 197449 vs
  197424 on a stylesheet-compiler Node binding), or afl-fuzz segfaults on a large-map target.
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
from it. No hand-supplied `MODES`, `DIRS`, `ENTRIES` or `ALLOC_CAP_MB`. Validated in the Node sibling
plugin on a stylesheet-compiler binding: `asan` plus `asan` under a harness mode variable selecting its
file-path entry point (here an interrupted run) handed straight to triage, which screened
each against its own build and mode and bucketed both.

Triage does not trust the manifest blindly. It notes any campaign whose `status` is not
`completed` (its crashes are real; the absence of more is not), **warns about any crash or
hang directory on disk that the manifest does not list** (they would otherwise be silently
missed), and still triages a hand-saved `crashers/` directory under every recorded mode.
Fill in the `confirm.rb` ENTRIES arms the manifest's `entry` values name before triage's
confirm step, as the triage skill already requires.

## Knobs

`WORKSPACE CAMPAIGNS CORPUS VARIANTS MODES DEFAULT_ENTRY DURATION WALL STAB_CHECK
MIN_STABILITY ALLOC_CAP_MB TIMEOUT_MS SELFTEST POLL JOBS SCREEN DETACH DICT`, each documented in `campaign.sh`'s
header. `DURATION` is fuzz-time per campaign; `JOBS` (default cores−1) is how many run at
once. `DICT` is the `afl-fuzz -x` dictionary: `$W/dict.afl` (the corpus skill's `dict.sh`)
when it exists, else the variant's `out/<variant>/dict.afl` from the build; `DICT=none`
runs without one. The harness skill's smoke runs pick the same default. `SCREEN=1` runs each afl-fuzz inside a detached GNU `screen` session (`afl-<campaign>`)
with its UI on, so a person can watch it live with `screen -r afl-<name>` (detach with
`C-a d`; `C-c` would kill the campaign) while the script keeps owning the pid, the
stability fallback and the manifest. The evidence behind the choices is in the Node sibling plugin's
`fuzzing-native-node-dependencies/skills/run-a-fuzzing-campaign/EVIDENCE.md`; it was measured on Node bindings, and the AFL++
mechanics it covers are the same here.
