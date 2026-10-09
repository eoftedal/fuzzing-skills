# Borrowing fixtures: where they hide and how to extract them

SKILL.md step 2 item 3 keeps the `find`/`tar` loop and the `extract_literals.py` calls.
This is the long form, for when the `find` comes back empty, full of noise, or the
extraction yields almost nothing.

## Fixtures one level down

The binding may ship none while the vendored dependency ships many.

* **Filter the `find` to the gem's own tree.** Prune `vendor/bundle`, the installed gems
  and the `oracle/` install, or it returns development-dependency noise.
* **Look inside vendored tarballs and submodules.** A vendored source tarball under
  `ext/` or `ports/archives/` can hold the library's whole `tests/files/` with a README
  naming every case, and `find` cannot see it. A tarball usually ships beside its `.sig`
  (the loop skips signatures and checksums).
* **A vendored library's test directory may be named `testing`.** The `find` already
  includes it.

## The fixtures may not be files

A library whose tests are compiled often carries hundreds of documents as string literals
in its test source, and a gem's own tests (`test/**/*.rb`, `spec/**/*.rb`) carry them as
Ruby strings, `%q`/`%w` lists and heredocs. `$RC/extract_literals.py` pulls them out.

```sh
cd $W && . ./fuzz.env
$RC/extract_literals.py OUT=./corpus-fixtures DECODE=hex SRC='spec/**/*.rb'
$RC/extract_literals.py OUT=./corpus-fixtures ALL=1 SRC=tests/*.c   # no signature byte
```

* `SRC=` repeats, takes a glob, or one quoted list; a path that does not exist is an
  error, not an empty result; `**` recurses. `LANG=c|js|rb` defaults by extension.
* `DECODE=hex|base64` when a binary record is spelled out as a string.
* `ALL=1` for a format with no signature byte (patterns, queries, source text); the
  default filter throws nearly everything away there.
* **A structured input convention** (a container of `flags NUL pattern NUL subject`)
  makes a raw literal not a seed: wrap each one into the container with a few lines of
  script before measuring.
* `JSREGEX=1` also extracts **regex literals** (`/.../flags`) from `.rb` and `.js`
  sources, the dominant fixture form in a regex binding's own tests, which string
  extraction misses entirely.
* Images embedded as `data:` URIs are not reachable this way; use the fixture files.
