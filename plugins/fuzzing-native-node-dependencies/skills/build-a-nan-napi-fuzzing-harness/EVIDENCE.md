# Evidence behind the rules in SKILL.md

Not loaded with the skill — this is the audit trail. If a rule in SKILL.md or in
`references/` looks wrong, this says which target produced it. The long form of each
rule, with its case, lives in `references/`; SKILL.md states the rule in a line.

Targets the rules were learned on: a stylesheet-compiler binding, an image-decoding binding,
a SAX XML-parser binding, a tarball-vendored compression binding, an image-processing binding
over system codec libraries, a regex-engine binding, a streaming compression binding with a
shared decoder context, a parser-runtime binding that loads a separate grammar addon, a
block-compression binding, and a DOM XML-parser binding. The resource scripts were validated
end to end on the SAX XML-parser binding (NAN, library compiled in,
no addon object linked, and the addon-object/stub path) with `build_addon.sh`,
`link_harness.sh`, `gate.sh`, `detect_selftest.sh` and the corpus skill's scripts.
Every script was then run end to end by the five evaluation runs below, and `smoke.sh` on
the image-decoding binding's zig build.

| rule in SKILL.md | target that produced it | what was measured |
|---|---|---|
| `afl-clang-fast` drops the runtime from `-shared` links | a stylesheet-compiler binding | `ERR_DLOPEN_FAILED: undefined symbol: __afl_area_ptr`; fixed with `LINK=clang++ LIBS=...rt.o` |
| `LIBS=` replaces rather than appends, and the AFL check passes anyway | an image-decoding binding | 4 DT_NEEDED instead of 18, 113 unresolved symbols, `dlopen` fails |
| node dies under the forkserver inside a dlopened addon | reproduced with a 12-line N-API addon | refuted a threading hypothesis with a C control at 9241 execs/s |
| `AFL_MAP_SIZE` too small segfaults afl-fuzz itself; it differs per variant, so ask each binary | a stylesheet-compiler binding: 70411 plain vs 197446 ASAN (~3x); but the SAX XML-parser binding 7686/7680, the tarball-vendored compression binding 1957/1978, the regex-engine binding 33103/33271, the image-decoding binding 2700/2823 and its zig build 56406/57727 -- roughly equal. No fixed ratio holds | measure every variant |
| `CC.target ?= $(CC)` — configure only bakes if CC was exported | an image-decoding binding (`?=` confirmed) vs a tarball-vendored compression binding (ignored `make CC=`) | the two cases differ by whether CC was exported at configure time |
| hand-written glue does not guarantee a binding-free function | a SAX XML-parser binding | its buffer-parse method takes `Local<Object>`; nine handlers only emit into V8 |
| a fourth layer: what the binding does around the boundary | an image-decoding binding | the post-decode setter the binding calls after the boundary sets width/height for 2 of 5 formats; first harness reported `w=0 h=0` |
| private fields need the explicit-instantiation trick | an image-decoding binding | four fields (surface, data, data length, SVG handle) are private; patching the header would unpublish the object |
| a gate mismatch can be the target's own OOB read | an image-decoding binding | the PNG stream reader gets no buffer length; 4-byte input over-reads, reproduced in a pristine build |
| uninstrumented back ends invert the baseline rule | an image-decoding binding | empty 19 tuples, full decode 24, garbage 61 |
| a missing `-dev` package silently removes a decoder | an image-decoding binding | the GIF library's `-dev` package absent -> `HAVE_GIF` undefined -> GIF branch dead, build succeeds |
| prebuilds can be the wrong architecture | the grammar addon of a parser-runtime binding | `linux-arm64` file was an x86-64 ELF, byte-identical to the x64 one |
| a prebuilt is an asset: gate against it | a regex-engine binding | prebuilt was GCC 10/Debian vs clang 21 harness; 42/42 seeds matched |
| peer ranges pin you to a version needing an older node | a parser-runtime binding that loads a separate grammar addon | the grammar's `peerOptional` range on an older runtime minor makes npm refuse the current runtime with ERESOLVE |
| the input delivery layer can live in JS | a parser-runtime binding that loads a separate grammar addon | its parse method takes a JS input callback; offsets are UTF-16 code units; 32768-unit staging buffer |
| dispatch can live in JS, with an attacker-declared allocation | a streaming compression binding with a shared decoder context | fast path allocates the declared total before decoding a byte |
| mirror handler sets and their return values | a SAX XML-parser binding | nine handlers; unknown-encoding handler's return value gates the path |
| persistent vs fork must be measured per target | an image-processing binding over system codec libraries (60 %, slower) vs a tarball-vendored compression binding (4.5x at 100 %) vs a regex-engine binding (93.8 % vs 100.00 %) | change one variable at a time |
| `-m` cannot be combined with a sanitizer build | a streaming compression binding with a shared decoder context | `The current memory limit (4.00 GB) is too restrictive`; fork server signal 6 |
| `pgrep -c ... || echo 0` yields "0\n0" and never terminates | this session's own waiters | two loops span 20 s apart indefinitely |
| `gate.sh` check 5 could never fail | review of the scripts | stderr was sent to /dev/null in check 1, so the stub marker was discarded; the exit status also ignored `MIN_ARMS` |
| `gen_stubs.sh` stubbed library symbols | review of the scripts | unanchored `4node` matched `lib::node::foo` and `std::vector<foo::node>`; now matches namespace tokens on demangled names and excludes symbols defined in the linked set |
| NAN addons reference a C-linkage node symbol | a SAX XML-parser binding, linking its glue object | `undefined reference to node_module_register`; neither the `napi_` nor the mangled pattern covered it |
| `detect_selftest.sh` missed SIGTRAP and could clobber the source | review of the scripts | PASS list lacked rc 133 (ASAN on aarch64); the restore trap was installed before the backup copy |

