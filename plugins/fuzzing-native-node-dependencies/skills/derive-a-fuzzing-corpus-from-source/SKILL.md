---
name: derive-a-fuzzing-corpus-from-source
description: Derive a high-coverage fuzzing seed corpus by reading the target's parser source instead of collecting sample files. Needs the gated fork harness from build-a-nan-napi-fuzzing-harness and its gate corpus. Use when a fuzzing harness exists but has few or weak seeds, when coverage has plateaued, when a format or code path has no sample files, or when asked to improve a corpus, write seeds, or raise branch coverage. The second of four skills - after build-a-nan-napi-fuzzing-harness, before run-a-fuzzing-campaign and triage-fuzzing-findings.
---

# Derive a fuzzing corpus by reading the source

You have a working harness. This is about what to feed it.

**Budget: about fifteen minutes, and it does not have to be perfect.** The deliverable is
a corpus that beats the baseline, passes the gate, and names what it does not cover; the
campaign's mutations do the rest. Time goes on waiting (unminimised measuring, gating
everything everywhere, per-mode crasher passes); the rules below say what to skip. Past
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
it as `err=`); `afl-showmap`. `resources/` holds the scripts (`$RC/` in every command),
every step names its own, and all take `KEY=VALUE` arguments. `references/` holds the long form of each step,
pointed at from the step; `references/measured-examples.md` holds the magnitudes behind
every rule. Read this file with a file reader, not `cat` into a terminal that truncates.

**Every command block starts with `cd $W && . ./fuzz.env`** (`$W` written out as the
absolute workspace path), because each tool call is a fresh shell; the harness skill wrote `fuzz.env` (`R`, `RC`, `W`, `PKG`, `MODES`, ...), and
if it is missing, go back and run its `init_workspace.sh`.

**The whole path:**

```sh
cd $W && . ./fuzz.env
# 1  $RC/measure.sh BASE=baseline ...           what the existing seeds cover
# 2  borrow: a transferred corpus, the gate corpus, fixtures, extract_literals.py
# 3  read the dispatcher; one seed per sniffer at minimum match
# 4  list the axes (table below); sweep options with $RC/sweep.sh
# 5  author: gen_template.mjs for records, literal files for text
# 6  $RC/validate.sh per family                 seeds reach DEEP code?
# 7  $RC/compare.sh, minimise.sh, cover.sh      gap, union, stop signal
# 7b $RC/dict.sh OUT=./dict.afl TOKENS=...       the campaign's dictionary
# 8  the success path: the library's writer, transplants, fixture directories
# 9  $RC/cost.sh                                 per-exec cost
```

## Deliverable

| path | contents |
|---|---|
| `corpus-final/` | **what the campaign fuzzes by default.** The union of the baseline, every borrowed set, the derived families and the `minimise.sh` keepers, deduplicated by content (step 7). Not just the cover. |
| `corpus-min/` | the greedy cover from `cover.sh`: a stop signal and a quick-check set, never the fuzzing default |
| `maps_final/` | `measure.sh BASE=final CORPUS=./corpus-final`, so the next person can compare against it |
| `crashers/`, `hangs/` | per the seed policy below, with `crashers.summary.tsv` beside them |
| `<set>.manifest.tsv` | beside each generated set, outside the corpus directory |
| `dict.afl` | the AFL++ dictionary (step 7b), which `campaign.sh` passes as `-x` by default |

Do not overwrite `corpus/`: it is the harness skill's gate corpus.

**Seed policy.** A seed that crashes only the sanitized (ASAN) harness stays in
`corpus-final/` and is also copied to `crashers/`, with its sanitizer `SUMMARY:` line
recorded in `crashers.summary.tsv`. A seed that crashes the plain harness goes only to
`crashers/`, with a `plain rc=` row in the same file; one that hangs (`rc=hang` from
`measure.sh`) goes to `hangs/`; neither goes into `corpus-final/`. The campaign skill runs afl-fuzz with
`AFL_IGNORE_SEED_PROBLEMS=1`, which skips crashing and hanging seeds in the dry run
instead of aborting, so the ASAN-only crashers left in `corpus-final/` are harmless there.

