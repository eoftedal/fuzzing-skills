---
name: derive-a-fuzzing-corpus-from-source
description: Derive a high-coverage fuzzing seed corpus by reading the target's parser source instead of collecting sample files. Use when a fuzzing harness exists but has few or weak seeds, when coverage has plateaued, when a format or code path has no sample files, or when asked to improve a corpus, write seeds, or raise branch coverage.
---

# Derive a fuzzing corpus by reading the source

You have a working harness. This is about what to feed it.

**Budget: about fifteen minutes, and it does not have to be perfect.** The deliverable is
a corpus that beats the baseline, passes the gate, and names what it does not cover; the
campaign's mutations do the rest. The runs that took an hour spent it waiting: measuring
thousands of unminimised fixtures, re-gating every seed in every mode on every variant,
and running the crasher pass per mode. The rules below say what to skip; when you pass
the budget, go to step 7, ship the union, and list the families you did not write.

**The goal is branches, not valid files.** A seed does not have to be a valid image,
archive, stylesheet or packet. It has to get *past the fields that gate the code you want
to reach*. A 90 %-garbage input that clears the first four validated fields is worth more
than a pristine sample that duplicates coverage. A seed that dies on field one reaches
nothing.

Reading beats collecting samples at every rejection path, boundary, unsupported-but-
recognised value, truncation, and any variant nobody committed a sample of. It loses at
code that only runs once the input was accepted (step 8).

**Prerequisites.** A harness that takes one input file as `argv[1]`, exits non-zero on
rejection, and prints a one-line `key=value` result including the library's **own error
code or name** in a field (the companion skill `build-a-nan-napi-fuzzing-harness` prints
it as `err=`); `afl-showmap`. `resources/` holds the scripts, every step names its own,
and all take `KEY=VALUE` arguments. `references/axes.md` is the long form of step 4;
`references/measured-examples.md` holds the magnitudes behind every rule.

**The whole path:**

```sh
# 1  resources/measure.sh BASE=baseline ...           what the existing seeds cover
# 2  borrow: a transferred corpus, the gate corpus, fixtures, extract_literals.py
# 3  read the dispatcher; one seed per sniffer at minimum match
# 4  list the axes (table below); sweep options with resources/sweep.sh
# 5  author: gen_template.mjs for records, literal files for text
# 6  resources/validate.sh per family                 seeds reach DEEP code?
# 7  resources/compare.sh, minimise.sh, cover.sh      gap, union, stop signal
# 8  the success path: the library's writer, transplants, fixture directories
# 9  resources/cost.sh                                 per-exec cost
```

## Deliverable

| path | contents |
|---|---|
| `corpus-final/` | **what the campaign fuzzes by default.** The union of the baseline, every borrowed set, the derived families and the `minimise.sh` keepers, deduplicated by content (step 7). Not just the cover. |
| `corpus-min/` | the greedy cover from `cover.sh`: a stop signal and a quick-check set, never the fuzzing default |
| `maps_final/` | `measure.sh BASE=final CORPUS=./corpus-final`, so the next person can compare against it |
| `crashers/`, `hangs/` | per the seed policy below, with `crashers.summary.tsv` beside them |
| `<set>.manifest.tsv` | beside each generated set, outside the corpus directory |

Do not overwrite `corpus/`: it is the harness skill's gate corpus.

**Seed policy.** A seed that crashes only the sanitized (ASAN) harness stays in
`corpus-final/` and is also copied to `crashers/`, with its sanitizer `SUMMARY:` line
recorded in `crashers.summary.tsv`. A seed that crashes the plain harness, or hangs
(`rc=hang` from `measure.sh`), goes only to `crashers/` (hangs may go in `hangs/`) and
never into `corpus-final/`. The campaign skill runs afl-fuzz with
`AFL_IGNORE_SEED_PROBLEMS=1`, which skips crashing and hanging seeds in the dry run
instead of aborting, so the ASAN-only crashers left in `corpus-final/` are harmless there;
`AFL_SKIP_CRASHES=1` covers crashes only and is not the setting to rely on.