## Evaluation runs (2026-10-02): six clean clones, six fresh agents, skills followed as written

| target | model | harness: start to self-test pass | corpus | what it taught |
|---|---|---|---|---|
| an image-decoding binding | Sonnet | 5.0 min | 4.9 min | HEAD has no binding.gyp (zig); `LIB` mandatory but no library object exists for a system-library binding; addon source dir missing from lifted flags; oracle prebuilt bundles its own builds of its image codecs |
| a SAX XML-parser binding | Opus | 4.2 min | 6.1 min | glue at package root, `SRCDIR` guess picked `lib/`; lockfile pinned an old nan; AFL++ 4.x refuses `ASAN_OPTIONS` without `abort_on_error=1`; `err` must be a token, not a number |
| a tarball-vendored compression binding | Sonnet | 5.0 min | 4.7 min | command-line `LIBS=` leaks into the gyp action's sub-make; `.o`-only clean breaks libtool deps; no `ADDON_CXX` for node-addon-api 3.x; archive outside build/Release |
| a regex-engine binding | Opus | 5.3 min | 13.0 min | NAN, not node-addon-api; relative `ADDON=` path fails silently in the gate; composite boundary; `sweep.sh` tag too long for a 5 KB subject |
| a streaming compression binding with a shared decoder context | Sonnet | 3.5 min | 11.6 min | **`FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION`** injected by afl-clang-fast compiles the library's dictID check out: 15-seed gate clean, 630-seed gate `mismatched=50`; JS-side dispatch; attacker-declared allocation must fail the same way on both arms (later: an invented cap rejected inputs the package accepts, so the templates now mirror node and cap only on opt-in); shared decoder context makes persistent mode 53 % stable |
| the image-decoding binding's next major version (a zig build) | Opus | 13.4 min incl. zig install and wrapper build.zig | 4.5 min | no binding.gyp: route 3b through zig's build graph with `wrapper_build.zig`; `afl_shim.h` lacked the three testcase macros so persistent mode silently compiled out; the image-surface class takes an optional env and is binding-free without one; every decoder instrumented (text shaper 38521 guards, 2D renderer 26041, JPEG codec 12163 ...); two real heap overflows reproduced on the real stack |

## Rerun (2026-10-03): same four clones, models swapped, revised skills, four agents at once on one host

