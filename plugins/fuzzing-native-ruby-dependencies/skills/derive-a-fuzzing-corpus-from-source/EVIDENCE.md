# Evidence behind the rules in SKILL.md

Not loaded with the skill. Tags: **[measured]** observed in a run listed here; **[tool]**
the installed tool's own output; **[carried]** learned on the Node sibling plugin and not
re-measured on Ruby. Platform: the `sectainer` image (Ubuntu 26.04 aarch64, Ruby 3.3.8,
clang 21, AFL++ 4.33c), 2026-10-06.

The method and almost every number in SKILL.md and `references/` are **[carried]**: the
corpus scripts are byte-identical in code to the Node plugin's (`scripts/check_shared.sh`),
they only see a harness binary and the key=value line, and the libraries the Node numbers
were measured on are C libraries. `references/measured-examples.md` says so at the top.

Targets (as in the harness EVIDENCE): A, a gem over a system library; B, a gem with vendored
libraries (mini_portile2); C, a gem whose parser is the extension's own C.

## Ruby runs

**Target C, one evaluation run (Sonnet), skill followed as written** [measured, eval run]:

| quantity | value |
|---|---|
| gate seeds (baseline) | 22 hand-made, 550 edges |
| derived seeds | 195 literal seeds from the parser source, 8 families |
| derived alone | 770 edges |
| `corpus-final` (union) | 213 seeds, 781 edges (784 on a second measure) |
| greedy cover (`corpus-min`) | 86 of 213 |
| unique maps | 185 of 213 |
| A-only edges (held by the hand-made set) | 11 |
| `err=` distribution | 128 seeds status 0, 67 status 1, ~19 distinct tokens |
| crashers / hangs during the corpus pass | 0 / 0 |
| machine time for generate + measure + compare + union + re-gate | ~25 s |