Every script that runs the harness bounds each run with `TIMEOUT=` (seconds, default 5)
and reports seeds over it as `hang`. `measure.sh` and the gate take `JOBS=` (default 8);
a thousand seeds is a minute, not five.

**A harness with several entry points** (`MODE=` settings, from the harness skill) is
one corpus measured several times. The scripts handle it like this: `measure.sh` runs
in one environment, so `sweep.sh SWEEP='MODE=... MODE=...'` is how you measure every
mode (it also writes the per-seed union, `maps_<base>_union/`, and names the per-mode
directories `maps_<base>_default` and `maps_<base>_MODE_compress`: `=` becomes `_`; the
current environment is always included, so do not list it in `SWEEP`); `compare.sh`
takes the unions; `minimise.sh MODES=` keeps a candidate that adds an edge in **any**
mode and `HAVE=` takes every per-mode map directory (it refuses one that does not exist); `cover.sh MAPS=` takes several directories
and unions each seed's maps, so the cover is not biased to the default mode; the seed
policy and the final gate loop over modes (step 7). Report per-mode edges and the union.
A setting is not a seed byte, so a mode-dependent corpus is still one directory: the
campaign skill runs one campaign per mode (`campaign.sh MODES=`) over the same
`corpus-final/`.

---

## Step 1 — Measure before generating anything

Non-negotiable, and the most common way this work gets wasted. You need what the
existing seeds cover before you can know what a new corpus adds *and misses*.

```sh
resources/measure.sh BASE=baseline HARNESS=./out/plain/harness-fork CORPUS=./corpus
```

It writes per-seed maps to `maps_baseline/`, always saves each seed's exit code and
result line to `maps_baseline/.results` (which `validate.sh` and `error_inventory.sh`
reuse, so the harness is not run again; `NO_RESULTS=1` skips that pass on a slow
target), and prints edge total, unique-map count, the exit-code histogram and which seeds
duplicate another's coverage. Pass `MAP_SIZE=$(cat out/plain/map_size)` when the
harness is not instrumented the way the script guesses. It costs about two process
starts per seed: measure an unminimised borrowed set (thousands of extracted literals)
once, or send it straight to `minimise.sh`, and use `NO_RESULTS=1` for sweeps.

**Then find out which back ends are in code you instrumented**, because a family aimed
at an uninstrumented decoder costs the same to write and shows up as nothing:

```sh
nm ./out/plain/harness-fork | grep -c sancov                        # the harness itself: must be > 0
for l in $(ldd <addon>.node | awk '{print $3}' | grep -vE 'libc\.|libstdc|libgcc|libm\.|libpthread|ld-linux'); do
  printf '%-40s sancov=%s\n' "$(basename $l)" "$(nm -D $l 2>/dev/null | grep -c sancov)"
done
```

An empty list is the good case: everything is statically linked and instrumented.
Spend the family budget where the instrumentation is. When every decoder is a system
`.so` with `sancov=0` (an image-decoding binding whose image codecs are system
libraries), the productive families are the **in-tree parsers**: a hand-rolled BMP
reader, container and EXIF glue, GIF compositing. A family for an uninstrumented decoder, and the writer-driven seeds of
step 8 for it, add nothing you can measure.

Two readings of the measurement that mislead: many seeds sharing one map while all
*failing* die early; sharing one map while all *succeeding* means the work is in code you
did not instrument. Check the exit codes before concluding either.

---

## Step 2 — Borrow before deriving

Cheapest coverage available, in this order. Measure each as an A-side (step 7), then
`minimise.sh` it into the corpus rather than shipping all of it.

1. **A corpus derived for another target over the same format.** Reading a *format*
   amortises across every binding over it. The seeds must share the **input convention**
   too: a UTF-16 corpus needs re-encoding before it means anything to a UTF-8 parser.
