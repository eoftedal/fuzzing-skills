---
name: derive-a-fuzzing-corpus-from-source
description: Derive a high-coverage fuzzing seed corpus for a Ruby C extension (a gem's native parser and the C library it vendors) by reading the parser source instead of collecting sample files. Use after build-a-ruby-c-extension-fuzzing-harness, when a harness exists but has few or weak seeds, when coverage has plateaued, when a format or code path has no sample files, or when asked to improve a corpus, write seeds, mine a gem's tests for fixtures, or raise branch coverage.
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
code or name** in a field (the companion skill `build-a-ruby-c-extension-fuzzing-harness`
prints it as `err=`, a stable token, never a message with a position in it), and
`afl-showmap`. `resources/` (`$RC`) holds the scripts, every step
names its own, and all take `KEY=VALUE` arguments. Every command block starts with
`cd $W && . ./fuzz.env` (`$W` spelled out), the workspace file the harness skill wrote (each
tool call is a fresh shell); if it is missing, run that skill's `resources/init_workspace.sh`
first. `references/axes.md` is the long form of step 4; `references/measured-examples.md`
holds the magnitudes behind every rule (measured on Node bindings over the same kind of C
libraries; the method is language-neutral). The other references are named at the step
that needs them.

**The whole path:**

```sh
cd $W && . ./fuzz.env
# 1  $RC/measure.sh BASE=baseline ...                 what the existing seeds cover
# 2  borrow: a transferred corpus, the gate corpus, fixtures, extract_literals.py
# 3  read the dispatcher; one seed per sniffer at minimum match
# 4  list the axes (table below); sweep options with $RC/sweep.sh
# 5  author: gen_template.rb for records, literal files for text
# 6  $RC/validate.sh per family                       seeds reach DEEP code?
# 7  $RC/compare.sh, minimise.sh, cover.sh, $R/gate.sh   gap, union, stop, re-gate
#    $RC/dict.sh OUT=./dict.afl TOKENS="..."          the campaign's dictionary
# 8  the success path: the library's writer, transplants, fixture directories
# 9  $RC/cost.sh                                       per-exec cost
```

## Deliverable

| path | contents |
|---|---|
| `corpus-final/` | **what the campaign fuzzes by default.** The union of the baseline, every borrowed set, the derived families and the `minimise.sh` keepers, deduplicated by content (step 7). Not just the cover. |
| `dict.afl` | the campaign's dictionary from `dict.sh` (step 7): the build's compared constants plus the tokens you supply |
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
one corpus measured several times: `sweep.sh SWEEP='MODE=... MODE=...'` measures every mode
and writes the per-seed union `maps_<base>_union/`, `minimise.sh MODES=` keeps a candidate
that adds an edge in **any** mode, and `cover.sh MAPS=` unions each seed's maps. Report
per-mode edges and the union. It stays one directory, and the campaign runs one campaign
per mode over it. Each script's mode handling: `references/axes.md`, "Several modes".

---

## Step 1 — Measure before generating anything

Non-negotiable, and the most common way this work gets wasted. You need what the
existing seeds cover before you can know what a new corpus adds *and misses*.

```sh
cd $W && . ./fuzz.env
$RC/measure.sh BASE=baseline HARNESS=./out/plain/harness-fork CORPUS=./corpus
```

It writes per-seed maps to `maps_baseline/`, always saves each seed's exit code and
result line to `maps_baseline/.results` (which `validate.sh` and `error_inventory.sh`
reuse, so the harness is not run again; `NO_RESULTS=1` skips that pass on a slow
target; it keeps an earlier `.results`), and prints edge total, unique-map count, the exit-code histogram and which seeds
duplicate another's coverage. It reads `out/<v>/map_size` itself. It costs about two process
starts per seed: use `NO_RESULTS=1` for sweeps, and see step 2 for borrowed sets.

**Then find out which back ends are in code you instrumented**, because a family aimed
at an uninstrumented decoder costs the same to write and shows up as nothing. Ask the
**harness**, not the extension (its `ldd` lists libruby and system libraries a shim or
static-archive harness never loads):

```sh
cd $W && . ./fuzz.env
nm ./out/plain/harness-fork | grep -c sancov                        # the harness itself: must be > 0
for a in out/plain/lib/*.a; do [ -f "$a" ] && printf '%-30s sancov=%s\n' "${a##*/}" "$(nm $a 2>/dev/null | grep -c sancov)"; done
ldd ./out/plain/harness-fork      # only for a harness linking a shared library: nm -D each one it names
```

Archives with sancov > 0 and no project `.so` in the `ldd` list is the good case.
Spend the family budget where the instrumentation is. When every decoder is a system
`.so` with `sancov=0` (measured on a Node image binding), the productive families are the
**in-tree parsers** (a hand-rolled reader, container glue); a family for an uninstrumented
decoder, and step 8's writer seeds for it, add nothing you can measure.

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
   ships many. Filter the `find` to the gem's own tree, and **look inside vendored
   tarballs and submodules**, which `find` cannot see (`references/borrowing.md`).
   ```sh
   cd $W && . ./fuzz.env
   find . \( -path ./vendor/bundle -o -path ./oracle \) -prune -o -type d \( -name test -o -name tests -o -name testing \
        -o -name fixtures -o -name testdata -o -name corpus -o -name golden* \) -print
   for t in ext/*/*.tar.* ports/archives/*.tar.* vendor/*.tar.*; do case $t in *.sig|*.asc|*.sha*) continue;; esac
     [ -f "$t" ] && tar tf "$t" | grep -iE 'test|fixture' | head; done
   ```
   **The fixtures may not be files.** Compiled test suites and a gem's own tests carry
   documents as string literals:
   ```sh
   cd $W && . ./fuzz.env
   $RC/extract_literals.py OUT=./corpus-fixtures STARTS='<' SRC=<lib>/tests/*.c
   $RC/extract_literals.py OUT=./corpus-fixtures RE='^(\x89PNG|GIF8)' SRC='test/**/*.rb spec/**/*.rb'
   ```
   `DECODE=hex`, `ALL=1` (no signature byte), `JSREGEX=1` (regex literals), and wrapping
   each literal into a **structured** input convention: `references/borrowing.md`.
4. **The library's own writer.** Where the dependency can write the format (step 8), its
   default output is a sample corpus you generated yourself.

**Ignore the one giant sample**, a cost problem, not a corpus: mine it for constructs,
then write small seeds carrying them.

**Never `measure.sh` an unminimised borrowed set of more than a few hundred files.** Send
it straight to `minimise.sh` against the baseline maps (one `afl-showmap` per candidate,
no result pass) and measure the keepers; thousands of extracted literals are minutes of
waiting for a number you will not use.

### When there is genuinely no baseline

Anything you write is a net win; the question is what to write next. Replace `A-only`
with the to-do list the library wrote for you: **every error code it can raise that
your corpus never provokes.**

```sh
cd $W && . ./fuzz.env
$RC/error_inventory.sh SRC=<vendor dir> PREFIX=<LIB> RESULTS=maps_baseline/.results
```

Three routes, best first (the long form, the enum one-liner and the `HASHCMD=` caveat:
`references/error-inventory.md`):

* an `*_ErrorString()` / `*_strerror()` function: fill in `$RC/errenum_template.c`
  and **do not grep**;
* the enum parsed from the header, when the harness prints the numeric code;
* only otherwise a literal grep, of the composer when messages are composed at runtime.

Classify what remains: **input-reachable** (write the seed), **API-state only**
(ignore), **unreachable in this configuration** (ignore, and record why; check the
constructor and subsystems the binding calls first) and **converted internally** (count
as covered by the generic code). The gem's Ruby wrapper may **shadow** a code; the
per-family `err` histogram shows it.

**Measure after each family.** A family that adds nothing means you misread the code
(when to stop: the last section).

---

## Step 3 — Read the entry point first

Find the function that decides *what kind of input this is*. Why each check pays:
`references/entry-point.md`.

* **Write one seed per sniffer at its minimum match**, often 2-12 bytes.
  ```sh
  cd $W && . ./fuzz.env
  grep -rnE "memcmp\(.*(magic|sig|header)|== *0x[0-9a-fA-F]{2}.*&&.*== *0x" src/
  ```
* **Dispatch order is reachability**: anything matching an earlier test never reaches a
  later one.
* **Emit lengths 0, 1, 2, 3 and the sniff width.** A 0-byte file is no afl-fuzz seed
  (dropped, and named in `campaigns/<name>.dropped`): keep it in the gate corpus; step 7's
  union skips it.
* **Prioritise anything that runs before the real codec**: metadata, container framing,
  checksum skipping.
* **Write a family for every supported format with zero fixtures**, after one
  minimum-match probe proves the back end is registered. Have the harness print **which
  back end was selected**.

---

## Step 4 — Turn the format into axes

One line per axis; `references/axes.md` has the reasoning and the greps.

| axis | how to find it | what to emit |
|---|---|---|
| generated parser | the grammar/schema/IDL file **is** the axis list; its `extras` and token regexes are looser than the standard | productions, separators, tokens straight from the grammar |
| constants | `enumerate_constants.sh` for hand-rolled parsers; `case` arms and enums for mature ones. **Only when the value selects a branch**: names looked up in one table by one loop (Unicode property names) are data (516 seeds, 11 edges); a table of function pointers (one converter per name) is an axis | every accepted value, every rejected one, one unlisted, both sides of each range check |
| declared sizes and counts | any field the code allocates or loops from (content size, dimensions, entry counts); the field's **encoding** (one frame format stores size-256 under one flag) | both sides of the allocation ceiling, sums across records (2^53 in a Float, 2^64), the wrap-to-zero product, and each encoding boundary checked against the real writer |
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

**Hold the bug patterns in mind while reading**: `references/bug-patterns.md` lists the
code shapes that break and the seeds that reach them. Verify allocator behaviour on
*your* toolchain with a ten-line program rather than reasoning about it.

---

## Step 5 — Choose how to author the seeds

| Input shape | Author as | Why |
|---|---|---|
| Binary record with sizes/offsets that must agree | **generator** from `$RC/gen_template.rb` | derived fields cannot be hand-maintained; you will regenerate a dozen times |
| Text in a grammar | **literal seeds, one file per construct** | a flat list of `emit(name, bytes, why)` *is* the readable form |
| Families that multiply (construct x encoding x position) | **small loops over a table of literals** | mild parameterisation, not a field-deriving generator |
| Payload that must genuinely decode | **the library's own writer** (step 8) | hand-assembly means implementing the codec |

The deciding property is whether seeds contain fields that must agree with each other.
If nothing has to be derived, do not build a generator.

**If you write a generator**, start from `gen_template.rb` (what it already does, and why
these two rules: `references/authoring.md`):

* **Prove the defaults parse to completion by byte-diffing against the real writer before
  any family exists.** A difference only in an optional field is fine when both decode the same.
  ```sh
  cd $W && . ./fuzz.env
  <writer> < sample > ref.bin && od -An -tx1 ref.bin | head -3
  ruby gen.rb ONLY=default && od -An -tx1 corpus-derived/default-001-default | head -3
  ```
* **Derive dependent fields from the code's own rule.** A plausible constant silently
  kills a whole family.

**If you write literal seeds**, start from one that parses to completion and vary one
construct per file. A family that all dies on an early syntax error tests one path many
times.

**Seeds that crash the sanitized harness are the point, not a problem.** The bug
patterns ask for them; the seed policy at the top says where they go.

**Either way:** keep two or three realistic composites (per-construct seeds cannot cover
combinations) and mark them in the manifest. A generator that requires the gem needs
its load path pointed at a plain snapshot (`ruby -I out/plain gen.rb`): the in-tree
`<name>.so` is whatever variant was built last.

---

## Step 6 — Validate that seeds reach deep code, not that they run

The highest-value check here. A corpus can have hundreds of files, all executing without
error, and score no better than the baseline, because they all died on the first
validated field.

```sh
cd $W && . ./fuzz.env
$RC/measure.sh BASE=derived HARNESS=./out/plain/harness-fork CORPUS=./corpus-derived   # writes maps_derived/
$RC/validate.sh RESULTS=maps_derived/.results FIELD=err                  # from measure.sh
$RC/validate.sh RESULTS=maps_derived/.results FIELD=err PREFIX=len-      # one family, no harness runs
$RC/validate.sh RESULTS=maps_derived/.results FIELD=err IGNORE="out_hash out_len"   # group by error only
```

After `sweep.sh` the results are per mode: `maps_<base>_default/.results` (and
`maps_<base>_MODE_<value>/.results`), not `maps_<base>/.results`.

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
cd $W && . ./fuzz.env
H=./out/plain/harness-fork
# every BORROWED set is minimised against what you have, and only its keepers are shipped
$RC/minimise.sh HAVE="maps_derived maps_baseline" CAND=./corpus-fixtures HARNESS=$H KEEP=./corpus-extra
$RC/minimise.sh HAVE="maps_derived maps_baseline" CAND=./corpus-samples  HARNESS=$H KEEP=./corpus-extra
# union of every set (name yours), deduplicated by content hash; corpus/ is read, never written
mkdir -p corpus-final crashers hangs; : > corpus-final.hashes
for f in corpus/* corpus-derived/* corpus-extra/*; do
  [ -s "$f" ] || continue                  # a 0-byte file is no afl-fuzz seed
  h=$(sha1sum < "$f" | cut -d' ' -f1); grep -qx "$h" corpus-final.hashes && continue
  echo "$h" >> corpus-final.hashes
  n=$(basename "$f"); [ -e "corpus-final/$n" ] && n="$(basename "$(dirname "$f")")-$n"
  cp "$f" "corpus-final/$n"
done
$RC/measure.sh BASE=final HARNESS=$H CORPUS=./corpus-final
# seed policy: hangs and plain-harness crashes (rc >= 128 is a signal) leave corpus-final/.
# Rebuilt on every run, one row per file in crashers/, keeping smoke.sh's smoke-* rows
# (its REAL crashes land in crashers/ too, and this pass does not re-find them).
grep '^smoke-' crashers.summary.tsv > .summary.tmp 2>/dev/null; mv .summary.tmp crashers.summary.tsv
awk -F'\t' '$1=="hang"{print $3}' maps_final/.results | while read -r n; do mv "corpus-final/$n" hangs/; done
awk -F'\t' '$1~/^[0-9]+$/ && $1>=128 {print $1"\t"$3}' maps_final/.results | while IFS=$'\t' read -r rc n; do
  mv "corpus-final/$n" crashers/ && printf '%s\tplain rc=%s\n' "$n" "$rc" >> crashers.summary.tsv; done
# ASAN-only crashers stay, copied out with their SUMMARY: line; default mode only. Why the
# ceiling and the 30 s timeout: references/measured-examples.md, step 7.
export ASAN_OPTIONS="detect_leaks=0:exitcode=86:allocator_may_return_null=1:max_allocation_size_mb=${ALLOC_CAP_MB:-1024}"
find corpus-final -maxdepth 1 -type f -print0 | xargs -0 -P 8 -I{} bash -c '
  o=$(timeout -k1 "$2" ./out/asan/harness-fork "$1" 2>&1 >/dev/null); rc=$?; s=$(grep -m1 "^SUMMARY:" <<<"$o")
  if [ -n "$s" ]; then cp "$1" crashers/ && printf "%s\t%s\n" "$(basename "$1")" "$s"
  elif [ $rc -eq 86 ] || [ $rc -ge 124 ]; then echo "WARN: $1 rc=$rc, no SUMMARY: (raise the timeout)" >&2; fi' _ {} "${ASAN_TIMEOUT:-30}" >> crashers.summary.tsv
$RC/measure.sh BASE=final HARNESS=$H CORPUS=./corpus-final     # maps_final/ after the moves
# no modes: sweep.sh refuses an empty SWEEP and writes no union, so cover the one map set
if [ -n "${MODES:-}" ]; then
  $RC/sweep.sh BASE=final HARNESS=$H CORPUS=./corpus-final       # SWEEP defaults to fuzz.env's MODES
  $RC/cover.sh MAPS="maps_final_union" KEEP=./corpus-min CORPUS=./corpus-final
else
  $RC/cover.sh MAPS="maps_final" KEEP=./corpus-min CORPUS=./corpus-final
fi
```

The greedy cover in `corpus-min/` is a stop signal, not a reason to ship only the cover
(a fuzzer mutates what you give it, and duplicates cost little); criteria in the last section.

**First, check the corpus agrees with itself**: `$RC/nondet.sh
HARNESS=./out/plain/harness-fork CORPUS=./corpus-final MOVE=./corpus-nondet` (`MODES` from
`fuzz.env`) runs every seed several times on one binary and moves out the ones whose result
varies; one also in `crashers/` stays, reported as the bug, not noise. A seed that disagrees
with itself fails the gate at random and drags the campaign's stability down (what to do
with them: the harness skill's `references/oracle-ceiling.md`). When it moves anything, re-run
the last `measure.sh` and the cover, so `maps_final/` and `corpus-min/` drop those seeds too.

**Re-run the harness skill's gate on `corpus-final/`**: the **plain** variant in the
default mode over the whole corpus, then every mode on the asan variant over `corpus-min/`
only (the cover reaches every edge). `REAL`/`REAL_ASAN` (with `$PKG` and `$EXT_ASAN`),
`FIELDS`, `SOFT_*` and `MODES` come from `fuzz.env`:

```sh
cd $W && . ./fuzz.env
$R/gate.sh DIRECT=./out/plain/harness-fork CORPUS=./corpus-final MODES= JOBS=8 MAP_SIZE=$(cat out/plain/map_size)  # default mode
$R/gate.sh DIRECT=./out/asan/harness-fork CORPUS=./corpus-min MAP_SIZE=$(cat out/asan/map_size)
```

It alone finds fidelity gaps the gate corpus was too small to reach. Expect the oracle's ceiling: a lossy conversion that changes the
length as well as the hash needs `SOFT_DROP="out_len out_hash"`, and a lossy test on
the final string alone misses a U+FFFD inside an event's name. Any mismatch goes back
to the harness skill's step 5; do not ship a corpus the gate has not seen. A mismatch
that differs between arms, or between two runs of one arm, may be uninitialised memory
reaching the API: a finding, handled per the harness skill's
`references/oracle-ceiling.md`.

**When you cannot predict the offset, sweep and minimise.** Generate every single-byte
flip of two or three small composites (not of every seed, and never through
`measure.sh`), then `minimise.sh` keeps the few that pay. This is the fuzzer's own job;
a few hundred keepers for a few hundred edges is plenty.

**Write the dictionary.** Mutation flips and splices bytes, so a multi-byte token that a
branch compares whole (a keyword, a format name, a separator) is one it almost never
assembles; the dictionary hands it over (why and an example: `references/dictionary.md`):

```sh
cd $W && . ./fuzz.env
$RC/dict.sh OUT=./dict.afl TOKENS="<tokens>" [TOKENS_FILE=<file>] [SRC="<uninstrumented sources>"]
```

It merges `out/plain/dict.afl` (the constants the instrumented code compares against) with
`TOKENS`: the framing separators documented at the top of `harness.cc`, every `MODE` and
option value, the names in a lookup table that selects code, a grammar's keywords and
operators. `SRC=` harvests literals from sources afl-clang-fast never compiled (a system
library built outside, `lib/**/*.rb` whose literals select native paths). The campaign
picks up `$W/dict.afl` by itself.

---

## Step 8 — The success path needs something reading cannot give

The gap that survives source reading is code that only runs once the input was accepted.

| Target consumes | The success path needs |
|---|---|
| A record it decodes | the library's own **writer**, driven across its option surface |
| A **program** run against data (regex, query, template, bytecode) | seeds that genuinely **match or execute against the fixture the harness supplies**; dump each seed's result once to confirm, because a "matching" seed that matches nothing tests the reject path again |
| A document it transforms | a valid document per output mode |

**Use the writer only for a layer you cannot hand-assemble** (entropy coding, a range
coder, codec tables, a checksum over compressed bytes); on a shallow tag-based format it
adds nothing.

**The most productive seeds of all are valid records corrupted after the header.** A
correct early section with a broken later one gets deep and *then* fails.

**Transplant blobs you cannot synthesise** onto a tiny host. **If the target resolves
external references, the corpus is a directory** of the referenced files. Both, and the
writer option that doubles as a dispatch switch: `references/authoring.md`.

---

## Step 9 — Keep per-execution cost low

Bytes are a proxy. Cost tracks **output size** (a 71-byte input rendering 512x512 is
expensive) and **how early the parser rejects**. Cap declared dimensions and counts, not
just file length, but keep a few mid-sized seeds to cross each internal chunking
threshold (size is also an axis).

```sh
cd $W && . ./fuzz.env
$RC/cost.sh HARNESS=./out/plain/harness-fork CORPUS=./corpus | head -20
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
  on one small-surface Node binding), measured over every mode (the reachable surface is
  nearly exhausted). A cover of a third or more is not a stop signal: the last two
  families are;
* the remaining gap is under the noise floor. Measure the same corpus twice
  (`BASE=base2`) and compare both the union and a pair of byte-identical seeds; take the
  larger jitter as the floor (a clock-seeded hash table jitters a few edges every run).

Keep everything listed under **Deliverable**: `corpus-final/` (the union, built in step
7), the manifests, `dict.afl`, `maps_final/`, `crashers/` and `hangs/`; `corpus-min/` only as the
cover.
Expect much of the effort to go on finding that a family was subtly broken; step 1 tells you.
