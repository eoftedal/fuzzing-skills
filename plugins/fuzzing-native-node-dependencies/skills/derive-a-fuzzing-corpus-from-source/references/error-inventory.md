# The error inventory: the to-do list when there is no baseline

SKILL.md step 2 runs `resources/error_inventory.sh` and names the routes and the classes
in a line each. This is the long form: how to get the library's error list, and how to
sort the codes your corpus never provokes. Magnitudes are in `measured-examples.md`
step 2.

## Three routes to the list, best first

1. **An error-string function.** If the library exposes `*_ErrorString()` /
   `*_strerror()` (or a C++ `Status::CodeText()`), **do not grep**:
   `resources/errenum_template.c` is the ten-line program. Fill in the two names, compile
   it together with the library's error-string source file (the AFL-instrumented objects
   do not link into a plain program; the pristine ones do), and diff its output against
   the `err` column of `.results`. It skips the filler string such functions return for
   non-members. The mapping is exact, and on every target that had such a function it
   was the right route. An enum member the parser never sets is dead code, which is a
   finding, not a gap.
2. **The enum, when the harness prints the numeric code.** Parse the enum from the header
   and index it:
   ```sh
   sed -n '/^typedef enum/,/^}/p' <lib>/api.h | grep -oE '[A-Z][A-Z0-9_]*ERR[A-Z0-9_]*'
   ```
3. **Grep the literals**, only when neither of the above exists. If the library
   *composes* its messages at runtime, grep the composer, not the literals: a literal
   grep both misses most of the real inventory and returns unrelated constants.

**`HASHCMD=` only works when the harness hashes exactly the literal.** A low hit rate from
it means the comparison is broken, not the corpus.

## Classify what remains

* **Input-reachable**: write the seed.
* **API-state only** (suspend, abort and allocation-failure paths): ignore.
* **Unreachable in this configuration** (a feature the binding never enables, a legacy
  format compiled out): ignore, and record why. This class is where effort goes to die:
  check which constructor and which subsystems the binding actually calls before writing
  seeds for a feature it never turns on (`axes.md`, "The option axis").
* **Converted internally**: an inner layer's code that an outer layer maps to a generic
  one before it reaches the API (an entropy decoder's table-size errors reported as
  "corruption detected" by the block layer). The generic code is the reachable one, so
  count the inner ones as covered by it, not as gaps.

## A JS wrapper can shadow the library's errors

A wrapper may run its own pre-check (a size check that throws its own error before the
native call), so a library code is reachable only through an input that gets past the
pre-check first (an unsized first frame). The per-family `err` histogram from
`validate.sh` is where that shows.

## The `err` token when the package has no error code

The histograms steer by `err`, so it must separate the library's errors from each other
and stay identical across seeds that hit the same one. When the package exposes only an
error class (every failure is one `ParseError`), the class alone puts every reject in
one bucket and the histogram says nothing. When the message embeds a position (`... at
line 3, column 17`), the whole message is unique per seed. Use the message **up to the
position marker**, spaces replaced by `_`, on both sides of the gate: it names the check
that failed and nothing about where. Change it in the harness and the real-side template
together, then re-gate when `FIELDS` compares `err`.