* **Re-gate the final corpus, always.** The 22-seed gate passed; the 213-seed re-gate found
  2 mismatches, both harness fidelity gaps the small corpus never exercised: an unknown
  encoding name (Ruby's `rb_enc_find` returns ASCII-8BIT, the shim returned NULL) and a
  non-ASCII name the extension turns into a Symbol (Ruby's `rb_intern` raises
  EncodingError). Fixed in the harness; re-gate 213/213. This is the rule in SKILL.md's
  step on re-gating, measured on Ruby for the first time.
* The scripts ran verbatim once `MAP_SIZE` was set (`measure.sh`, `compare.sh`,
  `cover.sh`, `minimise.sh`, `validate.sh`).

**Tooling checks** [measured]:
* `extract_literals.py LANG=rb` on target A's real `lib/**/*.rb`: 176 literals. The c and js
  modes still work.
* `gen_template.rb` (the port of `gen_template.mjs`) wrote byte-identical seeds and
  manifest to the `.mjs` on the same inputs, and runs warning-free under `ruby -w` 3.3.

**Target B, one evaluation run (Sonnet), 10-min campaign** [measured, eval run]:
gate seeds 39 -> 2754 edges; 422 derived seeds in 11 families -> 4157 edges (1422 only in
derived, 19 only in the gate set); 142 of 1392 fixtures from the main vendored library's
`test/` dir kept by `minimise.sh`; `corpus-final` 597 seeds, ~4850 edges; cover 248.
**One seed was nondeterministic** (several entries of one kind serialised in the
library's hash-seed order, six orderings in six runs, on both arms) -- the reason for `nondet.sh`,
which flags it (6 distinct results in 8 runs) and passes a stable seed [measured].

**Target C, second evaluation run (Sonnet), two modes** [measured, eval run]: 34 gate
seeds -> 467 edges (union of modes); 291 derived + 59 sweep keepers; `corpus-final` 376,
756 edges; the corpus re-gate found the gcc/clang `__LINE__` difference (harness EVIDENCE).

## Not yet measured on Ruby

The per-axis gains in `references/axes.md`, the cost and sweep rules, and the
"cover is a stop signal" rule are **[carried]**. Two Ruby targets are not enough to restate
them; the numbers above are consistent with them (derived seeds +40 to +51 % edges over
the hand-made set, which still held 11-19 edges the derived set missed).

## Shared-script changes mirrored from the Node review (2026-10-07)

Made identically in both plugins (`scripts/check_shared.sh`: 0 drift). Checked on a
small instrumented harness and fabricated inputs in the `sectainer` image, not on a gem.

| change | tag | evidence |
|---|---|---|
| `sweep.sh` and `nondet.sh` drop the gate's per-mode options after a colon (`MODE=x:min_arms=1`) | [measured, synthetic] | before, `MODE` carried the suffix and the default entry point was measured under the mode's name |
| `measure.sh` and `validate.sh` take the first line holding `status=` as the result line | [measured, synthetic] | library output on stdout before the result line no longer hides it; same rule as `gate.sh` |
| `error_inventory.sh` matches whole `err=` values | [measured, synthetic] | `ERROR` no longer counts every `err=*ERROR*` token as reached |
| `cost.sh SLOW_MS` lists seeds the campaign's dry run would drop silently | [carried] | from the Node review |
| step 7 snippet: `MODES` branch for a harness without modes, `crashers.summary.tsv` truncated per run with `TIMEOUT=` and a row for plain crashers; `gen_template.rb ONLY=` writes a per-family manifest; nondet paragraph says to re-measure after moving seeds | [carried] | the same snippet and template bugs as the Node copy |

## Trim (2026-10-07): under the 30 KB terminal truncation

| change | tag | evidence |
|---|---|---|
| SKILL.md 35.4 -> 28.6 KB. Moved, each behind a pointer from the step it left: fixture hunting to the new `borrowing.md`; the error-inventory routes and classes to the new `error-inventory.md`; step 3's explanations to the new `entry-point.md`; the bug-pattern table to the new `bug-patterns.md`; the generator, writer, transplant and external-reference explanations to the new `authoring.md`; the re-gate rationale points at the harness skill's `oracle-ceiling.md` | [tool] | the axis table, the step 7 snippet, the nondet step and the stop rules are unchanged; the "(measured)" markers stayed on their sentences; every reference file is pointed at from SKILL.md (7 files, 10 pointers, no dangling path); no em-dash outside the headings |

## Chain review mirrored from the Node plugin (2026-10-08)

| change | tag | evidence |
|---|---|---|
| command blocks source `fuzz.env`; `sweep.sh`/`nondet.sh` default to its `MODES`; `measure.sh` fails on no maps and no longer always exits 1; `compare.sh` fails on a missing directory | [measured, synthetic] | identical copies of the Node scripts, exercised on a tiny harness in the `sectainer` image |

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

## AFL dictionaries (2026-10-08)

| change | tag | evidence |
|---|---|---|
| new `dict.sh`: merges the build dictionaries with author-supplied tokens (`TOKENS`, `TOKENS_FILE` with `\\xNN` escapes) and regex-harvested literals from sources afl-clang-fast never compiled (`strcmp`/`memcmp`/`case` arms, integer constants in both byte orders), AFL syntax with `\\xNN`, `\\"` and `\\\\` escapes, entries over 128 decoded bytes dropped (afl-fuzz aborts on them), refuses an empty result | **[measured]** on a fabricated extension in the `sectainer-ruby` container, not on a published gem | 25 entries from two build files, TOKENS, a TOKENS_FILE and three source files; escaping checked with `cat -v`; afl-fuzz loaded all 25 ("Loaded 25 extra tokens"); a missing path exits 2, an empty result exits 1 |

## Round 3 fixes mirrored from the Node plugin (2026-10-09)

The shared scripts changed identically in both plugins (`check_shared.sh`: 0 drift). The
rows, with what was observed, are in the Node plugin's corpus EVIDENCE.md under "Round 3
fixes (2026-10-09)"; they were run in the `sectainer-ruby` container on a Node workspace,
so on this plugin they are **[carried]**:

| change | tag |
|---|---|
| `dict.sh`: `FROM` defaults to every `out/*/dict.afl` (printed), `FROM=none` opts out; `TOKENS` literal with a NOTE on escapes; `TOKENS_FILE` takes AFL-syntax lines; `MODES` values and `default` dropped (`DROP=`); `SRC=` also harvests named hex constants (C `#define`, Ruby `X = 0x...`, JS `exports.X =`) in both byte orders, capped by `NAMED_MAX`; runs `python3 -I` | **[carried]** (the Ruby copy of `dict.sh` ran once in the container with the default `FROM` and `SRC=`, 28 entries, `afl-fuzz` loaded 28; the Ruby constant pattern only on a synthetic `.rb`) |
| `error_inventory.sh FIELD=` and the collapsed-`err` warning; `references/error-inventory.md` section on `lib_err=` | **[carried]** |
| `errenum_template.c` loops from `MIN_CODE` (-64) | **[carried]** (the Ruby copy compiled with `-Wall -Werror` and printed negative codes) |
| `gen_template.rb`: unsigned clamps warn once on a negative value (Ruby has no int32 sign flip, but a negative from a subtraction is the same bug) | **[measured, synthetic]**: `ruby -c` ok; `u32(-5)`, `u32(-6)`, `u16(-1)` printed one warning for `u32` and one for `u16` |
| step 7: save the union block as a script; file known hangs and real-only crashes by hand as `hand-*` with a summary row; the block keeps `smoke-`, `gate-`, `hand-` rows; step 2/borrowing.md: no fixtures means the writer family | **[carried]** |
| the lossy-string and `AFL_SKIP_CRASHES` notes moved from SKILL.md to `references/measured-examples.md` to stay under 30,000 bytes | [tool] |

## Round 4 fixes mirrored from the Node plugin (2026-10-09)

Measured on a Node workspace in the `sectainer-ruby` container (rows in the Node plugin's
corpus EVIDENCE.md, "Round 4 fixes (2026-10-09)"); identical script in both plugins.

| change | tag |
|---|---|
| step 7's seed policy is `resources/union_crashers.sh`: keeps every `crashers.summary.tsv` row whose file still exists in `crashers/` or `hangs/` (any name, not only `smoke-`/`gate-`/`hand-`), drops rows for missing files, replaces rows it rewrites; hand-filed inputs may take any name. The Ruby block's `ASAN_TIMEOUT` is now the script's `TIMEOUT` (default 30), and its WARN also fires on an `ERROR: AddressSanitizer` line with no `SUMMARY:` | **[carried]** |
| SKILL.md size after the move | [tool]: `wc -c` 28,922 |
