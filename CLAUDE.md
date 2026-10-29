# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Claude Code plugin marketplace (`.claude-plugin/marketplace.json`) with two sibling plugins:
- `fuzzing-native-node-dependencies`: the native libraries behind NAN/N-API Node addons.
- `fuzzing-native-ruby-dependencies`: the C libraries behind Ruby gems' C extensions (mkmf / `extconf.rb`), validated on three gems of different shapes (system library, vendored libraries, parser in the extension) (see each skill's `EVIDENCE.md`).

It is not an application: there is no build, lint, or test suite. Both plugins are skills (Markdown instructions plus shell/C/Python helper scripts, Node `.mjs` or Ruby `.rb` for the real-stack side) for AFL++ fuzzing. When adding a plugin or bumping a version, keep `marketplace.json` and the plugin's `.claude-plugin/plugin.json` in sync.

Scope rule: the skills find vulnerabilities and stop at a classified, minimized reproducer for the maintainer. They do not develop exploits; don't add exploit-development content.

## Skill layout

Each skill under `plugins/<plugin>/skills/<name>/` has:
- `SKILL.md`: the instructions loaded by Claude (frontmatter `name` and `description`; the description drives triggering).
- `EVIDENCE.md`: not loaded with the skill. The measurements and review corrections behind each rule, tagged **[measured]**, **[tool]**, or **[carried]**. Update it when a rule changes, and don't state something as validated in `SKILL.md` without evidence here.
- `references/`: longer explanations, loaded on demand.
- `resources/`: runnable scripts and templates the skill invokes, run from the user's fuzz workspace rather than from this repo.

## The four-skill chain

Order: harness (`build-a-nan-napi-fuzzing-harness` / `build-a-ruby-c-extension-fuzzing-harness`) → `derive-a-fuzzing-corpus-from-source` → `run-a-fuzzing-campaign` → `triage-fuzzing-findings`.

The skills communicate through files in the fuzz workspace, so names must stay identical across all four. Each plugin's `skills/README.md` artifact table is the contract: `out/<variant>/{harness,harness-fork,map_size}`, `corpus/`, `corpus-final/`, `crashers/`, `hangs/`, the real-stack harness (`real_harness.mjs` / `real_harness.rb`), `oracle/`, `selftest.txt` (with a `PASS:` line), `campaigns/manifest.tsv`, `triage/REPORT.md`, and the AFL dictionaries `out/<variant>/dict.afl` (written by the builds via `AFL_LLVM_DICT2FILE`) and `$W/dict.afl` (the corpus skill's `dict.sh` merge, which `campaign.sh` passes as `-x` and records in the manifest's `dict` column), `out/<variant>/lib/` (an instrumented static archive of a system library plus its headers, from the harness skill's `build_lib.sh`), and the manifest's trailing `instances` column (`campaign.sh SECONDARIES=` runs `-M`/`-S` instances under one `-o`, so triage globs `*/crashes`). Renaming or changing the format of one in a skill means updating every skill that reads it.

Shared conventions (changing one touches several skills' scripts):
- **Harness mode = entry point, named after it.** The harness reads `MODE=<value>` from the environment, never from an input byte. The real harness and triage's confirm script share one `ENTRIES` object/hash keyed by that value, and the campaign manifest's `entry` column is that value. `MODES="MODE=file"` means the same thing to `gate.sh`, `smoke.sh`, `campaign.sh` and `triage_all.sh`.
- **One allocation ceiling, `ALLOC_CAP_MB` (default 1024)**, used by the gate, campaign (`-m` / `max_allocation_size_mb`), corpus crasher pass and triage's first rung, so a bug found in one step reproduces in the next.
- **`err=` is a single token** (the library's own error name or code), identical on both sides of the gate; corpus histograms and the error inventory key on it.
- **`fuzz.env` in the workspace** is written by the harness skill's `init_workspace.sh` (re-run with only the new keys as they become known) and sourced by every command block (`cd $W && . ./fuzz.env`), since a model's shell does not persist between tool calls. Keys: `SKILLS R RC W PKG_NAME PKG PKG_VERSION ADDON_ASAN ADDON_MATCH MODES FIELDS SOFT_FIELD SOFT_DROP ALLOC_CAP_MB REAL REAL_ASAN` (`ADDON_MATCH` narrows the real-stack addon swap when a package builds several addons; the Ruby plugin has `EXT_ASAN` in place of the two `ADDON_*` keys). Scripts read it as defaults; an explicit argument always wins.

## The two plugins share code by copy

The Ruby plugin carries its own copies of the generic AFL++ scripts (`gate.sh`, `smoke.sh`, `campaign.sh`, the corpus scripts, `screen.sh`/`bucket.sh`/`minimize.sh`, ...), so each plugin installs on its own. When you fix one of these in one plugin, make the same fix in the other, then run `scripts/check_shared.sh`. It ignores comment lines, and passes intended code differences listed in `scripts/shared-allow.txt`. Use `-v` to see the diffs, and `--accept` only after reviewing that every remaining difference is intended.

The ecosystem-specific parts are the build (node-gyp vs mkmf), stub generation (napi/V8 vs libruby exports, including data symbols), the real-stack and confirm scripts (`.mjs` vs `.rb`), and the triage verdict semantics.

## Editing notes

- Scripts have no repo-local test runner. Validate changes by running them in a real fuzz workspace, and record what you observed in the skill's `EVIDENCE.md`. Anything learned on Node and reused in the Ruby plugin is **[carried]**, never [measured], until it has been run on a Ruby gem.
- Command examples in `SKILL.md` and `references/` use `$R/` (harness skill) and `$RC/` (corpus skill) from `fuzz.env`, never a bare `resources/` path, which would resolve against the workspace rather than the skill.
- Fuzzing runs in the `sectainer` Docker image (AFL++ 4.33c, clang 21, aarch64 Linux, Ruby 3.3), built from `~/research/sectainer`. That is the platform the EVIDENCE files record.
- `EVIDENCE.md` files carry "review corrections" tables of past mistakes that are easy to reintroduce (for example, killing a wrapper subshell's pid instead of `afl-fuzz`, or recording a campaign as `completed` when it aborted). Read the relevant one before changing a script's control flow.
