# Fixtures one level down, and fixtures that are not files

SKILL.md step 2 lists the borrowed sets, and its item 3 runs the `find`/`tar` block and
`extract_literals.py`. This is the long form: the first two sets, where fixtures hide,
and the options for pulling them out of test source.
Magnitudes are in `measured-examples.md` step 2.

## Before the fixtures: the first two borrowed sets

* **A corpus derived for another target over the same format.** Reading a *format*
  amortises across every binding over it, so a corpus written for one binding is the
  cheapest start for the next. It must share the **input convention** too: a UTF-16
  corpus means nothing to a UTF-8 parser until it is re-encoded.
* **The harness's own gate corpus.** It was written to populate both arms of the gate,
  so it holds rejects a sample baseline lacks, and as a second A-side it can expose a
  broken family the sample baseline hid (SKILL.md step 7, "every A-side").
* **The one giant sample.** A single multi-megabyte document is a cost problem, not a
  corpus: every mutant pays its size. Read it for constructs and write small seeds that
  carry them.

## Where the files are

* **The binding may ship none while the vendored dependency ships many.** Look in the
  dependency's tree, not only the binding's.
* **Filter the `find` to the target's own tree.** Without the `node_modules` prune it
  returns devDependency fixtures, which are not a baseline.
* **Look inside vendored tarballs and submodules.** A vendored source tarball under
  `deps/` can hold the library's whole `tests/files/` with a README naming every case,
  and `find` cannot see it. A tarball usually ships beside its `.sig`, which the loop
  skips.
* **A vendored library's test directory may be named `testing`**, which the `find`
  includes for that reason.

## Fixtures as string literals

A library whose tests are compiled often carries hundreds of documents as string
literals in its test source. `resources/extract_literals.py` pulls them out:

* `SRC=` repeats, takes a glob, or one quoted list; a path that does not exist is an
  error, not an empty result.
* `STARTS=` keeps a literal containing a substring (default `<`); `RE=` instead keeps one
  whose decoded bytes match a regex (a signature such as `^(\x89PNG|GIF8)`).
* `DECODE=hex|base64` when a binary record is spelled out as an encoded string.
* `ALL=1` for a format with no signature byte (patterns, queries, source text); the
  default filter throws nearly everything away there.
* `JSREGEX=1` also extracts JS **regex literals** (`/.../flags`), the dominant fixture
  form in a regex binding's own tests, which string extraction misses entirely.
* **A structured input convention needs wrapping.** For a container such as
  `flags NUL pattern NUL subject`, a raw literal is not a seed: wrap each one into the
  container with a few lines of script before measuring.
* **Images embedded as `data:` URIs are not reachable this way**; use the fixture files.
