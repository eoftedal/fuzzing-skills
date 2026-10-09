# The smoke test: what it runs, and how to read what it says

Read this when SKILL.md step 6 points here, or when `smoke.sh` exits non-zero. The classes
and the exit codes are in `resources/smoke.sh`'s header; this is the rest.

## Why it exists

The gate runs the gate corpus, which is mostly valid input, so it never reaches the error
paths where a harness is most likely wrong. On the Node sibling, a harness that `memset` a
C++ object to zero crashed inside `std::string` on every decode **error** (43 phantom
SIGSEGVs in 15 seconds of fuzzing) while valid inputs worked perfectly, which is why it
survived the gate. A short run finds that in seconds; finding it after a campaign costs
the whole campaign.

## What it runs

It runs every seed through every sanitized fork harness, fuzzes each variant briefly (it
drives `campaign.sh` into `smoke/` with `SELFTEST=skip`, so the afl-fuzz setup is the
campaign skill's, and it judges the harness, not the detection), and classifies each
crash it saves. `MODES=` is the same list you gave the gate. It runs `HOSTSAN` once on a
seed first and stops (exit 2) if it prints no result line, since a broken real-side
command would otherwise make every crash `DIRECT-ONLY`.
Through `campaign.sh` it also takes the campaign's dictionary default (`$W/dict.afl`,
else `out/<variant>/dict.afl`), so a smoke after the corpus skill
mutates with the same tokens as the campaign.

* **With `HOSTSAN`, every crash is tried on the real stack first**, because the harness
  may carry copies of extension method bodies and `static inline` helpers
  (`boundary-shapes.md`), and a frame in `harness.cc` can be a real bug in that copied
  code.
* **One crash per site.** It replays one saved crash per crash site on the real stack, not
  every crash, and hands over one representative per site; each replay starts ruby with a
  sanitized extension and costs seconds, so the smoke as a whole can take minutes: run it
  detached or give the tool call a generous timeout.
* **`STRING_API=1`** when the API takes a validated or NUL-terminated String
  (`StringValueCStr`, a `valid_encoding?` check): crashes on input it cannot carry are
  then `OUT-OF-SCOPE`.

## Reading the verdict

It exits 1 on `HARNESS-FRAME` (innermost project frame in the harness's own code) or
`DIRECT-ONLY` (crashes the harness, not the real stack, on input the API can express),
and 2 when the smoke itself did not happen (no campaign `completed` or `walled`, one
`aborted` or `failed`, a variant not smoked, a broken `HOSTSAN`). It warns on execs/s
below 100 and stability below 90 %. A `PASS` means the harness is not obviously wrong; it
does not mean it is right: the gate and the self-test do that.

* **A `DIRECT-ONLY` can be the String ceiling**, not a harness bug: `oracle-ceiling.md`,
  section 2, says how to tell.
* **Without `HOSTSAN` a crash can only be called `UNVERIFIED`**, so give it: "crashes only
  in your harness, so your harness is wrong" is **false** under a sanitizer unless the
  real side runs the same sanitizer.
* **On the real side a wild segfault** prints Ruby's own `[BUG] Segmentation fault at
  0x...` and aborts rather than an ASAN report; ASAN's own checks still report normally.
* **Over a system library rebuilt as a static archive** (SKILL.md step 3b), the real side
  loads the uninstrumented system `.so`, so an overflow inside the library can read
  `DIRECT-ONLY` though it is real: read the frame (`oracle-ceiling.md`, "Over a system
  library the sanitized real side is blind inside it").

## Where its crashes go

A crash classed `REAL` or `PERSISTENT-ONLY` is copied into the workspace's `crashers/`
with a row in `crashers.summary.tsv`, where the triage skill picks it up (it triages
`crashers/` even when no campaign saved a crash). Nothing to copy by hand; the `smoke/`
tree itself is not triaged.

## Low stability

Two known causes (both from the Node sibling): a harness that mirrors a **context shared
across calls** carries state between iterations by design and wants the fork driver, and a
library that seeds its hash tables from the **clock or pid** (a parser's
`gettimeofday ^ getpid` hash salt) jitters a few edges per run. A third, seen on a Ruby
evaluation run: a library's **caches** (a name or string-interning cache that grows across
persistent iterations) gave stability in the low 90s; benign, since the cache changes only
which branch finds an entry. The campaign skill switches drivers on stability by itself
(the fork fallback), so none of these needs a harness change unless the gate disagrees.
