# Turning a format into axes: the long form

SKILL.md step 4 lists each axis in a line. This is the reasoning and the grep for each,
to read when a family you expected to add coverage added nothing, or when you are not
sure what the next family should be. Magnitudes are in `measured-examples.md`; they and
the "one target" anecdotes here were measured on Node bindings over C libraries.

## If the parser is generated, read the specification, not the generated code

When the parser comes from a grammar, schema, IDL or protocol definition, **that file is
the axis list** and the generated code is a table. Take the productions, the token
definitions and the separators straight from it. Two traps live there:

* **The dialect accepts more than the standard it is named after.** A grammar's "extras"
  or "ignored" list admits tokens *between any two other tokens*, so constructs the
  standard forbids parse fine.
* **Token definitions are looser than the standard's.** Take the regex from the grammar,
  not from the specification the grammar is named after.

```sh
ls *.grammar grammar.* *.g4 *.proto *.capnp schema.* 2>/dev/null
grep -nE 'extras|ignored|skip|whitespace|comment' <grammar file>
```

## Constants: which part of the output matters depends on the code's age

```sh
resources/enumerate_constants.sh src/parser.c | head -40
```

Hand-rolled parsers compare against literals, and the literal histogram *is* the axis
list. A mature library uses named enums and macros, and then the histogram is noise (it
returned `0`, `1`, `2` on one target). There the valuable output is the `case` arms and
the enum definitions:

```sh
grep -rhoE '\bcase [A-Za-z_][A-Za-z0-9_]*' src/ | sort -u
```

Then ask: **which enum values does my corpus never produce?** On one target the `case`
arms named four record types and the existing corpus, being entirely encoder output,
contained only one.

For each field emit **every accepted value, every explicitly rejected value, one
unlisted value** (the `default:` arm), and **the boundary either side** of every range
check.

## The option axis: flags and modes gate whole subsystems

```sh
grep -rnE '_PARSE_[A-Z]+|_OPT_[A-Z]+|enum .*[Oo]ptions|getenv\(' ext/ src/ harness.cc
```

A library with an options bitmask or mode switch runs **different subsystems** under
different settings: validation, recovery, entity substitution, a second grammar.

* **Seeds can be inert.** A whole family can parse and reach nothing because the
  subsystem that interprets it is switched off by default.
* **A setting that changes nothing is a finding.** Grep for the API call that drives it;
  usually the extension never makes it, so the whole family is unreachable here.
* **The switch may not be a runtime option.** It can be a compile-time macro in a vendored
  config header or the `extconf.h` mkmf wrote (see the harness skill's feature-detection
  step), or an **entry point the extension never calls**. Check which constructor the
  extension picked against the ones the library offers:
  ```sh
  grep -rn '<lib>_[A-Za-z]*\(Create\|Init\|New\)' ext/ <lib>/*.h
  ```
* **Expect a near-null result sometimes.** Measure it, then move on.

Keep seeds that need a particular setting in their **own corpus directory** (the setting
applies to a whole run), sweep with `resources/sweep.sh`, and **sweep the baseline over
the same settings** or the two numbers are not comparable. The harness's own `getenv`
names are the same axis: `grep -n getenv harness.cc` is the whole discovery step.

## Parallel implementations

If the library implements the same construct separately per encoding, width, endianness
or syntax, every construct has two or three implementations and your corpus probably
covers one. Build the construct list once, then loop it over every implementation.

```sh
grep -rnE 'Encoding\b|_utf8_|_utf16_|_le_|_be_|switch *\(.*encoding|INDENTED|SIMD|_sse|_neon' src/
```

## Internal buffer sizes are axes

A constant that chops input into chunks puts a boundary in the middle of every construct.
Place a **multi-byte character so it straddles each boundary**, and grow each table
**past** its initial size.

```sh
grep -rhnE '#define [A-Z_]*(BUF|BUFFER|CHUNK|BLOCK|CONTEXT|INIT)[A-Z_]*(SIZE|BYTES|LEN)' src/
```

## Each construct in every legal position

Per-construct seeds put each construct in one canonical place, but each *position* is a
different parser state: prolog, declaration subset, content, attribute value, epilog,
inside a literal. A character reference in an attribute value goes through the attribute
normaliser, which is separate code from the content path.

## A construct's parameter is its own sub-grammar

The seed proving a construct is handled rarely touches the grammar *inside* it. A
conditional directive takes a condition language (`and`, `or`, `not`, `only`,
parenthesised feature tests with and without values, prefixed ranges, ratios where `/`
is a separator, interpolation at three depths), none of which `@media screen { a { b: c
} }` reaches. The same goes for a negation pseudo-class taking a full selector list, an
`An+B` index expression, an arithmetic function where spaces are significant, an
attribute operator set, and a URL whose contents are unquoted. Ask of every construct:
*does this take an argument that something else parses?*

## A function or API family needs argument depth, not one call per name

Each entry point validates and dispatches on its arguments:

* **alternate arities**: a colour constructor taking `(colour, alpha)` and `(r, g, b, a)`
  runs different code under one name; so does a join with an explicit or inferred separator
* **keyword arguments**, in and out of order, and unknown names
* **nested calls**, where an argument is itself a call
* **type variation**: a named constant where a literal is expected, unitless vs typed
  (`180` vs `180deg`), an empty collection, `null`
* **boundary values**: negative indices, past-the-end, zero, clamping inputs
* **laziness**: an untaken branch must not be evaluated

Prefer depth on the twenty highest-fanout entry points over one call each on a hundred.

## Cross the axes that select a different implementation

A library with several engines picks between them on a *combination* of properties, and
each combination is a different body of code.

```sh
grep -rniE 'can_|choose|select|strategy|fits_in|kind\(\)|_fast_path' src/
```

Likewise **cross metadata with format**: an ancillary block's payload shape is *typed by
the main header* (a background colour is 2 bytes greyscale, 6 truecolour; a transparency
block is illegal once an alpha channel exists). Build the grid, each payload correctly
sized, **plus one sized for the wrong variant**: that is the length-validation arm.

## Two more cheap axes

* **One declaration that declares several things is a different path from N
  declarations.** An attribute-list declaration naming three attributes with mixed types,
  a default and a fixed value builds its table in a single pass; three separate
  declarations do not. Emit both.
* **Repetition count is an axis.** The first occurrence and the fiftieth differ: expansion
  accounting, table growth past its initial size, name caches. Emit 1 and ~50.

## Cross only the fields the code couples

```sh
grep -rnE "if *\(.*(&&|\|\|).*\b(len|size|count|depth|type|flags|version)\b" src/
```

Each such condition is a small grid; you want the valid cells *and* the rejected ones.
Do not cross everything with everything: that is how a corpus becomes 10 000 files
testing one error path.

## Size as an axis, not only a cost

A library processing in tiles or strips runs different code once the input needs more
than one of them; every tiny seed fits a single tile and never enters the multi-tile
machinery. Include a few mid-sized seeds and find the threshold in the source:

```sh
grep -rnE 'tile|strip|rows_per|MAX_[A-Z]+|_SIZE *[=:] *[0-9]{3,}' src/ | head
```

Cap *declared* dimensions and counts independently of actual size: a header claiming
10000x10000 costs real time on every execution forever.