Every script that runs the harness bounds each run with `TIMEOUT=` (seconds, default 5;
30 for step 7's ASAN crasher pass) and reports seeds over it as `hang`. `measure.sh` and the gate take `JOBS=` (default 8);
a thousand seeds is a minute, not five.

**A harness with several entry points** (`MODE=` settings) is one corpus measured
several times, and still one directory: the campaign runs one campaign per mode over
`corpus-final/`. `sweep.sh SWEEP='MODE=a MODE=b'` measures every mode (the current
environment is always included: do not list it) and writes `maps_<base>_union/`; give
`compare.sh` the unions, and `minimise.sh MODES= HAVE=` and `cover.sh MAPS=` every
per-mode directory. Report per-mode edges and the union. Names and details:
`references/modes.md`.

---

## Step 1 — Measure before generating anything

Non-negotiable, and the most common way this work gets wasted. You need what the
existing seeds cover before you can know what a new corpus adds *and misses*.

```sh
cd $W && . ./fuzz.env
$RC/measure.sh BASE=baseline HARNESS=./out/plain/harness-fork CORPUS=./corpus
```

It writes per-seed maps to `maps_baseline/` and each seed's exit code and result line to
`maps_baseline/.results` (which `validate.sh` and `error_inventory.sh` reuse, so the
harness is not run again), and prints edge total, unique-map count, the exit-code
histogram and which seeds duplicate another's coverage; it reads `out/<v>/map_size`
itself. `NO_RESULTS=1` skips the result pass, for a
discovery sweep only, never the final one, whose `.results` step 7 reads.

**Then find out which back ends are in code you instrumented**, because a family aimed
at an uninstrumented decoder costs the same to write and shows up as nothing. Look at
the harness binary and its archives, not the addon, whose `ldd` lists system `.so` files a
static-archive harness never loads:

```sh
cd $W && . ./fuzz.env
nm ./out/plain/harness-fork | grep -c sancov                        # the harness itself: must be > 0
for a in out/plain/lib/*.a; do [ -f "$a" ] && echo "$(basename $a) sancov=$(nm $a 2>/dev/null | grep -c sancov)"; done
# only if the harness links a shared library: nm -D on each ldd ./out/plain/harness-fork entry
```

Every archive non-zero (or no archives) is the good case. Spend the family budget where
the instrumentation is: when every decoder is in a system `.so` with `sancov=0` (or the
harness links no instrumented archive of it), write for the **in-tree parsers** (`references/measured-examples.md`
step 1); a family, or step 8's writer seeds, for an uninstrumented decoder adds nothing
you can measure.

Many seeds sharing one map die early if all *fail*, and run uninstrumented code if all
*succeed*: check the exit codes before concluding either.

---

## Step 2 — Borrow before deriving

Cheapest coverage available, in this order. Measure each as an A-side (step 7), then
`minimise.sh` it into the corpus rather than shipping all of it.

1. **A corpus derived for another target over the same format**, in the same **input
   convention** (re-encode a UTF-16 corpus for a UTF-8 parser).
2. **The harness's own gate corpus**: weak but real, often the only baseline (step 7,
   "every A-side").
3. **Fixtures one level down**, in the vendored dependency's tree. Filter the `find` to
   the target's own tree, and **look inside vendored tarballs and submodules**, which
   `find` cannot see (`references/fixtures.md`).
   ```sh
   cd $W && . ./fuzz.env && cd <package dir>
   find . -path ./node_modules -prune -o -type d \( -name test -o -name tests -o -name testing \
        -o -name fixtures -o -name testdata -o -name corpus -o -name golden* \) -print
   for t in deps/*.tar.* vendor/*.tar.*; do case $t in *.sig|*.asc|*.sha*) continue;; esac
     [ -f "$t" ] && tar tf "$t" | grep -iE 'test|fixture' | head; done
   ```
   **The fixtures may not be files**: compiled tests carry documents as string literals.
   ```sh
   cd $W && . ./fuzz.env; P=<package dir>
   $RC/extract_literals.py OUT=./corpus-fixtures STARTS='<' SRC=$P/<lib>/tests/*.c
   $RC/extract_literals.py OUT=./corpus-fixtures RE='^(\x89PNG|GIF8)' SRC=$P/test/*.js
   $RC/extract_literals.py OUT=./corpus-fixtures DECODE=hex SRC=$P/tests/*.ts
   $RC/extract_literals.py OUT=./corpus-fixtures ALL=1 SRC=$P/tests/*.c   # no signature byte
   ```
   `JSREGEX=1` for JS regex literals; wrap
   each literal into a **structured** input convention before measuring; `data:` URIs
   are not reachable this way. Options and cases: `references/fixtures.md`.
