# The Ruby shim: defining the runtime calls a parser in the extension makes

Read this when the boundary is the extension's own parser (`boundary-shapes.md`) and it
calls the Ruby runtime unconditionally. `resources/ruby_shim_template.c` is the skeleton;
its comments carry the details below next to the code.

## When and how

One such parser called `rb_ensure`, `rb_block_given_p` and `TypedData_Wrap_Struct`
unconditionally, so with stubs alone it traps on the first input. Pass the shim as
`link_harness.sh ... SHIM=shim.c`: it is compiled per variant, linked, excluded from
stubbing and rebuilt in the self-test.

* **Find the set** by linking without the shim and reading which stub the gate trips
  (`AFL-HARNESS-STUB: entered Ruby runtime: <symbol>`).
* **Define only those**, each mirroring what libruby does *for this caller*, and leave the
  rest as stubs so gate check 5 still proves the path stayed off the runtime. A branch the
  input path should never take traps (`AFL-HARNESS-RUBYPATH`) rather than returning a
  plausible value.
* **How many stubs remain** depends on which objects you link (an extension's name caches
  pull in `rb_intern*`, `rb_sym2id`, ...).

## What the template covers

* `rb_ensure`/`rb_protect` (`setjmp`, propagation outward).
* The xmalloc family, as `malloc`.
* `ruby_vsnprintf`, and the `ruby.h` macros you must `#undef` to define functions such as
  `rb_str_new` or `rb_intern` (the objects reference whatever name the macro expanded to:
  define every name `nm -u` shows). `ruby.h` first and outside `extern "C"`:
  `build-traps.md`, "Compiling a harness against ruby.h".
* `rb_enc_find` over a table generated from the runtime (`resources/gen_enc_table.rb`); an
  unknown name is ASCII-8BIT, not NULL (measured).

## Globals of extension objects you do not link

The parser's objects read globals that the object holding `Init_<name>` defines and sets:
class VALUEs (`rb_define_class_under`), ID variables (`rb_intern("text")`), a cached
encoding pointer. You do not link that object (it is all Ruby glue), and these are not
libruby symbols, so `gen_stubs.sh` does not stub them: they appear as **undefined
references at link time** (`nm -u` on the `EXT_OBJS` lists them up front). Define them in
the shim, set in a `shim_init()` that `harness.cc` calls once where `Init_<name>` would
run, each mirroring the line of `Init_<name>` that sets it (cite file:line). An ID becomes
an index into the shim's own name table; a class VALUE becomes a token node. The
template's "globals of an extension object you do NOT link" block is the worked example.
Both evaluation runs of the shim shape had to do this; once they were defined,
`gen_stubs.sh` reported 0 data stubs. A helper the parser calls from an unlinked object
(a string-interning cache) is the same case: define it, mirroring what it returns, and
note the drift risk, or link its object too.

## A handler-recording rb_funcall

A callback-driven parser in the extension reports each event with `rb_funcall(handler,
id, argc, ...)`. With the shim, that call is the artifact: record the method's name and
every argument into the event stream `harness.cc` hashes, in the format `real_harness.rb`'s
handler class writes on the real side, and return what the real handler returns (`nil`
for most). A receiver that is not the handler, or an ID the handler does not define,
traps with `AFL-HARNESS-RUBYPATH`. If the extension asks `rb_respond_to` before each
call, answer from the same table the real handler class defines. The template's `rb_funcall`/`rb_funcallv` pair is the worked example.

When the call raises mid-stream, the real side's rescue branch hashes `COLLECTED` (the
template's buffer the handler class appends each event to), so the shim's stream is hashed
on error too.

## When the callbacks BUILD Ruby objects

The builder callbacks behind a load method create strings, arrays and hashes. Make VALUE a
small tagged node (string, symbol, array, hash, object) that the shim fills, serialise the
tree into the artifact, and have `real_harness.rb` walk the real objects into the same
format, iteratively on both sides.

Mirror Ruby's encoding rules from experiments: `rb_intern` raises EncodingError for any
byte >= 0x80, valid UTF-8 included, while Ruby's `to_sym` does not (measured).
