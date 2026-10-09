# A harness with several entry points

SKILL.md's "A harness with several entry points" paragraph states the rule; this is how
each script handles `MODE=` settings (from the harness skill), so a mode-dependent
corpus is measured, minimised and covered over every mode, not just the default.

* **`measure.sh` runs in one environment.** `sweep.sh SWEEP='MODE=... MODE=...'` is how
  you measure every mode. The current environment is always included, so do not list it
  in `SWEEP`.
* **Directory names.** `sweep.sh` names the per-mode directories `maps_<base>_default`
  and `maps_<base>_MODE_compress` (`=` becomes `_`), and also writes the per-seed union,
  `maps_<base>_union/`. Each per-setting directory holds its own `.results`, so after a
  sweep `validate.sh RESULTS=` reads `maps_<base>_default/.results` (or a mode's), not
  `maps_<base>/.results`, which only a plain `measure.sh BASE=<base>` writes.
* **`compare.sh` takes the unions.**
* **`minimise.sh MODES=`** keeps a candidate that adds an edge in **any** mode, and
  `HAVE=` takes every per-mode map directory (it refuses one that does not exist).
* **`cover.sh MAPS=`** takes several directories and unions each seed's maps, so the
  cover is not biased to the default mode.
* **The seed policy and the final gate loop over modes** (SKILL.md step 7).
* **Report per-mode edges and the union.**
* **One directory, one campaign per mode.** A setting is not a seed byte, so a
  mode-dependent corpus is still one directory: the campaign skill runs one campaign per
  mode (`campaign.sh MODES=`) over the same `corpus-final/`.
