# The error inventory: what to write when there is no baseline

SKILL.md step 2 runs `error_inventory.sh` and names the routes and classes in a line
each. This is the long form: how to take each route, and how to classify what is left.
Read it when the inventory looks wrong (too short, full of non-errors) or when you are
deciding whether an unreached code is worth a seed.

With no baseline, anything you write is a net win; the question is what to write next.
Replace `A-only` with the to-do list the library wrote for you: **every error code it can
raise that your corpus never provokes.**

```sh
$RC/error_inventory.sh SRC=<vendor dir> PREFIX=<LIB> RESULTS=maps_baseline/.results
```

## Three routes, best first

1. **An error-string function.** If the library exposes `*_ErrorString()` /
   `*_strerror()` (or a C++ `Status::CodeText()`), **do not grep**:
   `$RC/errenum_template.c` is the ten-line program. Fill in the two names, compile
   it together with the library's error-string source file (the AFL-instrumented objects
   do not link into a plain program; the pristine ones do), and diff its output against
   the `err` column of `.results`. It skips the filler string such functions return for
   non-members. It walks from `MIN_CODE` (default -64), because error codes are often
   negative; set it below the enum's lowest member. The mapping is exact, and on every target that had such a function (Node
   bindings) it was the right route. An enum member the parser never sets is dead code,
   which is a finding, not a gap.
2. **The enum, when the harness prints the numeric code.** Parse the enum from the header
   and index it:
   ```sh
   sed -n '/^typedef enum/,/^}/p' <lib>/api.h | grep -oE '[A-Z][A-Z0-9_]*ERR[A-Z0-9_]*'
   ```
3. **Only otherwise, grep literals.** If the library *composes* its messages at runtime,
   grep the composer, not the literals: a literal grep both misses most of the real
   inventory and returns unrelated constants. `HASHCMD=` only works when the harness
   hashes exactly the literal; a low hit rate from it means the comparison is broken, not
   the corpus.

## Classify what remains

* **Input-reachable**: write the seed.
* **API-state only** (suspend/abort/alloc-failure paths): ignore.
* **Unreachable in this configuration** (a feature the binding never enables, a legacy
  format compiled out): ignore, and record why. This class is where effort goes to die:
  check which constructor and which subsystems the binding actually calls before writing
  seeds for a feature it never turns on.
* **Converted internally**: an inner layer's code that an outer layer maps to a generic
  one before it reaches the API (an entropy decoder's table-size errors reported as
  "corruption detected" by the block layer). The generic code is the reachable one, so
  count the inner ones as covered by it, not as gaps.

## A wrapper can shadow a code

The gem's Ruby wrapper (`lib/**/*.rb`) may **shadow** the library's header errors: a size
pre-check that raises its own error before the native call. A code is then reachable only
through an input that gets past the pre-check first (an unsized first frame). The
per-family `err` histogram is where that shows.

## When the binding collapses every error into one message

Some bindings map every library error to one fixed message, so `err` is the same token
for every reject: correct for the gate, which compares what the real stack shows, and
useless for the histograms and the inventory. `error_inventory.sh` warns when every
rejected input has one value. Give the direct harness an **ungated** `lib_err=` field
holding the library's own error name or code (the gate compares only `FIELDS`, so it
ignores the extra key), re-run `measure.sh`, then pass `FIELD=lib_err` to `validate.sh`
and `error_inventory.sh`, and diff `errenum`'s output against the `lib_err` column.