| target | model | harness | corpus | gate / self-test / smoke | what it taught |
|---|---|---|---|---|---|
| a SAX XML-parser binding | Sonnet | 5.1 min | 26.6 min | 925 agreed + 1 oracle-limited / PASS / PASS | `SOFT_DROP=out_hash` alone is a trap: a U+FFFD substitution changes `out_len` too, and a lossy test on the final string misses one inside an event name; `LD_PRELOAD` in front of `gate.sh` gives `rc=86` with an empty message; the serial gate took 3.5 min per 926 seeds |
| a regex-engine binding | Sonnet | 14.2 min | 69.4 min | 1331 agreed + 1 oracle-limited, 6 modes / PASS / PASS | six entry points behind `MODE=` and no mode loop in any script cost ~30 min; `build_addon.sh` called a library compiled into the addon's own target "a system .so"; an addon object with zero binding refs makes check 5 vacuous |
| a tarball-vendored compression binding | Opus | 10.1 min | 15.0 min | 364/364, 2 modes / PASS / PASS | `gen_stubs.sh` skipped the package's own methods pulled in by an inline helper (`undefined reference to <pkg>::Stream::method`), fixed by `NAMESPACES=`; glue grep missed `napi.h` included via `.hpp`; the out-of-tree REBUILD was one line of prose; `ADDON_CXX=g++` strips coverage from linked addon objects |
| a streaming compression binding with a shared decoder context | Opus | 8.3 min | 18.1 min | 423/423 plain, 3 modes; asan only with `allocator_may_return_null=1` / PASS / PASS | the gate's default `ASAN_OPTIONS` lacked the campaign's allocation ceiling, so declared-size seeds were no-output and filed as crashers; the self-test seed must take the faulted DISPATCH branch, not just the function; a package bug (truncated undeclared-size frame poisons the shared context) reproduced on the real stack |

Hit by all four: no `MODE=` iteration in `gate.sh`/`smoke.sh` (added), `npx node-gyp` absent
with npm's bundled copy unmentioned (now resolved by `build_addon.sh`). No skill script needed
patching in any of the four runs. Times grew against the first run because every agent
harnessed several entry points (1 each before) and the host was shared four ways; on the one
equal-scope comparison the harness phase was unchanged (5.1 vs 5.6 min). Testing the new
`smoke.sh MODES=` afterwards found a latent bug: `read` with `IFS=$'\t'` collapses an EMPTY
manifest field (a mode row without an `:entry`), shifting every later column; fixed by reading
with a non-whitespace separator.

### Re-check after the budget rules (2026-10-03, later): the regex-engine binding again, both models

| model | harness | corpus | modes | final edges | notes |
|---|---|---|---|---|---|
| Sonnet | 9.1 min | 9.4 min | 3 (default, buffer input, replace) | 4812 / 5355 three-mode union | the earlier six-mode Sonnet run took 14.2 + 69.4 min for 5370; the budget rules were followed and the skipped entry points named |
| Opus | 11.6 min | 7.2 min | 3 (default, flags, set) | 4264 / 4840 union | T4-T5 was 7.4 min: a third mode added after the first smoke, two self-test failures on the REBUILD quoting advice |

Both hit the same three things, all introduced or left by the morning's edits and fixed since:
the REBUILD quoting advice (single-quoting a `$(find ...)` hands `eval` a literal; expand
first, then quote), `sweep.sh` passing `NO_RESULTS=1` so `validate.sh RESULTS=` had nothing to
read, and `rebuild_asan.sh` discarding the build log the self-test shows on failure. Also:
the `LIB=` example sweeps up the addon's own objects when the library is compiled into the
addon's target (now says to name the vendored subtree); `find_boundary.sh` printed basenames,
so two `match.o` from different targets were indistinguishable (now prints paths); failed
self-test diagnostics were written into the package's submodule (now into the workspace);
`errenum_template.c` kept a pointer into a C++ temporary (now copies the string).

### Second re-check (2026-10-04): the streaming compression binding with a shared decoder context, both models, budget rules + handoff contract

| model | harness | corpus | modes | final edges (union) | notes |
|---|---|---|---|---|---|
| Opus | 9.7 min | 5.2 min | 2 (decompress, compress) | 739 / 1769 | 5 of the 9.7 min were re-running gate, smoke and self-test after adding the second mode (the budget text said "default first, then add"), plus chasing 5 smoke crashes filed STATE that reproduce single-shot on the persistent binary |
| Sonnet | 4.7 min | 8.2 min | 2 (same) | 839 / 1848 | fastest harness phase on this target; found the shared-context package bug independently |

