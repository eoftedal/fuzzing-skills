# Measured examples behind the rules in SKILL.md

Every rule in SKILL.md was learned on a target; this file keeps the magnitudes, by step,
so SKILL.md can state the rule in a line. Read an entry when you doubt a rule or want to
know how big an effect to expect. `EVIDENCE.md` maps each target to its totals.

## Step 1 — Measure first

* **A healthy-looking corpus can be broken.** A 90-file generator whose every seed was
  rejected scored **176 edges against a 19-seed baseline's 565**. Two wrong fields, fixed,
  took the same 90 seeds to **459**. The bugs had cost 62 % of the corpus's coverage while
  it looked perfectly healthy by file count and by "it runs".
* **One unique map with every seed succeeding means uninstrumented code.** One baseline
  had 13 files, 24 edges and a *single* unique map, and every file **succeeded**: the
  whole decode happened inside an uninstrumented system library. Seeds sharing one map
  while all *failing* die early; sharing one map while all *succeeding* means the work is
  in code you did not instrument.
* **Spend the family budget where the instrumentation is.** On a five-format target where
  four decoders were uninstrumented system libraries, the greedy cover's top ten seeds
  were six of one in-tree format, three of an in-tree metadata reader and one palette
  walk, and **nothing from the two formats whose decoders lived outside the build**,
  despite 21 seeds having been written for them. On an image-decoding binding whose
  codecs are system libraries, the productive families are the in-tree parsers: a
  hand-rolled BMP reader, container and EXIF glue, GIF compositing.

## Step 2 — Borrow before deriving

* **Transfer across bindings of one format.** A corpus derived for one library, applied
  unchanged to a different library parsing the same format, reached **97 % of that
  target's own fixture coverage and found 400+ edges the fixtures missed, for no work.**
* **Fixtures as string literals.** Extracting the inline documents from a library's
  compiled test suite yielded **106 documents holding 182 edges** a hand-built corpus
  missed. On a signature-less format the defaults filtered almost everything out: **30
  literals with the defaults, 2444 with `ALL=1`**, the latter worth hundreds of edges.
* **Error inventory by literal grep is noisy when messages are composed.** On one target it
  found 17 candidates of which 9 were not errors, while the true inventory was 41,
  because every message was assembled at runtime (`"Error while processing " + op + " - "
  + err`, with `err` itself concatenated by a `setErr*` wrapper).
* **Writing against the error-code list works.** On one XML target the reached error
  codes went from **7/42 to 20/42**, and it beat both a real-world sample corpus and the
  library's own fixtures on the same measure.
* **An unused constructor kills a family permanently.** One target compiled namespace
  support in and then never activated it, because the binding calls the plain
  constructor rather than the namespace-aware one: five error codes dead, and no amount
  of env-var sweeping would have shown it.
* **A dev-dependency's fixtures are not a baseline.** One "baseline" was 13 images
  belonging to two unrelated packages, found by an unfiltered `find`.

## Step 3 — Read the entry point

* **Sniffers at minimum match are the cheapest coverage in the method.** On a
  multi-format dispatcher, of 12 registered back ends the fixture corpus reached nine,
  and all three it missed were reachable in **12 bytes or fewer**.
* **Some sniffers copy `MIN(n, srcSize)` bytes over a buffer preloaded with the magic**,
  so a 1-byte input can pass as a candidate. Emit lengths 0, 1, 2, 3 and the sniff width.

## Step 4 — Axes

* **Options.** One corpus scored 3659 edges at default options and **4384 with validation
  enabled, +725 edges from zero new seeds**, +905 across a five-setting sweep. On another
  target, whose only runtime modes were a finalise flag and a string-vs-buffer entry
  point, the whole sweep was worth **1.2 %**. Measure it, then move on.
