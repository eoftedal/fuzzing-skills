# Evidence behind the rules in SKILL.md

Not loaded with the skill -- this is the audit trail. If a rule in SKILL.md or in
`references/` looks wrong, this says which run produced it. Tags: **[measured]** observed
in a run listed here; **[tool]** the installed tool's own output; **[carried]** learned on
the Node sibling plugin (`fuzzing-native-node-dependencies`) and kept because it is about
the C library, AFL++ or the method, not the runtime -- not re-measured on Ruby.

Platform for every run: the `sectainer` image -- Ubuntu 26.04, aarch64 Linux container,
14 cores, Ruby 3.3.8 (distro package), clang 21.1.8, AFL++ 4.33c, bash 5.3. All on
2026-10-06.

Targets:
* **target A, a gem over a system library** (the library as a `.so`):
  tooling development -- builds, stubs, link, real harness swap.
* **target B, a gem with vendored libraries** (a main vendored library, a second
  vendored library, and a vendored library built from a source dir in the gem, all via
  mini_portile2): tooling development, then two independent evaluation runs (Opus, Sonnet)
  of this skill as written, steps 1-6.
* **target C, a gem whose parser is the extension's own C**: one evaluation run
  (Sonnet) of all four skills end to end, with a 5-minute campaign.
* a fabricated fixture gem for the triage verdict ladder (triage EVIDENCE).

## Evaluation runs

| run | target | steps | result | wall clock |
|---|---|---|---|---|
| Opus | B, the gem's default parse call -> the library's parse-from-memory call + its serializer | 1-6 | all passed; gate 36/36 agreed plain and asan; smoke clean (plain 47.8k, asan 18.3k execs/s, stability 97.3-97.7 %); self-test PASS (heap-buffer-overflow, rc=86) | 9.8 min agent time |
| Sonnet | B, same entry, modes `default` + `strict` | 1-6 | all passed; gate 35/35 both modes plain and asan; smoke clean (48-58k / 27-29k execs/s, 96.6-97.1 %); self-test PASS | 7.5 min agent time |
| Sonnet | B, the gem's default parse call, rebuilt from scratch with the fixed plugin | all four skills, 10-min campaign | all passed; gate 39/39 plain and asan; corpus re-gate 597/597; self-test PASS via `rebuild_vendored.sh` (13 s); campaign 6.25 M execs, 0 crashes | 21.5 min container clock |
| Sonnet | C, its parse and load methods (`MODE=load`), from scratch | all four skills, 10-min campaign | all passed; gate 34/34 both modes plain and asan; 9 function stubs (name caches linked); campaign 119 M execs, 16 crashes, all the one known bug | 26.3 min container clock |
| Sonnet | C, its parse method -> the extension's parse function | all four skills | all passed; gate 22/22 then 213/213 after the corpus re-gate; smoke clean (plain 132k, asan 82k execs/s, 98.6 %); self-test PASS; campaign found one real bug | ~17 min agent time, 5 min of it the campaign |

Machine time is small in all three [measured]: gem install ~0.5 min, a variant build
<1 min for target B (47-64 s at 6 jobs, two agents sharing the host) and ~2 s for target
C, a gate 1-10 s, smoke ~30 s per variant, self-test 8-15 s. Writing the harness dominates
(target C: ~12 min estimated, for the shim and recording tree).

## Rules, and the run that produced each