2. **The harness's own gate corpus.** Twenty to forty seeds written to populate both
   arms. A weak baseline, but a real one, and often the only one. It also catches a
   failure a sample baseline cannot (step 7, "every A-side").
3. **Fixtures one level down.** The binding may ship none while the vendored dependency
   ships many. Filter the `find` to the target's own tree, or it returns devDependency
   noise, and **look inside vendored tarballs and submodules**: a vendored source tarball
   under `deps/` can hold the library's whole `tests/files/` with a README naming every
   case, and `find` cannot see it.
   ```sh
   find . -path ./node_modules -prune -o -type d \( -name test -o -name tests -o -name testing \
        -o -name fixtures -o -name testdata -o -name corpus -o -name golden* \) -print
   for t in deps/*.tar.* vendor/*.tar.*; do case $t in *.sig|*.asc|*.sha*) continue;; esac
     [ -f "$t" ] && tar tf "$t" | grep -iE 'test|fixture' | head; done
   ```
   (A vendored library's test directory may be named `testing`, and a tarball usually
   ships beside its `.sig`.)
   **The fixtures may not be files.** A library whose tests are compiled often carries
   hundreds of documents as string literals in its test source:
   ```sh
   resources/extract_literals.py OUT=./corpus-fixtures STARTS='<' SRC=<lib>/tests/*.c
   resources/extract_literals.py OUT=./corpus-fixtures RE='^(\x89PNG|GIF8)' SRC=test/*.js
   resources/extract_literals.py OUT=./corpus-fixtures DECODE=hex SRC=tests/*.ts
   resources/extract_literals.py OUT=./corpus-fixtures ALL=1 SRC=tests/*.c   # no signature byte
   ```
   `SRC=` repeats, takes a glob, or one quoted list; a path that does not exist is an
   error, not an empty result. `DECODE=hex|base64` when a binary record is spelled out
   as a string. `ALL=1` for a format with no signature byte (patterns, queries, source
   text); the default filter throws nearly everything away there. For a **structured**
   input convention (a container of `flags NUL pattern NUL subject`), a raw literal is
   not a seed: wrap each one into the container with a few lines of script before
   measuring. `JSREGEX=1` also extracts JS **regex literals**
   (`/.../flags`), the dominant fixture form in a regex binding's own tests, which string
   extraction misses entirely. Images embedded as `data:` URIs are not reachable this
   way; use the fixture files.
4. **The library's own writer.** Where the dependency can write the format (step 8), its
   default output is a sample corpus you generated yourself.

**Ignore the one giant sample.** A single multi-megabyte document is a cost problem, not
a corpus. Use it to find constructs, then write small seeds carrying them.

**Never `measure.sh` an unminimised borrowed set of more than a few hundred files.** Send
it straight to `minimise.sh` against the baseline maps (one `afl-showmap` per candidate,
no result pass) and measure the keepers; thousands of extracted literals are minutes of
waiting for a number you will not use.

### When there is genuinely no baseline

Anything you write is a net win; the question is what to write next. Replace `A-only`
with the to-do list the library wrote for you: **every error code it can raise that
your corpus never provokes.**

```sh
resources/error_inventory.sh SRC=<vendor dir> PREFIX=<LIB> RESULTS=maps_baseline/.results
```

Three routes, best first. If the library exposes `*_ErrorString()` / `*_strerror()`
(or a C++ `Status::CodeText()`), **do not grep**: `resources/errenum_template.c` is the
ten-line program; fill in the two names, compile it together with the library's
error-string source file (the AFL-instrumented objects do not link into a plain program;
the pristine ones do), and diff its output against the `err` column of `.results`. It
skips the filler string such functions return for non-members. The mapping is exact,
and on every target that had such a function it was the right route; an enum member
the parser never sets is dead code, which is a finding, not a gap. If the harness
prints the numeric code, parse the enum from the header and index it:
`sed -n '/^typedef enum/,/^}/p' <lib>/api.h | grep -oE '[A-Z][A-Z0-9_]*ERR[A-Z0-9_]*'`.
Only otherwise grep literals, and if the library *composes* its messages at runtime,
grep the composer, not the literals: a literal grep both misses most of the real
inventory and returns unrelated constants. `HASHCMD=` only works when the harness hashes
exactly the literal; a low hit rate from it means the comparison is broken, not the
corpus.