* **Parallel implementations.** A corpus with ~130 constructs in one encoding and four
  smoke tests in another left a single foreign-encoding sample holding 83 edges alone.
  **Re-emitting 21 representative constructs over two more implementations added 320
  edges from 46 seeds**, the largest single gain measured.
* **Sub-grammars.** On a stylesheet compiler, 65 seeds enumerating the grammar *inside*
  constructs (media-query conditions, `:not()` selector lists, `An+B`, arithmetic with
  significant spaces, unquoted URLs) were worth **958 edges** on top of a corpus that
  already had one seed per directive.
* **Argument depth.** One call each over 74 functions left a 325-edge gap; **60
  argument-variation seeds then added 302 edges inside functions already "covered"**.
* **Crossing axes that select an implementation.** One regex engine was selected only by
  **anchored AND capturing**; a corpus with anchored seeds and a corpus with capturing
  seeds both missed it. One such seed was worth 24 edges that 160 others missed.
* **A name lookup that selects code is an axis, not data.** On a transcoding binding the
  encoding name is looked up in a table of about a hundred and fifty converters, each a
  function pointer of its own, so one family per converter (decode, truncated decode,
  encode, encode with transliteration) is the parallel-implementations axis. Names
  looked up in one table by one loop, by contrast, select nothing.
* **Buffer boundaries.** One library ships a regression fixture whose entire purpose is a
  two-byte character split across its big buffer.
* **A generated parser's dialect is looser than its standard.** One JSON grammar listed
  `comment` in `extras`, making `//` and `/* */` legal **between a key and its colon**;
  its top rule was `repeat(value)`, so `1 2 3` was a valid document. Its escape rule was
  `'\\' + /("|\\|\/|b|f|n|r|t|u)/`, so **`"\u"` is a complete escape with no hex
  digits**. Seeds written from the standard mislabel all of these.

## Step 5 — Author

* **Byte-diff the default record before writing families.** A generator that followed
  every other rule (derived fields, a correctly implemented content checksum, clamped
  writes) still shipped a one-byte header bug that killed 87 of 192 seeds; the byte diff
  located it at a named offset in two lines.
* **The byte diff finds what re-reading the spec does not.** Both bugs found this way on
  one target were a length field with an off-by-one encoding convention (the byte stored
  `(n+1)*4`, not `n*4`) and a size field that had to count a trailing checksum described
  in a different section of the documentation.
* **Reading the byte diff.** It is thirty seconds, and it catches the class of framing
  error that no re-reading of the format does. A difference in an **optional** field (a
  writer that adds sizes or padding to a header by default, a multithreaded encoder's
  flags) is fine when both records decode to the same bytes; a difference in a required
  field is the bug you are looking for.
* **Dependent fields from a plausible constant.** A field that must agree with another
  (a length, a count, a checksum) and is filled with a plausible constant instead of the
  code's own rule silently kills the whole family, because every seed in it fails the
  same check.
* **A generator that imports the package needs the harness's loader interception.** After
  a sanitizer self-test the in-tree artefact is the sanitizer build, and the generator
  dies on a missing sanitizer symbol.

## Step 6 — Validate

* **Per family, not corpus-wide.** A corpus-wide histogram showed 72 successes, 135
  rejections and 41 distinct error values, a perfectly healthy picture, while every seed
  in one family of 15 failed to decode because the generator had reused a fixed payload
  across sizes.
* **Error-recovering parsers never fail.** One returns a tree carrying error and missing
  nodes, so every seed exits 0 and the exit-code check passes on any corpus.

## Step 7 — Compare and minimise

* **Reading alone scores level with or below the baseline, and that is not failure.** 72
  derived seeds scored slightly *under* a 21-seed baseline while finding 78 edges it
  missed and missing 83 of its own. The action is to merge, not replace.
* **A second A-side finds what a weak one hides.** The broken family above stayed
  invisible against a sample baseline (`A-only = 0` throughout) and showed up immediately
  against the harness's own gate corpus: `A-only = 8`, all eight held by one file, which
  named the family.
