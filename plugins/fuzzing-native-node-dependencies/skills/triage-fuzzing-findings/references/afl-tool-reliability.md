# Steering the AFL tools

Read this if `triage/min/` looks wrong, if afl-tmin seems to do nothing, or before
believing a minimized reproducer. The rule behind every choice here: **the skill steers the
tools — how they are fed, how strict they are, what counts as success — and never
reimplements them.** Everything below was measured on AFL++ 4.33c, aarch64, container
kernel 6.12, Python 3.14.

## afl-tmin: feed it through `/dev/stdin`

Symptom: afl-tmin's dry run reports `Program terminates normally` for an input that
crashes when run directly, minimizes to **0 bytes**, and **exits 0**. It looks like broken
crash detection. It is not: it is input delivery. A debug harness that prints what it
reads shows the cause:

```
direct:            [child] argc=2 argv1=in n=4 b0=C          -> SIGSEGV
under afl-tmin @@: [child] argc=2 argv1=./.afl-tmin-temp-6589 n=0 b0=.
```

afl-tmin's temp file reaches the harness **empty** — with `@@` and with an explicit `-f`
alike — so every candidate "terminates normally". afl-fuzz (`.cur_input`) and afl-showmap
deliver the same bytes to the same binaries correctly, and the forkserver does not use
shared-memory testcases (`Forkserver options received: (0x00000001)`), so this is afl-tmin's
file delivery. There is no environment switch for it.

The steering: **pass `/dev/stdin` as the harness's file argument** instead of `@@`. afl-tmin
then feeds stdin, the harness opens `/dev/stdin` as its input path, and the bytes arrive
intact. Measured: `[child] argv1=/dev/stdin n=4 b0=C`, crash mode, `Cxyz` minimized to `C`.
On real harnesses: a block-compression binding 7 → 5 B, an image-decoding binding's BMP
input 170 → 57 B, a stylesheet-compiler binding's stack exhaustion 170 → 44 B, each still producing its original sanitizer report.

This requires a harness that **reads** its input file. One that `stat()`s it for a size or
`mmap()`s it cannot take a pipe; `minimize.sh` checks each input through `/dev/stdin` first
and keeps the original bytes if the harness cannot.

## AFL_TMIN_EXACT is the retry, not the default

`AFL_TMIN_EXACT=1` makes afl-tmin keep only candidates that crash on the **identical
execution path**. As a default it is too strict: on an image-decoding binding's GIF input it rejected 97 of 112
candidates as `path` fruitless and reduced nothing. Without it, afl-tmin accepts any crash,
and can wander to a different bug: a stylesheet-compiler binding's over-read in one function
minimized into one in an unchecked UTF-8 decoder.

So `minimize.sh` lets afl-tmin minimize freely, compares the result's sanitizer key (kind +
function, not line) with the original's, and only on drift re-runs with `AFL_TMIN_EXACT=1`.
On the stylesheet-compiler binding's 6 representatives: 5 minimized freely, 1 drifted and was recovered by the
EXACT retry, 0 kept as original — 7 seconds for all six.

## afl-tmin's exit code means nothing

Even steered correctly, the result is checked rather than trusted: it must be non-empty,
reproduce, and keep its key (for hangs: still time out at the full timeout). If no attempt
verifies, the original bytes are kept and `tmin.log` says why. There is no homemade
fallback minimizer: an earlier version of this skill had one (`shrink.sh`), written while
the input-delivery cause was still misdiagnosed as broken crash detection. Once afl-tmin
could be fed correctly it was redundant.

## Hangs: afl-tmin -H with a short -t

In hang mode afl-tmin keeps candidates that time out, so every candidate that still hangs
costs the whole `-t`. `minimize.sh` runs `afl-tmin -H -t <HANG_S*1000>` (default 2 s) and
re-checks the result at the full timeout, so an input that merely runs slowly is caught.
For scale: shrinking one real 252-byte hang in a stylesheet-compiler binding took 1,458 s at a 10 s threshold and
238 s at 2 s, to the same 119 bytes.

## afl-cmin is not used, and the Python one hangs

`afl-cmin` ships twice. The Python rewrite dies in a forkserver worker
(`TypeError: array() argument 1 must be a unicode character, not None` — a module global
set only in the parent; Python 3.14 defaults multiprocessing to forkserver) and the parent
then waits forever at 0 % CPU. `afl-cmin.bash` works: `-C` on a 38-crash pool from an image-decoding binding kept
15, all of which crash.

The pipeline no longer runs either, because bucketing does the collapsing better and earlier:
on a stylesheet-compiler binding, `afl-cmin.bash -C` kept 106 of 124 crashes, while bucketing the 111 raw ASAN
crashes on the sanitizer key gave exactly the 4 published bugs. Minimizing one
representative per bucket replaces "cmin, then minimize every survivor".

## ASAN_OPTIONS per phase

afl-tmin requires `abort_on_error=1:symbolize=0` (a memory error must abort with a signal
it can see). Bucketing needs `symbolize=1` to read the SUMMARY line. `bucket.sh` and
`confirm.sh` **force** the options they depend on (appended last; ASAN takes the last
occurrence): running steps in one shell used to leave `symbolize=0` behind and every bucket
key degraded to `heap-buffer-overflow (harness-fork+0x152744) (BuildId: ...)`. The
allocation ceiling and `allocator_may_return_null=1` are forced too, per input, from
`cap.tsv` — the key must describe the crash as screened.
