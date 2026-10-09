# Skills

These skills are for finding vulnerabilities, not exploiting them. They stop at a classified,
minimized reproducer to report to the maintainer.

Fuzzing a native Node addon, in the order you use them:

- **build-a-nan-napi-fuzzing-harness**: build a direct AFL++ harness for the native library behind a NAN or N-API addon, prove it matches the real stack and detects faults, then smoke-test it for crashes of its own.
- **derive-a-fuzzing-corpus-from-source**: create or improve a high-coverage seed corpus by reading the target's parser source instead of collecting sample files.
- **run-a-fuzzing-campaign**: run the AFL++ campaigns (one per build variant and harness mode) and write a manifest recording how each ran.
- **triage-fuzzing-findings**: screen, bucket, minimize and confirm the crashes and hangs against the real npm package, to separate real bugs from artifacts.

What the skills hand each other, so the names stay the same end to end:

| artifact | written by | read by |
|---|---|---|
| `fuzz.env` (`SKILLS R RC W PKG_NAME PKG PKG_VERSION ADDON_ASAN MODES FIELDS SOFT_FIELD SOFT_DROP ALLOC_CAP_MB REAL REAL_ASAN`) | harness (`init_workspace.sh`, re-run as keys become known) | every skill's scripts, as defaults; an explicit argument wins |
| `out/<variant>/{harness,harness-fork,map_size}` | harness | corpus, campaign, triage |
| `out/<variant>/dict.afl`, `dict.afl` | harness builds, per variant (the constants the instrumented code compares against); corpus (`dict.sh` merges it with the author's tokens into `$W/dict.afl`) | campaign (`campaign.sh DICT=`, and `smoke.sh` through it: `$W/dict.afl`, else the variant's) |
| `corpus/` (the gate corpus), `real_harness.mjs`, `oracle/` | harness (`mkgate.sh` writes the gate corpus's truncations and flips) | corpus (re-gate), triage (`PKG=oracle/node_modules/<pkg>`, `GOOD=` a gate seed) |
| `selftest.txt` with its `PASS:` line | harness | campaign (refuses without it; flags it stale if a harness is newer) |
| `corpus-final/`, `hangs/` | corpus | campaign (`corpus-final/` is the default seed set), triage (`hangs/` is screened against every variant) |
| `crashers/` with `crashers.summary.tsv` | corpus (seed policy), harness (`smoke.sh`: one per `REAL` or `PERSISTENT-ONLY` site; the gate's `CRASHES-BOTH` seeds, moved by hand) | triage (screened against every variant, even when no campaign saved a crash) |
| `confirm.mjs` | you, in the workspace, from the triage skill's template (`ENTRIES` pasted from `real_harness.mjs`) | triage (`triage_all.sh` / `confirm.sh` by default; `CONFIRM=` points elsewhere) |
| `campaigns/manifest.tsv` | campaign | triage (variant, harness, mode, entry, ceiling, status per campaign) |
| `triage/REPORT.md` | triage | you |

Four conventions run through all four:

* **A harness mode is an entry point, named after it.** The harness reads `MODE=<value>` from the
  environment, never from an input byte; `real_harness.mjs` keeps its consumer calls in an
  `ENTRIES` object keyed by that value; the campaign records each mode's `entry` as that value;
  `confirm.mjs`'s `ENTRIES` is the same object. `MODES="MODE=file"` means the same thing to
  `gate.sh`, `smoke.sh`, `campaign.sh` and `triage_all.sh`.
* **One allocation ceiling, `ALLOC_CAP_MB` (1024).** The gate, the campaign (`-m` or
  `max_allocation_size_mb`), the corpus skill's crasher pass and the triage ladder's first rung
  all use it, so a declared-size bug found in one step reproduces in the next.
* **`err=` is one token**, the library's own error name or code, identical on both sides of the
  gate; the corpus skill's histograms and error inventory steer by it.
* **Every command block starts with `cd $W && . ./fuzz.env`**, because a model's shell does
  not persist between tool calls: a variable set in one block is gone in the next, and a bare
  `resources/` path resolves against the workspace. `$W` is written out as the absolute path;
commands use `$R/` and `$RC/` from the file.