Classify what remains: **input-reachable** (write the seed), **API-state only**
(suspend/abort/alloc-failure paths: ignore), **unreachable in this configuration** (a
feature the binding never enables, a legacy format compiled out: ignore, and record why),
and **converted internally** (an inner layer's code that an outer layer maps to a generic
one before it reaches the API: an entropy decoder's table-size errors reported as
"corruption detected" by the block layer; the generic code is the reachable one, so count
the inner ones as covered by it, not as gaps). The third class is where effort goes to
die: check which constructor and which subsystems the binding actually calls before
writing seeds for a feature it never turns on. One more thing the histogram shows: a JS
wrapper may **shadow** the library's header errors (a size pre-check that throws its own
error before the native call), so a code is reachable only through an input that gets
past the pre-check first (an unsized first frame); the per-family `err` histogram is
where that shows.

**Measure after each family.** A family that adds nothing means you misread the code
(when to stop: the last section).

---

## Step 3 — Read the entry point first

Find the function that decides *what kind of input this is*.

* **Sniffers are looser than the formats they claim to detect.** Look for magic checks
  testing fewer bytes than the signature has, or skipping one. Write one seed per
  sniffer at its **minimum match**, often 2-12 bytes: the cheapest coverage in the method.
  ```sh
  grep -rnE "memcmp\(.*(magic|sig|header)|== *0x[0-9a-fA-F]{2}.*&&.*== *0x" src/
  ```
* **Dispatch order is reachability.** If the dispatcher tests A before B, anything
  matching both never reaches B.
* **Short inputs.** A zero-padded fixed-size sniff buffer means sub-minimum inputs still
  reach every sniffer with defined values. Emit lengths 0, 1, 2, 3 and the sniff width.
* **Anything that runs before the real codec**: metadata, container framing, checksum
  skipping. In-tree, hand-written, rarely reviewed, reachable behind two bytes of magic.
  Prioritise it.
* **Supported formats with zero fixtures** are the biggest gap a sample corpus has, and
  mutation never closes it. **Verify the back end is registered** before writing a family
  for it: a class name in `strings` can sit behind an `#ifdef` the build never defined.
  One minimum-match probe settles it. Have the harness print **which back end was
  selected**.

---

## Step 4 — Turn the format into axes

One line per axis; `references/axes.md` has the reasoning and the greps.

| axis | how to find it | what to emit |
|---|---|---|
| generated parser | the grammar/schema/IDL file **is** the axis list; its `extras` and token regexes are looser than the standard | productions, separators, tokens straight from the grammar |
| constants | `enumerate_constants.sh` for hand-rolled parsers; `case` arms and enums for mature ones. **Only when the value selects a branch**: names looked up in one table by one loop (Unicode property names, script names) are data, and 516 seeds for them bought 11 edges | every accepted value, every rejected one, one unlisted, both sides of each range check |
| declared sizes and counts | any field the code allocates or loops from (content size, dimensions, entry counts); the field's **encoding** (one frame format stores size-256 under one flag) | both sides of the allocation ceiling, sums across records (2^53 in a JS double, 2^64), the wrap-to-zero product, and each encoding boundary checked against the real writer |
| the fixture the harness supplies | for a program-shaped input (regex, query, template) the subject's length and anchoring select the engine | several subjects via `SUBJECT=`, and seeds that genuinely match each one; dump the match result to confirm they do |
| options and modes | `grep -rnE '_PARSE_\|_OPT_\|getenv\(' src/ harness.cc`; also compile-time macros and constructors the binding never calls | per-setting corpus directories via `sweep.sh` (step 7: sweep both sides) |
| parallel implementations | per encoding, width, endianness, syntax (`_utf8_`, `_le_`, `SIMD`) | the construct list re-emitted over every implementation |
| internal buffer sizes | `#define *_(BUF\|CHUNK\|BLOCK)_SIZE` | a multi-byte char straddling each boundary; tables grown past their initial size |
| position | prolog, declaration, content, attribute value, epilog, inside a literal | each construct in each legal position |
| sub-grammar | does the construct take an argument something else parses? | the grammar *inside* the construct |
| argument depth | the twenty highest-fanout entry points | arities, keyword args, nesting, type variation, boundaries, laziness |
| implementation selection | `can_\|choose\|select\|strategy\|_fast_path` | the *combination* that selects each engine |
| metadata x format | payload shape typed by the main header | the grid, correctly sized, plus one sized for the wrong variant |
| multiplicity | one declaration of N things vs N declarations; first vs fiftieth occurrence | both; 1 and ~50 |
| size | tile/strip/chunk thresholds | a few mid-sized seeds; declared dimensions capped independently |

