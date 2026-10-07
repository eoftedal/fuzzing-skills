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
