# Evidence behind the rules in SKILL.md

Not loaded with the skill — this is the audit trail. If a rule in SKILL.md looks wrong,
this says which target produced it and what was measured. The magnitudes behind each rule
are in `references/measured-examples.md`, organised by step; SKILL.md states the rule in
a line.

Script fixes from review (2026-10-02): `extract_literals.py ALL=1` was a no-op (the `RE` default was
read before `ALL` set it); `error_inventory.sh` hard-coded five past targets' prefixes
(now `PREFIX=`); `measure.sh` now saves `.results` so `validate.sh` and
`error_inventory.sh` do not re-run the harness; `validate.sh` runs the harness once per
seed instead of three times; `sweep.sh` and `gen_template.mjs` are new.

| target | input shape | mode used | seeds | baseline | derived | gap left | what it taught |
|---|---|---|---|---|---|---|---|
| image decoders behind an image-decoding binding | binary containers | generator | 265 | 429 | 677 (1.58x) | — | the source method; 3 crashes before any fuzzing |
| a compression binding (frame format) | binary frames | generator + writer + sweep | 131 | 273 | 387 (1.42x) | 2 | reading alone scored *below* baseline; writer closed 72 of an 83-edge gap |
| a regex-engine binding | text (pattern) | literal seeds | 176 | 3036 | 3538 (1.17x) | 13 (under a 21-edge jitter floor) | engine selected by anchored AND capturing; match-path seeds +201 |
| a SAX XML-parser binding | text + structure | literal seeds + loops | 266 | 1255 | 1815 (1.45x) | 0 | error codes 7/42 -> 20/42; per-encoding re-emission +320; upstream fixtures were C string literals |
| an image-processing binding over system codec libraries | binary, multi-format dispatcher | generator + writer + transplant | 347 | 4594 | 5160 (1.12x) | 1 | 3 decoders had zero sample coverage, each reachable in <=12 bytes; median seed 7757 B -> 167 B |
| a stylesheet-compiler binding | text (language) | literal seeds + loops | 455 (+27 second syntax) | 10618 | 17023 (1.60x) | 205, almost all one second-syntax file | sub-grammars +958; argument depth +302; resolvable imports need on-disk fixtures |
| a DOM XML-parser binding | text + structure | **transferred corpus** + library-specific | 278 | 4474 | 4564 (1.02x) | 465 | transfer gave 97 % of baseline for free; the option sweep was worth +905, more than any seed work; one flag was inert because the binding never calls its API |
| a streaming-compression binding | binary containers | generator + writer | 155 | 565 | 848 (1.50x) | 0 | a broken generator scored 176 before two field fixes took it to 459; the byte diff against the real encoder found both |
| a block-compression binding | binary tags | **generator only** | 76 | 94 | 123 (1.31x) | 0 | the writer added **0** edges: no entropy layer to reach. 15 of 106 seeds covered all 123 edges |
| a parser-runtime binding that loads a separate grammar addon | text (UTF-16 in) | literal seeds + loops | 167 | 933 | 1125 (1.21x) | 0 | the grammar file was the axis list, and its dialect accepted more than the standard; error recovery makes the exit-code check vacuous |
| a multi-codec image binding (system codecs uninstrumented) | binary, 5-way sniffer | generator + writer | 207 | 24 (13 unrelated images, 1 unique map) | 613 | 0 | the only instrumented parsing was the sniffer, an in-tree metadata reader and one in-tree decoder; a second A-side (the harness gate corpus) was what exposed a broken seed family |

---

## Evaluation runs (2026-10-02): five fresh agents following the skill as written

| target | baseline | fixtures | derived | final | what it taught |
|---|---|---|---|---|---|
| an image-decoding binding | 286 | 430 | 678 | 689 | every decoder is an uninstrumented system .so; the in-tree BMP parser and GIF glue were the productive families, the JPEG writer family added nothing; 21 seeds crash the ASAN harness and need a `crashers/` convention |
| a SAX XML-parser binding | 719 | 1171 | 2131 | 2190 | re-emitting the construct list through four tokenizers was +344; the enum route for the error inventory was exact; hash-salt jitter of 4 edges |
| a streaming-compression binding | 634 | 880 | 1001 | 1003 | the best fixtures were inside the vendored library tarball, invisible to `find`; the JS splitter on `YZ` makes a byte pair a corpus axis |
| a regex-engine binding | 3016 | 4058 | 3867 | 4334 | 516 seeds for table-driven Unicode names bought 11 edges; JS regex literals were the dominant fixture form and `extract_literals.py` missed them; the subject is an axis |
| a streaming compression binding with a shared decoder context | 368 | — | 944 | 972 | declared-size family from reading the binding's TypeScript decompress wrapper; the declared-content-size encoding (size-256) broke 22 seeds until `validate.sh` showed one error on all of them; re-gating the final corpus exposed a harness fidelity bug |
| the image-decoding binding's next major version (a zig build) | 3037 | 4504 | 2761 | 5057 | with every decoder instrumented the vendored codecs dominate (the SVG codec ~3345, the JPEG codec ~2198, the PNG codec ~1451); the JPEG success path is reachable only through real files (step 8); hand-assembled GIFs reach the reader and fail, fixtures carry the decode |