Cross only the fields the code couples (`if (... && ...)` naming two fields). Crossing
everything with everything produces 10 000 files testing one error path.

**Options are often worth more than any seed work** and easy to miss because they are not
input bytes; a setting that changes nothing is itself a finding (the binding never makes
the call). Expect a near-null result sometimes.

### Bug patterns to hold in mind while reading

| Shape | Why it breaks | Seeds to write |
|---|---|---|
| Range check **before** a sign flip (`if (h > MAX) err; if (h < 0) h = -h;`) | the negation reintroduces the excluded value | large negatives for every signed field, especially `INT_MIN` |
| Allocation size computed in `int` from input fields | overflows long before any field looks unreasonable | factor backwards so the product **wraps to 0 or small positive** |
| `new T[n]` without `nothrow` plus a null check | plain `new[]` throws, so the guard is dead code | an unreasonable size aborts the process |
| `new (nothrow) T[n]` where arithmetic **wraps to 0** | allocation succeeds, every guard passes | a *negative* size is caught, zero is not |
| Two reader primitives, one checked and one not | some call site relies on one up-front check | pass the up-front check, then read more than was validated |
| A reader with no bounds checks plus a separate `hasBytes()` | a caller that does not use it; `_idx + n` wraps | an index so large the wrap reports "true" |
| Unsigned underflow in relative offsets (`skip(read32() - 8)`) | `value < constant` gives ~4 G | that field at `0`, `1`, `constant-1`, `UINT_MAX` |
| Table indexed by a raw byte, sized by a count field | index 0..255 into a 2-entry table | minimum legal table size, maximum index values |
| Loop bound from one structure, memory sized by another | declared vs actual, container vs element | mismatch the pair |
| Error paths that release without clearing the pointer | shared cleanup frees again | reach each early return |
| Anything parsed **before** validation | hand-written, rarely reviewed, cheap to reach | two bytes of magic plus crafted metadata |

Verify allocator behaviour on *your* toolchain with a ten-line program rather than
reasoning about it.

---

## Step 5 — Choose how to author the seeds

| Input shape | Author as | Why |
|---|---|---|
| Binary record with sizes/offsets that must agree | **generator** from `resources/gen_template.mjs` | derived fields cannot be hand-maintained; you will regenerate a dozen times |
| Text in a grammar | **literal seeds, one file per construct** | a flat list of `emit(name, bytes, why)` *is* the readable form |
| Families that multiply (construct x encoding x position) | **small loops over a table of literals** | mild parameterisation, not a field-deriving generator |
| Payload that must genuinely decode | **the library's own writer** (step 8) | hand-assembly means implementing the codec |

The deciding property is whether seeds contain fields that must agree with each other.
If nothing has to be derived, do not build a generator.

