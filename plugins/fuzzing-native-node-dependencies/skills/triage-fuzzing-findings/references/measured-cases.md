# Measured cases behind the triage rules

What happened on earlier targets, one bullet per rule in `SKILL.md`. These are other runs'
results, not expected outcomes: a different count, timing or verdict on your target is not a
sign that your triage went wrong.

## Entry points and modes

* **Confirm every entry point.** A stylesheet-compiler binding has a string entry point and
  a file-path entry point, and 25 of its 111 confirmed crashes were reachable only through
  the file-path one: the string entry point replaces invalid UTF-8 with U+FFFD before the
  library sees a byte. One entry point reports those 25 as artifacts.
* **A harness mode is an entry point too.** The two bugs found under harness `MODE=2` in the
  image-decoding binding's next major version (a zig build) read CLEAN through its
  promise-based loader and segfault the npm install through an arm that sets the image
  object's MIME data mode, which is what `MODE=2` sets.
* **A crash found in one mode does not reproduce in another.** Those two crashers are
  `rc=0` by default and `rc=134` under `MODE=2`: a heap over-read in the EXIF-orientation
  rotation and a 67 MB `memcpy` over-read. A mode-blind screen filed both as
  non-reproducing.

## Pipeline cost and order

* **Bucket before minimize.** On a stylesheet-compiler binding with 111 crashes: screen
  14 s; bucket 27 s, giving 4 bugs; confirm about 0.1 s per cell; minimize 7 s for 6
  representatives.
* On an image-decoding binding the whole pipeline including both confirmations took 61 s;
  the earlier "cmin, then minimize every survivor" design ran past 20 minutes.
* **Confirm the original bytes first.** The image-decoding binding's GIF bug reads CLEAN on
  the npm install once minimized and crashes it only as the original. The automatic
  re-test of pre-tmin bytes recovered that critical finding.

## Which build reproduces what, over 161 crashes

| campaign | both builds | ASAN only | plain only | neither |
|---|---|---|---|---|
| stylesheet-compiler binding, plain (13) | 13 | 0 | 0 | 0 |
| stylesheet-compiler binding, ASAN (111) | 0 | 111 | 0 | 0 |
| image-decoding binding, plain (37) | 25 | 2 | 0 | 10 |

Not one input crashed the plain build alone. The image-decoding binding's two ASAN-only
crashes came from the plain campaign. The 10 that reproduce nowhere are fork-mode
non-reproducers.

## Allocation ceiling

* An earlier ladder stopped at the first rung that reproduced anything, and a 600 MB
  declared-size input sharing a pool with heap over-reads was silently dropped.
* An amplification line as printed:

  ```
  0008-...-id_000008_sig_09_src: 5 B in -> 3758096257 B demanded  (751619251x amplification)
  => RESOURCE EXHAUSTION / DoS
  ```

## Minimization and buckets

* **Do not hand-minimize further.** A stylesheet-compiler binding's stack-exhaustion
  reproducer resisted manual reduction: deep nesting is guarded, and the real mechanism is
  unbounded recursion during evaluation, past the guard.
* **Merge on function.** That binding's 25-crash over-read in an unchecked UTF-8 decoder is
  reported at three lines of one header (`:76`, `:82`, `:84`). Exact SUMMARY key: 6 buckets;
  merged: 4, the published answer.
* **Hang buckets are approximate.** A loop inside a stylesheet compiler's evaluate/expand
  passes landed in a coarser bucket on another run.

## Confirm cells

* **`ADDON-NOT-SWAPPED`.** A stylesheet-compiler binding honours the package's own
  environment variable for its binary path, so a hook on `'bindings'` never fired; the
  `process.dlopen` hook does.
* **All-CLEAN column.** An image-decoding binding's first JS harness "confirmed" success
  for 18 files that had all failed, because the image object's `complete` getter it checked
  is hardcoded `return true`.
