# The smoke run: why it exists and how to read it

Read this when step 6 of SKILL.md points here or `smoke.sh` fails. The crash classes and
what to do about each are in `smoke.sh`'s header; this file is the rest.

## Why a smoke run, when the gate passed

The gate compares the harness with the real stack on the gate corpus, which is mostly
valid input, so it never reaches the error paths where a harness is most likely wrong.
Case: on an image-decoding binding the harness `memset` a C++ object to zero; every
decode **error** crashed inside `std::string` (43 phantom SIGSEGVs in 15 seconds of
fuzzing) while valid inputs worked perfectly, which is why it survived the gate. A short
run finds that in seconds; finding it after a campaign, in a pile of crashes, costs the
whole campaign.

## What it runs

It runs every seed through every sanitized fork harness, fuzzes each variant briefly (it
drives `campaign.sh` into `smoke/` with `SELFTEST=skip`, because it judges the harness,
not the detection, so the afl-fuzz setup is the campaign skill's, not repeated here), and
classifies each crash it saves. `MODES=` is the same list you gave the gate: one short
campaign per variant per mode, each recorded with its `mode_env` in the manifest, and
every seed and crash replayed under that mode on both sides.

It runs `HOSTSAN` once on a seed first and stops (exit 2) if it prints no result line: a
broken real-side command would otherwise make every crash `DIRECT-ONLY`. With `HOSTSAN`,
every crash is tried on the **real stack first**, because the harness carries copies of
package method bodies and `static inline` helpers (`boundary-shapes.md`) and a frame in
`harness.cc` can be a real bug in that copied code.

**One crash per site.** The real-stack replay starts node with the sanitized addon and
symbolizes its report, seconds per crash, so a short smoke that saves a hundred crashes
of three bugs would spend most of its time there (one evaluation run: 23 s of fuzzing,
then over seven minutes replaying 17 crashes of one site; another, 25 minutes for 112
crashes of 3 sites). `smoke.sh` groups the saved crashes by site first and replays one
per site, so its runtime grows with the number of distinct sites, not crashes. That is
still minutes when the harness or the library crashes easily, so run it detached
(`> smoke.log 2>&1 &`) or with a generous tool timeout and read `smoke.log` when it
exits; a foreground `| tee` in a tool call with a two-minute limit gets backgrounded or
cut off.

A crash classed `REAL` (it crashes the real stack too) or `PERSISTENT-ONLY` (it
reproduces single-shot on the persistent binary but not on the fork one) has one
representative per site copied into the workspace's `crashers/` as
`smoke-<variant>[@<mode>]-<name>`, with a `smoke <class> <site>` row in
`crashers.summary.tsv`, the directory the corpus skill's seed policy fills. Triage screens `crashers/` (it skips `smoke/` itself), so nothing is
copied by hand.

## Hangs

A hang does not fail the smoke, but it is not silent either: the summary line reports
`hangs=N` per variant and mode, and one hang per (variant, mode) is filed into the
workspace's `hangs/` as `smoke-<variant>[@<mode>]-<name>`, which triage screens against
every variant. Only a hang that still runs on replay is filed: `smoke.sh` replays the
smallest of each group for `HANG_S` seconds (default 5), and one that finishes sooner
was only slow under AFL's millisecond timeout (often an ASAN build of a decoder's
inner loop). It is listed in the summary (`only slow on replay`, `not handed on`), not
filed, so `hangs=3` with nothing new in `hangs/` is expected, not a lost hang; the
campaign's own hangs reach triage anyway. A hang that sits in mirrored dispatch on purpose (a JS state machine
with an unhandled state, `boundary-shapes.md`) is a finding of the package's JavaScript
layer; one in your own harness code (a reset that never terminates) is a harness bug to
fix before the self-test.

## Exit codes and warnings

Exit 1 on `HARNESS-FRAME` or `DIRECT-ONLY`. Exit 2 when the smoke test itself did not
happen: no campaign `completed` or `walled`, any campaign `aborted` or `failed`, a variant
with no finished run, or a broken `HOSTSAN`. It also warns on execs/s below 100 (measured
over the time afl-fuzz actually ran; a harness that initialises on every call) and on
stability below 90 %.

## Why the real side runs the same sanitizer

Without `HOSTSAN` a crash can only be called `UNVERIFIED`. The comparison is the reason:
"crashes only in your harness, so your harness is wrong" is **false** under a sanitizer,
because a 1-byte over-read is invisible to a non-sanitized host, so the real side must
run the same sanitizer. A variant built without the sanitizer has no stack of its own;
its crashes are re-run on a sanitized variant to get one.

## Low stability

Three known causes. A harness that mirrors a **context shared across calls** (a streaming
compression binding's one decoder context, reset per call) carries state between
iterations by design and wants the fork driver. A library that seeds its hash tables from
the **clock or pid** (an XML parser's `gettimeofday ^ getpid` hash salt) jitters a few
edges per run, which is the noise floor the corpus skill measures. A library-wide
**cache that grows across iterations** (an interned-name table, a compiled-pattern or
type cache filled on first use) makes an input's first run take paths its later runs
skip; that typically leaves stability in the low 90s and is benign. The campaign skill
switches drivers on stability by itself, so its fork fallback handles all three.
