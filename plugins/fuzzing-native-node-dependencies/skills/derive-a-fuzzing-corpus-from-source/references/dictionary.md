# The dictionary: what the build writes, what you add

SKILL.md step 7b runs `dict.sh`. This is the long form: the file format, what the
build-time pass records and what it misses, and a worked example.

## Why a dictionary at all

afl-fuzz mutates bytes: flips, arithmetic, splices of other queue entries. A four-byte
magic or an eight-letter keyword is one value out of 2^32 or 2^64 to that mutator, so a
branch behind `strcmp(name, "UTF-16LE")` stays closed however long the campaign runs,
unless a seed already carries the token. A dictionary hands afl-fuzz the tokens whole:
it inserts them and overwrites bytes with them at any position while it mutates. The corpus puts each token in one position; the dictionary moves it to all of
them.

## The file format

One token per line, `name="value"` or just `"value"`, with `\xNN` for a non-printing
byte and `\"`, `\\` escaped; `#` starts a comment and afl-fuzz ignores the names. It
rejects a token longer than 128 bytes, and `dict.sh`'s `MAXLEN=` (default 32) keeps the
file to tokens short enough to splice cheaply.

## What the build-time pass sees, and what it does not

`build_addon.sh` and `link_harness.sh` set `AFL_LLVM_DICT2FILE`, so afl-clang-fast
records, per instrumented object, the constant operand of each comparison: integer
compares against an immediate (magic numbers, field values, `case` labels) and
`memcmp`/`strcmp`/`strncmp`/`strcasecmp` calls with a literal argument. The result,
deduplicated, is `out/<variant>/dict.afl`, and the build summary prints its entry count.
An entry count near zero for a parser that obviously checks magic bytes means the
library was not compiled by those scripts (a 3b archive without the export, harness
skill `references/build-traps.md`).

It does not see:

* **Code afl-clang-fast never compiled**: a system library the harness links
  uninstrumented, and the package's JavaScript, which decides which native path runs
  (an option name checked in `lib/*.js`, a format string mapped to an enum before the
  call). `SRC=` harvests string literals from those files by regex.
* **Names compared through a table.** `strcmp(name, table[i].name)` in a loop has no
  literal operand at the call site, so none of the table's names is recorded, and those
  names are often exactly what selects a converter, codec or handler.
* **Your own framing.** The separators between the fields of a framed input are
  single bytes the harness splits on, not constants the library compares; afl-fuzz
  needs them to build a well-framed mutant from scratch.
* **Grammar tokens a generated lexer matches by state table**: the keywords and
  operators are in transition tables, not compare instructions.
* **Values the code computes before comparing** (a hash of a name, a checksum).
  A token for the name still helps when the hash is over the token.

Those are what `TOKENS=` and `TOKENS_FILE=` are for. A token holding a space goes in
`TOKENS_FILE=`, one per line. Check the written `dict.afl` for any non-printing
separator: it must appear as its `\xNN` escape.

## A worked example: a converter selected by name

A binding converts text between encodings; the harness frames each input as
`<from>\0<to>\0<payload>` (documented at the top of `harness.cc`) and the library picks
one converter per name from a table of function pointers. `MODES="MODE=stream"` adds the
streaming entry point. The build-time `dict.afl` holds the library's byte-order marks and
escape-sequence constants, but no encoding name, because the names are matched by a loop
over the table.

```sh
cd $W && . ./fuzz.env
grep -ohE '"[A-Z0-9_-]{3,24}"' <lib>/src/<name-table>.c | tr -d '"' | sort -u > names.txt
printf '%s\n' '\x00' stream default >> names.txt
$RC/dict.sh OUT=./dict.afl TOKENS_FILE=names.txt SRC="lib/*.js"
```

The result holds, beside the build-time constants:

```
"\x00"
"UTF-8"
"UTF-16LE"
"UTF-32BE"
"ISO-8859-1"
"SHIFT_JIS"
"EUC-JP"
"stream"
```

Now a mutant that replaces `UTF-8` with `EUC-JP` reaches a different converter in one
step, where without the dictionary it needed the corpus to hold a seed for every name.
Aliases count as tokens too (`LATIN1` beside `ISO-8859-1`) when the lookup normalises
them through its own code. The same reasoning covers a format name chosen by a string
option, a stylesheet's property names, or a query language's keywords and operators.

## What the campaign does with it

`campaign.sh` passes `-x $W/dict.afl` when it exists, else the variant's
`out/<variant>/dict.afl`; `DICT=none` turns it off, and the manifest's `dict` column
records which one ran, because a finding that needed a token reproduces through its
saved input but is found again only with the same dictionary.