4. **The library's own writer.** Where the dependency can write the format (step 8), its
   default output is a sample corpus you generated yourself.

**Ignore the one giant sample** (a cost problem, not a corpus): mine it for constructs,
then write small seeds carrying them.

**Never `measure.sh` an unminimised borrowed set of more than a few hundred files.** Send
it straight to `minimise.sh` against the baseline maps (one `afl-showmap` per candidate,
no result pass) and measure the keepers.

### When there is genuinely no baseline

Anything you write is a net win; the question is what to write next. Replace `A-only`
with the to-do list the library wrote for you: **every error code it can raise that
your corpus never provokes.**

```sh
cd $W && . ./fuzz.env
$RC/error_inventory.sh SRC=<vendor dir> PREFIX=<LIB> RESULTS=maps_baseline/.results
```

Three routes to the list, best first (`references/error-inventory.md` has each):

* an `*_ErrorString()` / `*_strerror()` function: compile `$RC/errenum_template.c`
  against it and diff with the `err` column; **do not grep**;
* a numeric code from the harness: parse the enum from the header;
* only otherwise grep literals, and the composer when messages are built at runtime
  (`HASHCMD=` only when the harness hashes exactly the literal).

Classify what remains (input-reachable: write the seed; the other classes, and a JS
wrapper shadowing a library error, are in `references/error-inventory.md`).

**Measure after each family.** A family that adds nothing means you misread the code
(when to stop: the last section).

---

## Step 3 — Read the entry point first