## Rerun (2026-10-03): same four clones, models swapped, revised skills

| target | model | baseline | final | corpus phase | what it taught |
|---|---|---|---|---|---|
| a SAX XML-parser binding | Sonnet | 858 | 2301 (926 seeds, cover 397) | 26.6 min, ~14 of them three serial 926-seed gates | the step-7 union snippet shipped every fixture instead of the minimised keepers (fixed); `errenum_template.c` cannot link AFL-instrumented objects (compile the error-string source in); the buffer-straddle axis bought 6 edges because UTF-8 input never uses the transcoding buffer |
| a regex-engine binding | Sonnet | 3153 / 3783 six-mode union | 4605 / 5370 union (1332 seeds, cover 199) | 69.4 min, ~40 waiting on `measure.sh`/`gate.sh` | 6867 extracted literals took 10 min to measure (now parallel; send unminimised sets to `minimise.sh`); literals must be wrapped into the harness's input container; the vendored `testing/` directory held 167 exclusive edges; `A-only` named the missing axis exactly |
| a tarball-vendored compression binding | Opus | 822 / 1040 two-mode union | 1106 / 1343 union (364 seeds, cover 132) | 15.0 min | the tar loop matched the tarball's `.sig`; a byte-diff against a multithreaded writer differs in optional header fields while both decode identically; route 2 of the error inventory (parse the enum) had no script (now a one-liner) |
| a streaming compression binding with a shared decoder context | Opus | 588 | 738 (423 seeds, cover 62) | 18.1 min | `MAX_CODE 64` in `errenum_template.c` was too small and the filler string was not skipped (fixed); the seed-policy ASAN pass filed declared-size seeds as crashers without the campaign's allocation ceiling (fixed); hand-built compressed blocks all died on one size error and the writer could not produce a reference that small |

Script changes from this rerun: `measure.sh` runs seeds in parallel (`JOBS=`), hashes each map
once and writes `.edges` first; `minimise.sh` takes several `HAVE=` directories and `MODES=`;
`cover.sh` unions several `MAPS=` directories; `extract_literals.py` accepts `SRC="a b"` and
fails on a missing file; `errenum_template.c` skips the filler string and documents the build.

## Second re-check (2026-10-04): the streaming compression binding, both models, budget rules

| model | baseline (union) | final (union) | corpus phase | what it taught |
|---|---|---|---|---|
| Opus | 1408 | 1769 (328 seeds, cover 64) | 5.2 min | `minimise.sh` silently accepted a non-existent `HAVE=` (a mistyped `sweep.sh` name) and reported +579 for a seed worth +36 (now refuses); `sweep.sh` always includes the current environment (documented); the error inventory needs a "converted internally" class for inner-layer codes an outer layer maps to a generic one (added) |
| Sonnet | 814 | 1848 (725 seeds, cover 107) | 8.2 min | `measure.sh`'s duplicate list was 480 lines for 725 seeds (now capped at 20 with the full list in `.duplicates`, and marked as current-mode-only); the obvious `*_getErrorName()` took an encoded `size_t`, not the code (template says to check); a JS size pre-check shadowed the library's header errors until an unsized first frame got past it (noted in step 2) |

## A password-hashing binding (2026-10-04): both models

| model | baseline (union) | final (union) | corpus phase | what it taught |
|---|---|---|---|---|
| Opus | 243 | 272 (173 seeds, cover 21: the stop signal fired) | 3.7 min | a 352-edge native surface is the honest answer; the library's fixtures added nothing new |
| Sonnet | 182 | 230 (222 seeds, cover 41) | 5.3 min | `error_inventory.sh` compared raw literals with spaces against `err=` tokens with underscores and reported a miss (now matches the token form too) and read one mode's `.results` (now several); hangs from the input-chosen cost field are the work-factor case the harness skill now bounds |
