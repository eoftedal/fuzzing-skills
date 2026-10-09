# The campaign's dictionary: what goes in it, and why

SKILL.md step 7 ends with `$RC/dict.sh`. This is the reasoning behind it and a worked
example, to read when you are deciding what to put in `TOKENS` or a dictionary seems to
add nothing.

## Why mutation needs it

afl-fuzz flips bits, replaces bytes with interesting values and splices inputs. A branch
that compares four or more bytes at once (`memcmp(p, "IEND", 4)`, `strcmp(name, "utf-16le")`)
gives coverage feedback only once every byte matches, so mutation has no gradient towards
it and almost never assembles the token by chance. A dictionary entry is inserted or
overwritten whole, so the token arrives in one step. A seed carries a token in one place;
the dictionary lets the fuzzer put it anywhere.

## AFL dictionary syntax

One entry per line, `name="value"` (the name is optional: `"value"` alone is valid), with
`\xNN` for any byte that is not printable and `\"` / `\\` for the quote and backslash;
lines starting with `#` are comments.

## What the build-time pass sees, and what it does not

`build_ext.sh` and `link_harness.sh` compile with `AFL_LLVM_DICT2FILE`, so every variant
build writes `out/<variant>/dict.afl`: the constant operands of string and memory compares
(`strcmp`, `memcmp` and relatives) and of integer compares and `switch` cases, in every
file afl-clang-fast compiled (the extension's library code, vendored archives built by
mini_portile, which inherit the variable, and `harness.cc`).

It does not see:

* **Code afl-clang-fast never compiled**: a system library linked as a `.so`, a 3b archive
  built without exporting the variable (the harness skill's `build-traps.md`, 3b), the
  shim (compiled plain), libruby, and every Ruby file. A `lib/**/*.rb` that picks the
  native method from a keyword (`case opts[:format] when "strict"`) holds tokens that select
  native paths; `SRC=` harvests them.
* **Names in a table.** A loop `for (i...) if (!strcasecmp(name, tbl[i].name))` compares
  against a table entry, not a constant at the call site, so none of the names is recorded.
  This is the commonest gap: every name that selects a different converter, handler or
  sub-parser goes in `TOKENS`.
* **Comparisons the code does not spell as one**: a hand-rolled byte loop, a hash of the
  token compared to a precomputed hash (a perfect-hash keyword lookup), a `switch` on the
  first byte followed by a compare of the rest.
* **The harness's own framing.** A separator found with `memchr` is not a comparison: the
  framing documented at the top of `harness.cc` (the NUL between an option string and the
  document, a length prefix's typical values) goes in `TOKENS`.

## What to put in TOKENS

* the framing separators documented at the top of `harness.cc`;
* every `MODE` value and every option value the harness frames into the input (an option
  string, an encoding name), including one the code rejects;
* the names in any lookup table whose entries select code (converters, handlers,
  sub-parsers); names that one loop looks up as data are worth less (SKILL.md step 4,
  constants axis);
* a grammar's keywords and operators, including the multi-byte ones (`<![CDATA[`, `-->`,
  `::`, `**=`) and the case variants the lexer accepts.

`TOKENS_FILE=` takes a longer list, and a token with spaces or control bytes; `dict.sh`'s
header gives both forms' syntax. `SRC=` harvests string literals by regex, capped at
`MAXLEN=` (32) bytes; keep it to the files that hold the tokens. afl-fuzz uses at most
`MAX_DET_EXTRAS` (256 in AFL++'s `config.h`) entries in its deterministic stage and the
rest only at random, so a dictionary of thousands of harvested strings dilutes the ones
you chose. `dict.sh` refuses to write an empty dictionary.

## Worked example: a converter selected by name

A harness frames `<encoding name> NUL <document>`, and the library looks the name up:

```c
static const struct { const char *name; conv_fn fn; } convs[] = {
  { "UTF-8", conv_utf8 }, { "UTF-16LE", conv_utf16le }, { "ISO-8859-1", conv_latin1 },
  { "SHIFT_JIS", conv_sjis }, ...
};
for (i = 0; i < N; i++) if (!strcasecmp(name, convs[i].name)) return convs[i].fn;
```

`out/plain/dict.afl` holds none of those names (they are table data), but it does hold the
document parser's own magic bytes and keywords. The step:

```sh
cd $W && . ./fuzz.env
$RC/dict.sh OUT=./dict.afl TOKENS="UTF-8 UTF-16LE ISO-8859-1 SHIFT_JIS x-unknown" \
    SRC="lib/**/*.rb"
grep -c . dict.afl        # entries; then read it once
```

The NUL separator is a control byte, so it goes in `TOKENS_FILE=`. Each converter is a
different parser of the same bytes, so with these entries a mutation can swap the name
in front of any document and reach a converter no seed named.

## Where it goes next

`campaign.sh` passes `afl-fuzz -x` with `$W/dict.afl` by default, else the variant's
`out/<variant>/dict.afl`; `DICT=none` disables it, and the manifest's `dict` column records
which file each campaign used. The harness skill's smoke run picks the same default.
Whether a dictionary raises coverage on your target is not measured in this plugin: a
short campaign with `DICT=none` beside one with it settles it.
