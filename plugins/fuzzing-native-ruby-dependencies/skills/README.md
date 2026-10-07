# Skills

These skills are for finding vulnerabilities, not exploiting them. They stop at a classified,
minimized reproducer to report to the maintainer.

Fuzzing a Ruby gem's C extension, in the order you use them:

- **build-a-ruby-c-extension-fuzzing-harness**: build a direct AFL++ harness for the C library behind a gem's C extension (mkmf, `extconf.rb`), prove it matches the real stack and detects faults, then smoke-test it for crashes of its own.
- **derive-a-fuzzing-corpus-from-source**: create or improve a high-coverage seed corpus by reading the target's parser source instead of collecting sample files.
- **run-a-fuzzing-campaign**: run the AFL++ campaigns (one per build variant and harness mode) and write a manifest recording how each ran.
- **triage-fuzzing-findings**: screen, bucket, minimize and confirm the crashes and hangs against the real gem, to separate real bugs from artifacts.

What the skills hand each other, so the names stay the same end to end:

| artifact | written by | read by |
|---|---|---|
| `out/<variant>/{harness,harness-fork,map_size}` | harness | corpus, campaign, triage |
| `out/<variant>/{<ext>.so,Makefile,extconf.h,obj/,lib/}` | harness (`build_ext.sh`) | harness (`link_harness.sh`), triage (the sanitized `.so` swapped into the real gem) |
| `corpus/` (the gate corpus), `real_harness.rb`, `oracle/` | harness | corpus (re-gate), triage (`PKG=oracle/gems/<gem>-<ver>`, `GOOD=` a gate seed) |
| `selftest.txt` with its `PASS:` line | harness | campaign (refuses without it; flags it stale if a harness is newer) |
| `corpus-final/`, `crashers/`, `hangs/` | corpus | campaign (`corpus-final/` is the default seed set), triage (`crashers/` and `hangs/` are screened against every variant) |
| `campaigns/manifest.tsv` | campaign | triage (variant, harness, mode, entry, ceiling, status per campaign) |
| `triage/REPORT.md` | triage | you |

`oracle/` is an independent install of the published gem, built from source:
`gem install --install-dir oracle --platform ruby <gem> -v <ver>` (dependencies included: the
real-side scripts activate the gem from `oracle/`, and its runtime dependencies must resolve
there). `--platform ruby` matters: a precompiled platform gem (`aarch64-linux-gnu`,
`x86_64-linux`) ships someone else's build of the extension and of any vendored library.

Three conventions run through all four:

* **A harness mode is an entry point, named after it.** The harness reads `MODE=<value>` from the
  environment, never from an input byte; `real_harness.rb` keeps its calls into the gem in an
  `ENTRIES` hash keyed by that value; the campaign records each mode's `entry` as that value;
  `confirm.rb`'s `ENTRIES` is the same hash. `MODES="MODE=file"` means the same thing to
  `gate.sh`, `smoke.sh`, `campaign.sh` and `triage_all.sh`.
* **One allocation ceiling, `ALLOC_CAP_MB` (1024).** The gate, the campaign (`-m` or
  `max_allocation_size_mb`), the corpus skill's crasher pass and the triage ladder's first rung
  all use it, so a declared-size bug found in one step reproduces in the next.
* **`err=` is one token**, the library's own error name or code, identical on both sides of the
  gate; the corpus skill's histograms and error inventory steer by it. On the Ruby side it is
  the code or name the gem exposes, else the exception class.

`real_harness.rb` and `confirm.rb` need Ruby 3.0 or newer (endless methods; the targets are
3.x anyway). Developed and tested on Ruby 3.3.8.

The Ruby side runs sanitized extensions with the ASAN runtime preloaded into `ruby`
(`LD_PRELOAD=$(find_asan_rt.sh)`) and `ASAN_OPTIONS=detect_leaks=0`: the interpreter does not free
everything at exit, so leak reports from it are noise. `real_harness.rb` and `confirm.rb` also
re-exec themselves with `use_sigaltstack=0` when ASAN is loaded: without it every Ruby thread
exit dies in ASAN's "CHECK failed ... unable to unmmap" (measured, Ruby 3.3 / clang 21 / aarch64).