Find the function that decides *what kind of input this is* (`references/axes.md`, "Read
the entry point first", has the reasoning).

* **One seed per sniffer at its minimum match**, often 2-12 bytes: sniffers test fewer
  bytes than their signature.
  ```sh
  cd $W && . ./fuzz.env && cd <package dir>
  grep -rnE "memcmp\(.*(magic|sig|header)|== *0x[0-9a-fA-F]{2}.*&&.*== *0x" src/
  ```
* **Dispatch order is reachability**: anything matching an earlier test never reaches a
  later one.
* **Emit lengths 0, 1, 2, 3 and the sniff width.** afl-fuzz drops a zero-byte seed
  (named in `campaigns/<name>.dropped`), so the step 7 union leaves it in the gate corpus.
* **Prioritise anything that runs before the real codec**: metadata, container framing,
  checksum skipping.
* **Write for supported formats with zero fixtures**, after one minimum-match probe
  proves the back end is registered. Have the harness print **which back end was
  selected**.

---

## Step 4 — Turn the format into axes

One line per axis; `references/axes.md` has the reasoning and the greps.

| axis | how to find it | what to emit |
|---|---|---|
| generated parser | the grammar/schema/IDL file **is** the axis list; its `extras` and token regexes are looser than the standard | productions, separators, tokens straight from the grammar |
| constants | `enumerate_constants.sh` for hand-rolled parsers; `case` arms and enums for mature ones. **Only when the value selects a branch**: names looked up in one table by one loop (Unicode property names) are data, and 516 seeds bought 11 edges; a table of function pointers (one converter per name) is the next row's axis | every accepted value, every rejected one, one unlisted, both sides of each range check |
| declared sizes and counts | any field the code allocates or loops from (content size, dimensions, entry counts); the field's **encoding** (one frame format stores size-256 under one flag) | both sides of the allocation ceiling, sums across records (2^53 in a JS double, 2^64), the wrap-to-zero product, and each encoding boundary checked against the real writer |
| the fixture the harness supplies | for a program-shaped input (regex, query, template) the subject's length and anchoring select the engine | several subjects via `SUBJECT=`, and seeds that genuinely match each one; dump the match result to confirm they do |
| options and modes | `grep -rnE '_PARSE_\|_OPT_\|getenv\(' src/ harness.cc`; also compile-time macros and constructors the binding never calls | per-setting corpus directories via `sweep.sh` (step 7: sweep both sides) |
| parallel implementations | per encoding, width, endianness, syntax (`_utf8_`, `_le_`, `SIMD`), or one per name in a function-pointer table | the construct list re-emitted over every implementation |
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
input bytes; a setting that changes nothing is itself a finding, and a near-null result
is normal (`references/axes.md`, "The option axis").

**Hold the bug patterns in mind while reading** (`references/bug-patterns.md`: sign flips
after range checks, `int` allocation sizes that wrap, unchecked readers, offset
underflow, mismatched loop bounds, double frees) and write the seeds each row names.
Verify allocator behaviour on *your* toolchain with a ten-line program rather than
reasoning about it.

---

## Step 5 — Choose how to author the seeds

| Input shape | Author as | Why |
|---|---|---|
| Binary record with sizes/offsets that must agree | **generator** from `$RC/gen_template.mjs` | derived fields cannot be hand-maintained; you will regenerate a dozen times |
| Text in a grammar | **literal seeds, one file per construct** | a flat list of `emit(name, bytes, why)` *is* the readable form |
| Families that multiply (construct x encoding x position) | **small loops over a table of literals** | mild parameterisation, not a field-deriving generator |
| Payload that must genuinely decode | **the library's own writer** (step 8) | hand-assembly means implementing the codec |

The deciding property is whether seeds contain fields that must agree with each other.
If nothing has to be derived, do not build a generator.

**If you write a generator**, start from `gen_template.mjs` (it already names files
`<family>-<nnn>-<name>` for `validate.sh PREFIX=`, writes the manifest outside the corpus,
clamps writes to field width, and separates declared value from layout). Add:

* **Defaults that parse to completion, proved by byte-diffing against the real writer
  before any family exists**: a differing required field is the bug, an optional one is
  fine if both decode alike (`references/measured-examples.md` step 5):
  ```sh
  cd $W && . ./fuzz.env
  <writer> < sample > ref.bin && od -An -tx1 ref.bin | head -3
  node gen.mjs ONLY=default && od -An -tx1 corpus-derived/default-001-default | head -3
  ```
* **Dependent fields derived from the code's own rule**, never a plausible constant.

**If you write literal seeds**, start from one that parses to completion and vary one
construct per file. A family that all dies on an early syntax error tests one path many
times.

**Seeds that crash the sanitized harness are the point, not a problem.** The bug patterns
ask for them (INT_MIN dimensions, indices past a palette); file them under the seed
policy at the top.

**Either way:** keep two or three realistic composites (per-construct seeds cannot cover
combinations) and mark them in the manifest. A generator that imports the package needs
the harness's loader interception, pointed at a plain snapshot: the in-tree artefact is
whatever variant was built last.

---

## Step 6 — Validate that seeds reach deep code, not that they run

The highest-value check here: hundreds of seeds can all run cleanly and score no better
than the baseline, because they all died on the first validated field.

```sh
cd $W && . ./fuzz.env
$RC/measure.sh BASE=derived HARNESS=./out/plain/harness-fork CORPUS=./corpus-derived   # writes maps_derived/
$RC/validate.sh RESULTS=maps_derived/.results FIELD=err                  # from measure.sh
$RC/validate.sh RESULTS=maps_derived/.results FIELD=err PREFIX=len-      # one family, no harness runs
$RC/validate.sh RESULTS=maps_derived/.results FIELD=err IGNORE="out_hash out_len"   # group by error only
```

**Run it per family.** One broken family of 15 disappears into 200 healthy seeds. Three
checks, in increasing value:

1. **Exit-code histogram**, only if the target can reject at all. An error-recovering
   parser never fails; use its own error flag as the arm signal instead.
2. **Unique maps vs file count.** Want them close, with the step-1 caveat about
   uninstrumented code.
3. **The target's own error code, per seed.** The same early error on every seed means
   you never got past field one. This is the one that finds the bug. With only an error
   class, or a message embedding a position, `err` is the message up to the position
   marker (`references/error-inventory.md`).

After `sweep.sh` the results are per mode: `maps_<base>_default/.results`, and one per
setting beside it (`references/modes.md`).

**When the "valid" seeds do not parse, diff against the real encoder** instead of
reasoning about which field is wrong: `od -An -tx1` on one record from each, side by
side: faster, and conclusive.

---

## Step 7 — Compare as set differences, attribute the gap, minimise, stop

The absolute edge count depends on how much of the dependency is instrumented; the set
*differences* say where to go next.

```sh
cd $W && . ./fuzz.env
$RC/compare.sh A=maps_baseline B=maps_derived
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
cd $W && . ./fuzz.env; H=./out/plain/harness-fork
# every BORROWED set is minimised against what you have, and only its keepers are shipped
$RC/minimise.sh HAVE="maps_derived maps_baseline" CAND=./corpus-fixtures HARNESS=$H KEEP=./corpus-extra
$RC/minimise.sh HAVE="maps_derived maps_baseline" CAND=./corpus-samples  HARNESS=$H KEEP=./corpus-extra
# union of every set (name yours), deduplicated by content hash; corpus/ is read, never written
mkdir -p corpus-final crashers hangs; : > corpus-final.hashes
for f in corpus/* corpus-derived/* corpus-extra/*; do
  [ -f "$f" ] && [ -s "$f" ] || continue    # zero bytes: no afl-fuzz seed
  h=$(sha1sum < "$f" | cut -d' ' -f1); grep -qx "$h" corpus-final.hashes && continue
  echo "$h" >> corpus-final.hashes
  n=$(basename "$f"); [ -e "corpus-final/$n" ] && n="$(basename "$(dirname "$f")")-$n"
  cp "$f" "corpus-final/$n"
done
$RC/measure.sh BASE=final HARNESS=$H CORPUS=./corpus-final
# seed policy: hangs and plain crashes (rc >= 128) leave corpus-final/.
# rebuild this pass's rows only: smoke-* rows are smoke.sh's finds, not re-derivable here
grep '^smoke-' crashers.summary.tsv > .tmp 2>/dev/null; mv .tmp crashers.summary.tsv
awk -F'\t' '$1=="hang"{print $3}' maps_final/.results | while read -r n; do mv "corpus-final/$n" hangs/; done
awk -F'\t' '$1~/^[0-9]+$/ && $1>=128 {print $1"\t"$3}' maps_final/.results | while IFS=$'\t' read -r rc n; do
  mv "corpus-final/$n" crashers/ && printf '%s\tplain rc=%s\n' "$n" "$rc" >> crashers.summary.tsv; done
# ASAN-only crashers stay, and are copied out with their summary line.  Same ASAN_OPTIONS as
# the campaign and the gate: without the allocation ceiling a seed that merely DECLARES a huge
# size aborts with allocation-size-too-big and is filed as a crasher it is not.
# Default mode only, in parallel: a crash only in another mode is that mode's campaign's to find.
# 30 s, not 5: under load ASAN symbolization outlasts 5 s, the report loses its SUMMARY: line,
# and the pass would record nothing; the WARN names every such seed.
export ASAN_OPTIONS="detect_leaks=0:exitcode=86:allocator_may_return_null=1:max_allocation_size_mb=$ALLOC_CAP_MB"
find corpus-final -maxdepth 1 -type f -print0 | xargs -0 -P 8 -I{} bash -c '
  o=$(timeout -k1 "$2" ./out/asan/harness-fork "$1" 2>&1 >/dev/null); rc=$?
  s=$(printf "%s\n" "$o" | grep -m1 "^SUMMARY:")
  if [ -n "$s" ]; then cp "$1" crashers/ && printf "%s\t%s\n" "$(basename "$1")" "$s"
  elif [ $rc = 86 ] || [ $rc -gt 128 ] || printf "%s" "$o" | grep -q "ERROR: AddressSanitizer"; then
    echo "WARN: $(basename "$1") rc=$rc but no SUMMARY: line: raise TIMEOUT" >&2; fi' _ {} "${TIMEOUT:-30}" >> crashers.summary.tsv
$RC/measure.sh BASE=final HARNESS=$H CORPUS=./corpus-final     # maps_final/ after the moves
# no modes: sweep.sh refuses an empty SWEEP and writes no union, so cover the one map set
if [ -n "$MODES" ]; then
  $RC/sweep.sh BASE=final HARNESS=$H CORPUS=./corpus-final SWEEP="$MODES"   # fuzz.env's MODES, as the gate's
  $RC/cover.sh MAPS="maps_final_union" KEEP=./corpus-min CORPUS=./corpus-final
else
  $RC/cover.sh MAPS="maps_final" KEEP=./corpus-min CORPUS=./corpus-final
fi
```

The greedy cover in `corpus-min/` is a stop signal, not a reason to ship only the cover
(a fuzzer mutates what you give it, and duplicates cost little); criteria in the last section.

**Check that every seed agrees with itself** (exit 0 when all do):

```sh
cd $W && . ./fuzz.env
$RC/nondet.sh HARNESS=./out/plain/harness-fork CORPUS=./corpus-final MOVE=./corpus-nondet MODES="$MODES"
```

A seed that does not agree with itself cannot pass the gate reliably, and its mutants
drag the campaign's stability down: quarantine it, or canonicalise the order on both
sides of the gate; never loosen `FIELDS`. A seed also in `crashers/` is not quarantined:
its varying result is the bug (an over-read returning garbage), not noise. When it moves
anything, re-run the last `measure.sh` and the cover so `maps_final/` and `corpus-min/` drop those seeds too.

**Re-run the harness skill's gate** (`$R/gate.sh`): the **plain** variant in the default
mode only (`MODES=""`) over the whole corpus, then the asan variant in every mode over
the cover (`gate.sh` picks `REAL_ASAN` itself for it; the rest comes from `fuzz.env`):

```sh
cd $W && . ./fuzz.env
$R/gate.sh DIRECT=./out/plain/harness-fork CORPUS=./corpus-final JOBS=8 MODES="" MAP_SIZE=$(cat out/plain/map_size)
$R/gate.sh DIRECT=./out/asan/harness-fork CORPUS=./corpus-min JOBS=8
```

Re-gate because only a real corpus reaches the oracle's ceiling; the cover is enough for
the asan arms
(`references/measured-examples.md` step 7). `gate.sh` skips seeds also in `crashers/` as
`known-crasher`, so the ASAN-only crashers the cover kept need no exclusion. The lossy
test must look at every string the API returns (a U+FFFD inside an event's name). Any
mismatch goes back to the harness skill's step 5 and its `references/oracle-ceiling.md`;
do not ship a corpus the gate has not seen.

**When you cannot predict the offset, sweep and minimise.** Generate every single-byte
flip of two or three small composites (not of every seed, and never through
`measure.sh`), then `minimise.sh` keeps the few that pay. This is the fuzzer's own job;
a few hundred keepers for a few hundred edges is plenty.

---

## Step 7b — Write the dictionary

afl-fuzz splices dictionary tokens in whole; mutation alone almost never assembles a
multi-byte keyword. The harness builds wrote `out/<variant>/dict.afl` (the constants
instrumented code compares against); add what that pass cannot see:

```sh
cd $W && . ./fuzz.env
$RC/dict.sh OUT=./dict.afl TOKENS="<separator> <mode> <option> ..." [SRC="<uncompiled sources>"]
```

`TOKENS` (or `TOKENS_FILE=`): the framing separators documented at the top of
`harness.cc`, every `MODE` and option value, the names in a lookup table that selects
code (encoding or format names), a grammar's keywords and operators. `SRC=` harvests
literals from sources afl-clang-fast never compiled (a system library, JavaScript that
selects native paths). The campaign picks `$W/dict.afl` by itself. Syntax and a worked
example: `references/dictionary.md`.

---

## Step 8 — The success path needs something reading cannot give

The gap that survives source reading is code that only runs once the input was accepted.

| Target consumes | The success path needs |
|---|---|
| A record it decodes | the library's own **writer**, driven across its option surface |
| A **program** run against data (regex, query, template, bytecode) | seeds that genuinely **match or execute against the fixture the harness supplies**; dump each seed's result once to confirm, because a "matching" seed that matches nothing tests the reject path again |
| A document it transforms | a valid document per output mode |

**Decide whether you need the writer at all** (only for a layer you cannot
hand-assemble), then drive it across its option surface. **The most productive seeds of
all are valid records corrupted after the header.** **Transplant blobs you cannot
synthesise** onto a tiny host; **if the target resolves external references, the corpus
is a directory**. Each in `references/success-path.md`.

---

## Step 9 — Keep per-execution cost low

Bytes are a proxy. Cost tracks **output size** and **how early the parser rejects**
(`references/measured-examples.md` step 9). Cap declared dimensions and counts, not
just file length, but keep a few mid-sized seeds to cross each internal chunking
threshold (size is also an axis).

```sh
cd $W && . ./fuzz.env
$RC/cost.sh HARNESS=./out/plain/harness-fork CORPUS=./corpus | head -20
```

It also lists the seeds whose per-exec work exceeds `SLOW_MS` (default 1000). The
campaign's dry run drops them silently (afl-fuzz calibrates a far lower timeout, and
`AFL_IGNORE_SEED_PROBLEMS=1` skips what exceeds it), so cap their declared work or move
them to `hangs/`.

Skip it when per-exec work is far below fork+exec: the ranking is then noise. Time the call in-process instead if cost matters.

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