| rule | run | what was measured |
|---|---|---|
| link the extension with plain `clang -shared`, AFL runtime named in `LIBS` | A | `afl-clang-fast -shared` dropped `afl-compiler-rt.o` even when LIBS named it; `ruby -e require` -> `undefined symbol: __afl_area_ptr` [measured] |
| mkmf ignores env `CFLAGS`; use `--with-cflags`, which REPLACES Ruby's CFLAGS | one-line extconf.rb | env `-DENVFLAG` reached neither probes nor Makefile; `--with-cflags=-DARGFLAG` reached both and removed `-g -O2` [measured] |
| silence clang's warnings on ruby.h; compare probes with the oracle (`ORACLE=`) | B | under clang 21, `ruby.h` warns `-Wdefault-const-init-field-unsafe`; every `-Werror` probe failed; the source-dir library's `-I` was rejected and the build died on its header; after the fix, 22 probes identical to the gcc oracle's [measured] |
| delete mini_portile markers, not only directories | B | with `ports/*.installed` left, "Activating <library> ... (from ports/...)" with no compile, then a library function reported missing [measured] |
| snapshot vendored archives, headers and recipes before `make`; rewrite the snapshot Makefile | B; both B evaluation runs | the gem's cleanup deletes `ports/` after the link: both vendored `.a` archives gone; both evaluation runs then failed on the main vendored library's version header not found and on `LIBS_FROM_MK=1` with a missing archive [measured]; after the fix the Opus harness linked with neither workaround |
| keep tarballs outside the tree (`OUT/vendor-archives`) | Opus run | the asan build silently re-downloaded both vendored libraries [measured]; after the fix, 0 downloads |
| `rebuild_vendored.sh` for the self-test of a vendored library | both B runs | each spent ~2-3 min extracting, patching (6 patches) and configuring the main vendored library by hand; the helper does it in 12 s with 129 coverage symbols, and the documented REBUILD route gives PASS (heap-buffer-overflow) in 10 s [measured] |
| per-archive coverage check; skip `test*.a` and recipe build trees | B | the four vendored archives: 129, 57, 27, 51 sancov symbols; the library's own test archive and duplicate copies from `tmp/` had been picked up [measured] |
| stub exactly what libruby exports; data symbols as PROT_NONE pages | A | 62 function + 3 data stubs (`rb_cObject`, `rb_eNoMemError`, `rb_eRuntimeError`); the extension's `Init_` function from the harness traps at `rb_ext_ractor_safe` [measured] |
| data stubs in a read-only segment | A | in `.bss`, LeakSanitizer scanned the PROT_NONE page at exit and every clean ASAN run died with "LeakSanitizer has encountered a fatal error" [measured] |
| shim for an extension whose parser is its own C | C | the extension's parse function calls `rb_ensure`, `rb_block_given_p`, `TypedData_Wrap_Struct` unconditionally; with a shim for those, 3 stubs left (`rb_raise`, `rb_yield`, `rb_gc_mark`) and gate 213/213 [measured, eval run] |
| `rb_enc_find` of an unknown name is ASCII-8BIT, not NULL | C | the corpus re-gate mismatched on unknown encoding names until the shim returned index 0 [measured, eval run] |
| ask the runtime for TABLES too (`gen_enc_table.rb`) | Opus run; C | target B's serializer: `Encoding.find("UCS-4")` and `("ebcdic-us")` raise ArgumentError although the main vendored library accepts them [measured] |
| the load check may have to go through the gem's own require | C | standalone: "cannot load such file -- <gem>/version"; with lib/ on the path: "uninitialized constant" for a constant in the gem's namespace; the gem-style fallback loads it and the maps check passes; a wrong `REQUIRE=` fails [measured] |
| include `ruby.h` first, outside `extern "C"`; `#undef snprintf/vsnprintf` | C | `templates must have C++ linkage` from stdalign.h; `undefined reference to 'ruby_snprintf'` [measured, eval run] |
| real harness: swap through require AND require_relative, prove it from /proc/self/maps | A; B source | target B tries `require_relative "3.3/<ext>"` before `require "<gem>/<ext>"`; a non-matching EXT_MATCH is refused with EXT-NOT-SWAPPED because the gem's own extension `.so` is mapped [measured] |
| ruby under ASAN: `use_sigaltstack=0` | A, fixture | every Ruby thread exit: "AddressSanitizer: CHECK failed ... unable to unmmap" (Ruby's malloc'd signal stack munmapped as ASAN's); plain C pthreads under the same preload are fine [measured] |
| small input Strings are invisible to ASAN on the Ruby side | Ruby 3.3 | `ObjectSpace.dump`: Strings shorter than ~616 bytes are embedded in the GC slot, from `File.binread` and from `String.new(capacity:)` alike [measured] |
| allocation failure is NoMemoryError, not StandardError; size beyond C API -> ArgumentError | Ruby 3.3 | under `ulimit -v`: NoMemoryError "failed to allocate memory"; the "negative string size (or size too big)" message is in libruby; `String.new(capacity: 2**40)` SUCCEEDED (overcommit) [measured] |
| recovering parsers reject almost nothing | both B runs | with recovery on, only 1-2 of 35-36 seeds took the error arm [measured]; the template's default arm no longer passes `strict` |
| `lossy` set at the transcoding step, never from the output's content | Opus run | the template's "contains U+FFFD" test would hide real mismatches on documents containing U+FFFD [measured, eval run] |
| hash `.b` bytes | Opus run | `+` on a UTF-16 (dummy encoding) serializer output raises Encoding::CompatibilityError [measured] |
| `lift_flags.sh`: shell-split, drop string macros with spaces/quotes | both B runs | a `-D<GEM>_PATCHES="..."` string macro cut at a space: `missing terminating '"'` on every compile [measured]; the token-wise filter also dropped `-include`'s argument |
| `gate.sh` always prints PASS/FAIL | Opus run | with no MODES only the exit code said it, lost under `| tee` [measured]; fixed in both plugins |
| self-test staleness: no action needed | both B runs | `selftest.txt` 11-13 ms newer than the relinked harness; bash `-nt` compares nanoseconds [measured] |
| `FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION` undefined for AFL variants | Node sibling | a compression library compiled its dictionary-id check out [carried] |
| a 1-byte over-read into a larger buffer fires nothing; anchor `FAULT_SED` to the function | Node sibling | [carried]; both self-tests here placed the fault past the allocation and passed |
| the four layers, the oracle ceiling order, check 4 (coverage) | Node sibling | [carried]; layer 3 (allocator hooks: target B routes the vendored library's allocator to `ruby_x*`) was mirrored with malloc in both B runs and the gate agreed |
| `SHIM=` in `link_harness.sh` | C 10-min run | the agent had to write its own shim-compile and link wrappers; linking its shim through `SHIM=` gives 9 stubs and byte-identical results on all 34 gate seeds [measured] |
| `#undef` ruby.h's function macros before defining them in a shim | C 10-min run; Ruby 3.3 headers | `rb_str_new` etc. failed with "expected ')'"; the preprocessor shows 16 such macros (rb_str_new*, rb_utf8_str_new*, rb_usascii_str_new*, rb_enc_str_new*, rb_exc_new_cstr, rb_intern, rb_intern_const, ...) [measured] |
| `rb_intern` raises EncodingError for any byte >= 0x80 | C runs; Fiddle | `rb_intern("caf\xC3\xA9")` and `("\xff")` raise "invalid symbol in encoding US-ASCII"; `"\xff".force_encoding("US-ASCII").to_sym` does not [measured] |
| `enc_names[]` ends in a sentinel: loop to it, not over sizeof | B 10-min run | a sizeof loop passed NULL to strcasecmp: NO-OUTPUT rc=139 on unknown encodings [measured, eval run] |
| `err=` defaults to the exception class, not the message | C 10-min run | the gem's namespaced exception class's message embeds line and column, unique per seed [measured] |
| normalise `__FILE__:__LINE__` out of messages (gcc oracle vs clang variant) | C 10-min run | target C's `[<file>.c:N]` in messages differed by 3 lines for a multi-line call: 5 of 291 derived seeds mismatched, invisible to the 34-seed gate [measured, eval run] |
| probe comparison falls back to `gem_make.out` | C | target C's extconf.rb ends with `make clean`, deleting mkmf.log; `gem_make.out` vs `build.log`: 8 probes match [measured] |
| a lone NO-OUTPUT rc=124 on a loaded host: re-run first | C 10-min run | one asan gate run reported no-output=1 under contention; two re-runs clean [measured, eval run] |
| SKILL.md does not quote earlier findings | C 10-min run | the agent read "3 stubs left" and "8 crashes -> 1 bucket" as expected outcomes; its own 9 stubs looked wrong although they were fine [measured, eval run] |

## Review corrections

Mistakes made while writing this skill that the runs above caught; each is easy to
reintroduce.

| what was believed | what a run showed | fix |
|---|---|---|
| `extern "C" T x[N];` defines the data stubs | a declaration in C++: every data stub undefined at link | `extern "C" { ... }` block |
| `-newer build.log` finds this build's archives | build.log is appended during make, so it is always newer | a stamp file before extconf.rb |
| `read` with tab separators keeps empty fields | IFS whitespace collapses them: the source-dir library's configure options landed in its patches field | `\037` separator |
| tarballs in `ports/archives/` survive | target B deletes them | `OUT/vendor-archives` |
| the documented swap check covers the sanitized columns | a crashing cell exits before reporting its swap | liveness run per sanitized column (triage) |
| a fixture over-read proves the ASAN column | clang -O2 deleted the malloc/free pair and the read; the row read CLEAN | keep the pointer opaque (`asm volatile`) |

## Shared-script changes mirrored from the Node review (2026-10-07)

Made identically in both plugins (`scripts/check_shared.sh`: 0 drift). Checked in the
`sectainer-ruby` container on the binaries the runs above left behind and on fabricated
harnesses; none was run against a new gem.

| change | tag | evidence |
|---|---|---|
| `link_harness.sh` and `smoke.sh` fail when `out/<v>/harness` lacks `##SIG_AFL_PERSISTENT##` or `harness-fork` carries it | [measured] | the persistent binaries of the runs above carry it and their fork twins do not; one scratch workspace's persistent binaries lack it and are now refused; a persistent binary copied over `harness-fork` is refused |
| `gate.sh` judges NO-OUTPUT on "no line with a `status=` key" and reads keys from that line only | [measured, synthetic] | fake harnesses whose stdout is only logging are NO-OUTPUT; stray `err=` lines no longer supply a key |
| `detect_selftest.sh`: `ALLOC_CAP_MB` in the default `ASAN_OPTIONS`, `timeout 60` in `run()` and in the seed pick, rc=124 named as a hang; header says to export `MODE=` for a mode-only fault | [carried] | the Node review; the Ruby self-tests above never hit a hang or a declared allocation |
| `harness_template.cc`: keep `status` below 64 | [carried] | `smoke.sh` reads 86 and >127 as a crash |
