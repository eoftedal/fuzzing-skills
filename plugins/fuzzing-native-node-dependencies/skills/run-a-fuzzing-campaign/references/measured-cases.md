# Measured cases behind the campaign rules

What happened on earlier targets, one bullet per rule in `SKILL.md`. These are other runs'
figures, not expected outcomes: a different count, map size or run time on your target is
not a sign that something went wrong.

* **Manifest `variant` + `harness`.** `campaign/asan2/` had no `out/asan2/`; the largest
  crash set was skipped.
* **Manifest `mode_env` + `entry`.** An image-decoding binding's `MODE=2` bugs filed "does
  not reproduce" until the mode was named by hand.
* **Manifest `alloc_cap_mb`.** A block-compression binding's 17 crashes reproduced 0 of 10
  at the wrong ceiling.
* **Manifest `crash_files`.** 112 saved vs 64 files on disk, silently.
* **Manifest `seeds_loaded` / `seeds_total`.** `AFL_IGNORE_SEED_PROBLEMS` silently dropped
  one of 455 seeds.
* **`DURATION` is fuzz time.** A campaign on the image-decoding binding's next major version
  (a zig build) with `-V 40` ran 268 s once it had saved a hang.
* **`AFL_MAP_SIZE` per binary.** Persistent and fork differ: 197449 vs 197424 on a
  stylesheet-compiler binding.
* **Hand-off to triage.** Validated on a stylesheet-compiler binding: `asan` plus `asan`
  under a harness mode variable selecting its file-path entry point (here an interrupted
  run) handed straight to triage, which screened each against its own build and mode and
  bucketed both.
