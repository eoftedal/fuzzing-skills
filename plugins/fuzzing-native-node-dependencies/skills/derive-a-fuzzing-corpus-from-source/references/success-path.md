# The success path: writer, transplants, fixture directories

SKILL.md step 8 keeps the table and a line per technique. This is the long form.
Magnitudes are in `measured-examples.md` step 8.

## Decide whether you need the writer at all

The library's writer is necessary only when the format has a layer you cannot
hand-assemble: entropy coding, a range coder, codec-internal tables, a checksum over
compressed bytes. On a shallow tag-based format it adds nothing over a generator.

Drive it across its option surface. One writer option is usually worth two axes: the
flag that omits a declared output size is often also the binding's dispatch switch.

## Valid records corrupted after the header

The most productive seeds of all. A correct early section with a broken later one gets
past every check that gates the deep code and *then* fails, so it exercises the error
paths of the late parsers, which neither a valid sample nor a seed broken at field one
reaches. Take a writer's output or a valid fixture and truncate, flip or resize a field
past the header, one record per seed.

## Transplant blobs you cannot synthesise

A colour profile, a metadata IFD, an embedded font: cut the segment out of a sample and
graft it onto a tiny host. The host keeps the decode cheap while the graft reaches the
same parsers. Truncated and length-inflated variants of the graft come free. Where the
writer refuses a variant, keep the sample that holds it and say so.

## If the target resolves external references, the corpus is a directory

A seed whose include never resolves reaches only the failure path. Create the referenced
files, point the target's search path at them, and treat the fixture directory as part
of the corpus: entities and DTDs, stylesheet imports, template includes, archive
members.