**If you write a generator**, start from `gen_template.mjs`. It already names files
`<family>-<nnn>-<name>` so `validate.sh PREFIX=` can slice a family, writes the manifest
*outside* the corpus directory, clamps every written integer to its field width, and
separates the declared value from the actual layout. What you add:

* **Defaults that parse to completion, proved by byte-diffing against the real writer
  before any family exists.** Thirty seconds, and it catches the class of framing error
  that no re-reading of the format does:
  ```sh
  <writer> < sample > ref.bin && od -An -tx1 ref.bin | head -3
  node gen.mjs ONLY=default && od -An -tx1 corpus-derived/default-001-default | head -3
  ```
  A difference in an **optional** field (a writer that adds sizes or padding to a header
  by default, a multithreaded encoder's flags) is fine when both records decode to the
  same bytes; a difference in a required field is the bug you are looking for.
* **Dependent fields derived from the code's own rule.** A plausible constant silently
  kills a whole family.

**If you write literal seeds**, start from one that parses to completion and vary one
construct per file. A family that all dies on an early syntax error tests one path many
times.

**Seeds that crash the sanitized harness are the point, not a problem.** The bug-pattern
table asks for them (INT_MIN dimensions, indices past a palette), and they belong in the
deliverable under the seed policy at the top: ASAN-only crashers stay in `corpus-final/`
and are copied to `crashers/`; plain-harness crashers and hangs leave it.

**Either way:** keep two or three realistic composites (per-construct seeds cannot cover
combinations) and mark them in the manifest. A generator that imports the package needs
the harness's loader interception, pointed at a plain snapshot: the in-tree artefact is
whatever variant was built last.

---

## Step 6 — Validate that seeds reach deep code, not that they run

The highest-value check here. A corpus can have hundreds of files, all executing without
error, and score no better than the baseline, because they all died on the first
validated field.

```sh
resources/measure.sh BASE=derived HARNESS=./out/plain/harness-fork CORPUS=./corpus-derived   # writes maps_derived/
resources/validate.sh RESULTS=maps_derived/.results FIELD=err                  # from measure.sh
resources/validate.sh RESULTS=maps_derived/.results FIELD=err PREFIX=len-      # one family, no harness runs
resources/validate.sh RESULTS=maps_derived/.results FIELD=err IGNORE="out_hash out_len"   # group by error only
```

**Run it per family.** One broken family of 15 disappears into 200 healthy seeds. Three
checks, in increasing value:

1. **Exit-code histogram**, only if the target can reject at all. An error-recovering
   parser never fails; use its own error flag as the arm signal instead.
2. **Unique maps vs file count.** Want them close, with the step-1 caveat about
   uninstrumented code.
3. **The target's own error code, per seed.** The same early error on every seed means
   you never got past field one. This is the one that finds the bug.

**When the "valid" seeds do not parse, diff against the real encoder** instead of
reasoning about which field is wrong: `od -An -tx1` on one record from each, side by
side. It is faster and it is conclusive.

---

## Step 7 — Compare as set differences, attribute the gap, minimise, stop

The absolute edge count depends on how much of the dependency is instrumented; the set
*differences* say where to go next.

```sh
resources/compare.sh A=maps_baseline B=maps_derived
```

* **Expect reading alone to score level with or below the baseline.** A derived corpus
  and a sample corpus are often largely disjoint; the action is to merge, not replace.
* **`A-only` is the to-do list.** It names the files holding the edges you miss: open
  them and read them. Each attribution round names a different missing axis.
* **Measure against every A-side you have.** A baseline your corpus already subsumes
  gives `A-only = 0` and tells you nothing; the gate corpus or a second fixture set costs
  one more `measure.sh` run and can expose a broken family the first one hid.
* **If you swept options, sweep the baseline too** (`sweep.sh` on both), or the comparison
  is partly manufactured.

**Union, then keep it lean.** No sourcing strategy dominates; ship the union as
`corpus-final/`. Minimise each borrowed or swept set against what you have, assemble,
apply the seed policy, measure:

```sh
H=./out/plain/harness-fork
# every BORROWED set is minimised against what you have, and only its keepers are shipped
resources/minimise.sh HAVE="maps_derived maps_baseline" CAND=./corpus-fixtures HARNESS=$H KEEP=./corpus-extra
resources/minimise.sh HAVE="maps_derived maps_baseline" CAND=./corpus-samples  HARNESS=$H KEEP=./corpus-extra
# union of every set (name yours), deduplicated by content hash; corpus/ is read, never written
mkdir -p corpus-final crashers hangs; : > corpus-final.hashes
for f in corpus/* corpus-derived/* corpus-extra/*; do
  [ -f "$f" ] || continue
  h=$(sha1sum < "$f" | cut -d' ' -f1); grep -qx "$h" corpus-final.hashes && continue
  echo "$h" >> corpus-final.hashes
  n=$(basename "$f"); [ -e "corpus-final/$n" ] && n="$(basename "$(dirname "$f")")-$n"
  cp "$f" "corpus-final/$n"
done
resources/measure.sh BASE=final HARNESS=$H CORPUS=./corpus-final
# seed policy: hangs and plain-harness crashes (rc >= 128 is a signal) leave corpus-final/
awk -F'\t' '$1=="hang"{print $3}' maps_final/.results | while read -r n; do mv "corpus-final/$n" hangs/; done
awk -F'\t' '$1~/^[0-9]+$/ && $1>=128 {print $3}' maps_final/.results | while read -r n; do mv "corpus-final/$n" crashers/; done
# ASAN-only crashers stay, and are copied out with their summary line.  Same ASAN_OPTIONS as
# the campaign and the gate: without the allocation ceiling a seed that merely DECLARES a huge
# size aborts with allocation-size-too-big and is filed as a crasher it is not.
# Default mode only, in parallel: a seed that crashes only in another mode is the campaign's
# to find (it runs one campaign per mode), not worth a serial pass per mode here.
export ASAN_OPTIONS="detect_leaks=0:allocator_may_return_null=1:max_allocation_size_mb=${ALLOC_CAP_MB:-1024}"
find corpus-final -maxdepth 1 -type f -print0 | xargs -0 -P 8 -I{} bash -c '
  s=$(timeout -k1 5 ./out/asan/harness-fork "$1" 2>&1 >/dev/null | grep -m1 "^SUMMARY:")
  [ -n "$s" ] && cp "$1" crashers/ && printf "%s\t%s\n" "$(basename "$1")" "$s"' _ {} >> crashers.summary.tsv
resources/measure.sh BASE=final HARNESS=$H CORPUS=./corpus-final     # maps_final/ after the moves
resources/sweep.sh BASE=final HARNESS=$H CORPUS=./corpus-final SWEEP="$MODES"   # per-mode + maps_final_union/
resources/cover.sh MAPS="maps_final_union" KEEP=./corpus-min CORPUS=./corpus-final
```

The greedy cover in `corpus-min/` is a stop signal, not a reason to ship only the cover
(a fuzzer mutates what you give it, and duplicates cost little); criteria in the last section.

**Re-run the harness skill's gate on `corpus-final/`**: the **plain** variant in the
default mode over the whole corpus (`JOBS=8`; a thousand seeds is about a minute), then
the other modes and the asan variant over `corpus-min/` only. The oracle's ceiling and a
mirroring gap show on plain in the default mode; the cover reaches every edge, so it is
enough to prove the other arms. Gating every seed in every mode on every variant is what
turned one run into an hour. It is the only check that finds fidelity gaps the gate corpus was
too small to reach, and on one target it was what exposed a library accepting inputs
the real stack rejects. Expect it to find the oracle's ceiling too: a lossy conversion
that changes the length as well as the hash needs `SOFT_DROP="out_len out_hash"`, and a
lossy test that looks only at the final string misses a U+FFFD inside an event's name.
Any mismatch goes back to the harness skill's step 5; do not ship a corpus the gate has
not seen. One mismatch
shape is a finding rather than a gap: a decoder that allocates its output and never
fully writes it, or a parser that leaves part of a stack buffer unset on a bad input,
puts uninitialised bytes in the API's result -- different between the arms, and for a
heap buffer often different between two runs of one arm (run each arm twice; a stack
buffer is usually stable per arm). ASAN does not see it; a one-off MSan build of the
library and harness names it. Have the real side mark exactly **those inputs** lossy
(the condition that takes the path), never the whole mode, and record it as
uninitialised memory reaching the API.

**When you cannot predict the offset, sweep and minimise.** Generate every single-byte
flip of two or three small composites (not of every seed, and never through
`measure.sh`), then `minimise.sh` keeps the few that pay. This is the fuzzer's own job;
a few hundred keepers for a few hundred edges is plenty.

---

## Step 8 — The success path needs something reading cannot give

The gap that survives source reading is code that only runs once the input was accepted.

| Target consumes | The success path needs |
|---|---|
| A record it decodes | the library's own **writer**, driven across its option surface |
| A **program** run against data (regex, query, template, bytecode) | seeds that genuinely **match or execute against the fixture the harness supplies**; dump each seed's result once to confirm, because a "matching" seed that matches nothing tests the reject path again |
| A document it transforms | a valid document per output mode |

**Decide whether you need the writer at all.** It is necessary only when the format has a
layer you cannot hand-assemble: entropy coding, a range coder, codec-internal tables, a
checksum over compressed bytes. On a shallow tag-based format it adds nothing. One
writer option is usually worth two axes: the flag that omits a declared output size is
often also the binding's dispatch switch.

**The most productive seeds of all are valid records corrupted after the header.** A
correct early section with a broken later one gets deep and *then* fails.

**Transplant blobs you cannot synthesise** (a colour profile, a metadata IFD, an embedded
font): cut the segment out of a sample and graft it onto a tiny host. Truncated and
length-inflated variants come free. Where the writer refuses a variant, keep the sample
that holds it and say so.

**If the target resolves external references, the corpus is a directory.** A seed whose
include never resolves reaches only the failure path. Create the referenced files, point
the target's search path at them, and treat the fixture directory as part of the corpus:
entities and DTDs, stylesheet imports, template includes, archive members.

---

## Step 9 — Keep per-execution cost low

Bytes are a proxy. Cost tracks **output size** (a 71-byte input rendering 512x512 is
expensive) and **how early the parser rejects**. Cap declared dimensions and counts, not
just file length, but keep a few mid-sized seeds to cross each internal chunking
threshold (size is also an axis).

```sh
resources/cost.sh HARNESS=./out/plain/harness-fork CORPUS=./corpus | head -20
```

Skip it when per-exec work is far below fork+exec (a 10 µs parser against a 900 µs
startup): the ranking is then noise. Time the call in-process instead if cost matters.

---

## When to stop, and what to keep

Stop when any of these holds:

* the fifteen-minute budget is spent: finish step 7 and ship what you have, with the
  unwritten families listed in the report;
* two consecutive families add nothing;
* the greedy cover from `cover.sh` is tiny: under about a sixth of the seeds (15 of 106
  on one small-surface target), measured over every mode (the reachable surface is
  nearly exhausted). A cover of a third or more is not a stop signal: the last two
  families are;
* the remaining gap is under the noise floor. Measure the same corpus twice
  (`BASE=base2`) and compare both the union and a pair of byte-identical seeds; take the
  larger jitter as the floor. A library that seeds its hash tables from the clock or the
  pid jitters a few edges on every run; that is the floor, not a bug in your corpus.

Keep everything listed under **Deliverable**: `corpus-final/` (the union, built in step
7), the manifests, `maps_final/`, `crashers/` and `hangs/`; `corpus-min/` only as the
cover.
Expect a substantial share of the effort to go on discovering that a generator or a seed
family was subtly broken; step 1 is what tells you.