* **Union, then minimise.** Three corpora for one target measured 1594, 1255 and 1096
  edges and were substantially disjoint, union 1815; pairwise each found 180-480 edges
  the others missed. `minimise.sh` retained 43 of 106 external fixtures and 23 of 55
  samples, and the result subsumed the baseline completely.
* **A small cover is a stop signal.** On one small-surface target **15 of 106 seeds held
  all 123 edges**.
* **Noise floor.** One target was stable at the union level and jittered 21 edges per
  seed; another was byte-identical per seed while the *union* moved by 6. Take the larger
  of the two as the floor.
* **Re-gate on the real corpus, cheaply.** A thousand seeds on the plain variant in the
  default mode is about a minute; gating every seed in every mode on every variant is
  what turned one run into an hour. The oracle's ceiling and a mirroring gap show on
  plain in the default mode, and the cover reaches every edge, so the asan run over the
  cover is enough to prove the other arms. The re-gate is the only check that finds
  fidelity gaps the gate corpus was too small to reach: on one target it exposed a
  library accepting inputs the real stack rejects.
* **The ASAN crasher pass needs a long timeout.** With a 5-second limit on a loaded
  machine the sanitizer's symbolization outran the timeout, no report reached its
  `SUMMARY:` line, and the pass recorded nothing and said nothing; at 90 seconds the same
  pass found 32 ASAN-only crashers. Hence the 30-second default and the `WARN` line for a
  run that exits 86 or on a signal with no `SUMMARY:`.
* **The crasher pass uses the campaign's and the gate's `ASAN_OPTIONS`.** Without the
  allocation ceiling a seed that merely *declares* a huge size aborts with
  allocation-size-too-big and is filed as a crasher it is not. It runs in the default
  mode only, in parallel: a crash only in another mode is that mode's campaign's to find.
* **`AFL_IGNORE_SEED_PROBLEMS=1`, not `AFL_SKIP_CRASHES=1`.** The latter covers crashing
  seeds only and says nothing of hanging ones.
* **A nondeterministic seed can be a crasher.** `nondet.sh` once moved 20 seeds to
  quarantine whose varying results came from the plain harness reading past the end of
  its input: the over-read bug, already in `crashers/`. Hence `nondet.sh` leaves a seed
  that is also in `crashers/` in place and reports it as the bug.
* **Sweep and minimise.** One sweep of 258 single-byte-flip candidates yielded **10
  keepers for +20 edges**.

## Step 8 — The success path

* **The writer closes what reading cannot, when there is an opaque layer.** Of an 83-edge
  gap left by reading alone, driving the library's own compressor across strategies,
  levels and frame flags closed **72**. On a shallow tag-based format, **30 seeds of real
  compressor output added exactly 0 edges** over the generator.
* **Program-shaped inputs need seeds written against the harness's subject.** 37 regex
  seeds written to match the fixed subject added 201 edges that 127 reading-derived seeds
  could not reach.
* **Transplanted blobs.** One fixture held 99 edges because it carried a real colour
  profile plus two metadata blocks; splicing those segments in front of a 16x16 image
  reached the same parsers at a thousandth of the decode cost.

## Step 9 — Cost

* A 71-byte input that renders a 512x512 surface is expensive; a 30-byte sample can be
  as cheap as anything you generate. Early-reject seeds cost several times less than
  decoding ones at the same byte size.
* **When to skip `cost.sh`.** A 10 µs parser against a 900 µs fork+exec startup: the
  per-exec ranking is noise, so time the call in-process instead.
* Reference end-to-end result on a target with hand-written in-tree parsing: seed
  coverage 429 to 677 edges, converged 659 to 732, distinct crash sites 7 to 10, three
  crashes that reproduced the moment the files were written. On a thin shim over a
  mature library with good fixtures: 1.02x; borrow a corpus and sweep options instead.
