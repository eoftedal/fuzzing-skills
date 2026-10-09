# Authoring seeds and reaching the success path: the long form

SKILL.md steps 5 and 8 keep the rules in a line each. This is the explanation, for when a
generated family dies early or the success path stays uncovered.

## What the generator template already does

`$RC/gen_template.rb` names files `<family>-<nnn>-<name>` so `validate.sh PREFIX=`
can slice a family, writes the manifest *outside* the corpus directory, clamps every
written integer to its field width, and separates the declared value from the actual
layout. What you add is the two rules below.

## Defaults that parse to completion, proved by a byte diff

Byte-diff the default record against the real writer before any family exists. It takes
thirty seconds and catches the class of framing error that no re-reading of the format
does.

```sh
<writer> < sample > ref.bin && od -An -tx1 ref.bin | head -3
ruby gen.rb ONLY=default && od -An -tx1 corpus-derived/default-001-default | head -3
```

A difference in an **optional** field (a writer that adds sizes or padding to a header by
default, a multithreaded encoder's flags) is fine when both records decode to the same
bytes; a difference in a required field is the bug you are looking for.

## Dependent fields derived from the code's own rule

A plausible constant silently kills a whole family. Take the rule (a length, a checksum,
an offset) from the code that checks it, not from a description of the format.

## Whether the success path needs the writer

The library's writer is necessary only when the format has a layer you cannot
hand-assemble: entropy coding, a range coder, codec-internal tables, a checksum over
compressed bytes. On a shallow tag-based format it adds nothing. One writer option is
usually worth two axes: the flag that omits a declared output size is often also the
binding's dispatch switch.

## Transplant blobs you cannot synthesise

A colour profile, a metadata IFD, an embedded font: cut the segment out of a sample and
graft it onto a tiny host. Truncated and length-inflated variants come free. Where the
writer refuses a variant, keep the sample that holds it and say so.

## If the target resolves external references, the corpus is a directory

A seed whose include never resolves reaches only the failure path. Create the referenced
files, point the target's search path at them, and treat the fixture directory as part of
the corpus: entities and DTDs, stylesheet imports, template includes, archive members.