Both used the new contract: `real_harness.mjs` ENTRIES keyed by MODE value (`{default, compress}`),
modes decided and named, skipped entry points listed. Both hit the global `MIN_ARMS` on a
compressor mode (now `MODES="MODE=compress:min_arms=1"`); Opus found `smoke.sh` calling a crash
STATE when it reproduces single-shot on the PERSISTENT binary but not the fork one (now its own
class, `PERSISTENT-ONLY`, a warning with the sanitizer site; on re-test 70 such crashes in 20 s,
all in the Huffman encoder's `*_compress*X_repeat`, cause unknown); the mode-budget text now says
to decide the modes before the first gate. Also from these runs: node's own tokens
(`ERR_OUT_OF_RANGE`, `ERR_MEMORY_ALLOCATION_FAILED`) and `-DNODE_KMAXLENGTH=$(node -p ...)` are
in the templates; the self-test's restore relink counts as a harness change (re-gate asan).

### A password-hashing binding (2026-10-04): a new shape, both models

Three native files compiled into the addon's own gyp target, node-addon-api with AsyncWorkers,
a two-argument API (salt, password) and an input-chosen cost exponent. Opus 6.9 + 3.7 min,
Sonnet 3.2 + 5.3 min; both linked the two library objects only (0 refs vs 39), both took the
hash entry point plus the cheap rounds parser as modes, both PASS everywhere, both left the
tree clean. Both found the same package bug through the gate: an invalid base64 character in
the salt leaves part of a 16-byte stack buffer uninitialised and the returned hash carries
those bytes -- stable per arm, different between arms, invisible to ASAN, named by an MSan
build in one run. Changes: `oracle-ceiling.md` and step 5 now say ASAN does not see
uninitialised reads and give the MSan recipe and the per-input `lossy` rule; step 4 has
"attacker-chosen work" (`WORK_CEIL`, mirrored on both arms, and an unbounded work factor as a
finding) beside attacker-declared allocations; the "wrong tool" rule moved to step 1 and
says an input-chosen cost is not a reason to stop; step 4 says how to frame several byte
arguments in one file; the real-harness template awaits an async arm; the file says to read
it with a file reader (38 KB; two Sonnet runs lost its tail to `cat`).

Hit by every target (2026-10-02): writing the REBUILD script by hand (and, at the time, the corpus skill's `measure.sh` not writing `.results` above 150 seeds, since fixed).
Hit by three or more: the ASAN fuzz command rejected by AFL++; the pristine variant built and never used; the "ASAN map ~3x" claim; a boundary that is a method of an ObjectWrap class.

## The smoke check (`resources/smoke.sh`)

| rule in SKILL.md | how it was established |
|---|---|
| run the harness briefly before the campaign, not only the gate | **[carried]** an image-decoding binding: a `memset`-zeroed image object made every decode *error* path crash inside `std::string` -- 43 phantom SIGSEGVs in 15 s of fuzzing -- while valid inputs worked, so the gate (mostly valid seeds) passed it. Nothing in the skill ran the harness on error paths before the campaign; the old `triage.sh` caught it only afterwards, in a pile of crashes |
| classify by the innermost project-source frame, not the top frame | **[measured]** synthetic harness with one planted bug of each kind: a bug in `harness_glue.c` was `HARNESS-FRAME` (`glue_prepare @ harness_glue.c:5`), a bug in the library `REAL` (`lib_parse @ lib.c:6`), and the exit status was 1 |
| the real-stack comparison catches what frames cannot | **[measured]** same synthetic harness: a harness that hands the library an unterminated buffer crashes in *library* code (`lib_parse @ lib.c:7`), so no frame test sees it; only the real stack, which terminates its buffer, showed it was `DIRECT-ONLY` |
| the real side must run the same sanitizer options as the direct side | node under ASAN prints a LeakSanitizer `SUMMARY: AddressSanitizer: N byte(s) leaked` at exit; the `Sanitizer:` test read it as a crash until `detect_leaks=0` was passed to the real run |
| a variant with no sanitizer needs its crashes re-run on a sanitized one | **[measured]** the image-decoding binding's next major version (a zig build), plain build: two crashes classified `REAL` at `? @ ?:?` (no stack); re-run on the ASAN fork harness they resolve to one source line in the PNG stream reader, so the harness-frame test can run on them |
| works on a real harness and the real npm stack | **[measured]** the image-decoding binding's next major version (a zig build) with `real_harness.mjs` under ASAN: 4 crashes, all `REAL`, all in the PNG stream reader; 52 s end to end. Its stability 97.6 %, 357 execs/s under ASAN and 1,810/s plain |
| bound the smoke run by wall-clock too | **[measured]** AFL's `-V` is fuzz time only: a plain smoke run on the image-decoding binding with `-V 40` ran **268 s** once it had saved a hang, so a "short" check took 5 minutes. `campaign.sh WALL=` stops it and records `walled`; `smoke.sh` passes `3 * SMOKE_S + 30` |
| `triage.sh` / `classify.sh` removed | the real-stack comparison moved into `smoke.sh` (before the campaign); deduplication is the triage skill's, which fixed bugs they still had (single-pass template collapse, AFL's `README.txt` read as a crash, no timeout) |

## Review of the skill (2026-10-07): checks moved from prose into the scripts

A read-through of SKILL.md, the references and every resource against the chain contract.
Nothing new was learned on a target; the changes make existing rules falsifiable by a script
or remove text the scripts already enforce. Tested in the `sectainer-ruby` container on the
binaries of past runs plus fabricated harnesses, so the tags are [tool] and [measured] on
synthetic cases, never on a new target.

| change | tag | what was checked |
|---|---|---|
| `link_harness.sh` and `smoke.sh` fail when `out/<v>/harness` lacks `##SIG_AFL_PERSISTENT##` or `harness-fork` carries it | **[measured]** | the persistent binaries of past runs carry the string and their fork twins do not; a persistent binary without it (the zig-shim case above) and a persistent binary copied over `harness-fork` are both refused. Until now the only guard was a sentence in step 3b |
| `gate.sh` judges NO-OUTPUT on "no line with a `status=` key", and `get()` reads keys from that line only | **[measured]** | fake harnesses: stdout that is only logging is NO-OUTPUT with the new message (before: a MISMATCH with every key empty); a seed with stray `err=` and `status_x` logging lines agreed because keys came from the result line. Same test smoke.sh's HOSTSAN preflight already used |
| `gate.sh` names rc=124 contention when fewer than three seeds have no output | **[measured]** | one asan gate run reported `no-output=1` while other campaigns shared the host; two re-runs were clean. (The comment in `gate.sh` said "measured" before this file did) |
| `gate.sh` ends with a `PASS:`/`FAIL:` verdict line in default-only mode too | **[tool]** | piped through `tee` the exit status is lost; the multi-mode path already printed one |
| `detect_selftest.sh` default `ASAN_OPTIONS` carry `allocator_may_return_null=1:max_allocation_size_mb=$ALLOC_CAP_MB` | **[tool]** | the self-test was the one step outside the chain's single allocation ceiling (README conventions) |
| `detect_selftest.sh` runs the harness under `timeout 60` in `run()` and in the automatic seed pick; rc=124 is named as a hang in both FAIL messages | **[tool]** | a fault that sends the library into a loop hung the script indefinitely before |
| `real_harness_template.mjs` dies `ADDON-NEVER-LOADED` when the package answered without dlopening any addon | **[tool]** | a package that rejects in JavaScript before loading its addon lazily printed `ADDON-NOT-SWAPPED`, whose hint points at a wrong path. Still no result line, so the swap proof is unchanged |
| both `harness_template.cc` copies: keep `status` below 64 | **[tool]** | `smoke.sh` reads 86 and anything above 127 as a crash, the gate reads 124 as a timeout |
| SKILL.md description names node-gyp, `binding.gyp`, prebuilt `.node`, what the skill proves, and the chain | **[tool]** | triggering vocabulary; the campaign skill's description already carried the chain pointer |
| SKILL.md: prefer the published tarball (`npm pack`) over a clone as the build tree, state both versions in the write-up | **[carried]** | from the Ruby sibling, where a clone lacked sources a release step generates; the Node skill already met the symptom (a `prepare` step running `tsc`). Not yet seen to matter on a Node target |
| SKILL.md: the self-test runs in the current environment, so export `MODE=` for a fault on a mode-only path | **[tool]** | `detect_selftest.sh` never applied a mode; the text did not say so |
| SKILL.md trimmed from 40.0 to 39.0 KB: allocation/work-ceiling long form to `four-layers.md` layer 2, REBUILD out-of-tree recipe and zig REBUILD to the new `selftest-rebuild.md`, mode-budget cost anecdotes dropped (this file keeps them) | **[tool]** | every imperative rule stayed in SKILL.md; the three blocks were 4.5 KB, so the file is still above the 30 KB terminal truncation and the read-with-a-file-reader note stays |
| pristine-variant count: "on the evaluation targets" | **[tool]** | SKILL.md said five, this file said three or more |
