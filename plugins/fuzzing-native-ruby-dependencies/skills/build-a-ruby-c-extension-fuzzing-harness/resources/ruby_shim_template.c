/* Skeleton for a Ruby-runtime SHIM: real (non-trapping) definitions of the few rb_* /
 * ruby_* functions an extension's OWN parser calls on the input path, for a gem whose
 * parsing code lives in the extension itself (a parser entry that calls rb_ensure,
 * rb_block_given_p and TypedData_Wrap_Struct unconditionally, so there is no
 * runtime-free function to call instead).  Everything you do NOT define here is still a trapping stub
 * (gen_stubs.sh), so the gate's check 5 keeps proving the harness stayed off the rest of
 * the runtime.
 *
 * Rules:
 *   * Define only what the boundary path reaches, found by linking WITHOUT the shim and
 *     reading which stub the gate/smoke trips (AFL-HARNESS-STUB: entered Ruby runtime: X).
 *   * Each definition mirrors what libruby does FOR THIS CALLER, with a comment saying
 *     why that is enough.  A shim that returns a plausible value where Ruby would raise is
 *     a fidelity bug the gate has to catch; prefer trapping (AFL-HARNESS-RUBYPATH) for
 *     branches the input path should never take.
 *   * Pass it to link_harness.sh as SHIM="shim.c [more.c]": compiled per variant with
 *     plain clang (no AFL instrumentation), that variant's sanitizer and the lifted
 *     flags (plus -I its own dir),
 *     linked like LIB, excluded from stub generation, and rebuilt by rebuild_asan.sh for
 *     the self-test.  Definitions in harness.cc work too (the harness object counts as
 *     "defined elsewhere" for gen_stubs.sh) but need extern "C" there. */
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <ruby.h>
/* #include "myext.h"   -- the extension's header, AFTER ruby.h */
/* #include "enc_table.h"   -- ruby resources/gen_enc_table.rb > enc_table.h */

/* ruby.h maps snprintf/vsnprintf to ruby_snprintf/ruby_vsnprintf (libruby's own printf
 * with %"PRIsVALUE" support).  Undefine them here so this file's own calls use libc;
 * define ruby_vsnprintf below only if the extension calls it. */
#undef snprintf
#undef vsnprintf
/* ruby.h also turns these into macros (measured on Ruby 3.3: __builtin_constant_p
 * wrappers), so `VALUE rb_str_new(...) {` fails with "expected ')'".  #undef the ones you
 * define.  The objects still reference the real symbol names: the macros expand to
 * rb_str_new_static / rb_intern2 / rb_str_new etc. depending on the argument, so define
 * every name `nm -u` of the extension objects shows, not the one in the source.
 *   rb_str_new rb_str_new_cstr rb_str_new2 rb_usascii_str_new rb_usascii_str_new_cstr
 *   rb_utf8_str_new rb_utf8_str_new_cstr rb_enc_str_new rb_enc_str_new_cstr
 *   rb_external_str_new_cstr rb_locale_str_new_cstr rb_str_buf_new_cstr rb_str_cat_cstr
 *   rb_exc_new_cstr rb_intern rb_intern_const */

/* ---- a recording object model ---------------------------------------------------------
 * When the parser's own callbacks BUILD Ruby objects (rb_str_new per
 * text node, rb_ary_push per child, rb_hash_aset per attribute, rb_ivar_set on an element),
 * the shim cannot hand back real VALUEs.  What worked (two evaluation runs): VALUE
 * becomes a pointer to a small tagged node -- STR(bytes, encoding), SYM(name), ARY(items),
 * HASH(pairs in insertion order), OBJ(class, ivars) -- that the shim's rb_* definitions
 * create and fill, and after the parse the harness serialises that tree into the artifact
 * it hashes.  real_harness.rb walks the REAL Ruby objects and writes the identical format.
 * Rules that cost time to discover:
 *   * Walk the tree ITERATIVELY on both sides (an explicit stack): a deep document is a
 *     recursion-depth difference between C and Ruby, not a finding.
 *   * Mirror Ruby's encoding rules, from experiments, not from memory (measured):
 *     rb_intern / rb_intern2 intern as US-ASCII and raise EncodingError for any byte
 *     >= 0x80 ("\xff".force_encoding("US-ASCII").to_sym does NOT raise -- the C path
 *     differs from the Ruby one); a Symbol made from valid ASCII-only UTF-8 gets
 *     US-ASCII encoding; one from invalid UTF-8 raises EncodingError.
 *   * Leave anything the input path should not reach as a stub, and anything you could
 *     not model as a RUBYPATH trap, not a plausible return value.
 * Keep VALUE immediates (Qnil, Qtrue, Qfalse, Fixnums) as Ruby encodes them (ruby.h's
 * RUBY_Qnil etc.): extension code compares against them inline. */

/* A minimal node for the worked rb_funcall example below; grow it into the model above
 * (ARY, HASH, OBJ) when the parser builds more than strings and symbols. */
enum { SHIM_STR = 1, SHIM_SYM };
typedef struct shim_node { int tag; size_t n; unsigned char *p; } shim_node;
/* tokens (below) live under 0x10000 and immediates in the low bits; a node is a heap pointer */
static int shim_is_node(VALUE v) { return v >= 0x10000 && (v & 7) == 0; }

/* ---- data the extension reads ------------------------------------------------------
 * Ruby's class/exception VALUEs are data symbols (rb_cObject, rb_eArgError, ...).  If
 * the path only PASSES them along (to TypedData_Wrap_Struct, to its own raise helper),
 * a distinct token is enough; harness.cc can decode it.  If the path dereferences one,
 * it must stay a (trapping) data stub instead.
 * A token is a multiple of 8 between 0x1000 and 0x10000 (0x1200, 0x1208, ...): never an
 * immediate (a set low bit reads as a Fixnum; 0x08, 0x14, 0x34 are Qnil, Qtrue, Qundef),
 * and a dereference faults at once instead of reading plausible memory.
 *   VALUE rb_cObject = 0x1200;
 *
 * ---- globals of an extension object you do NOT link ----------------------------------
 * The extension's own globals (its class VALUEs, the ID variables Init_<name> sets with
 * rb_intern, an encoding pointer it caches) live in the object holding Init_<name> and
 * the method glue, which the harness usually leaves out.  They are not libruby symbols:
 * gen_stubs.sh does not stub them, and they show up as "undefined reference to
 * `myext_cParser'" at link time (`nm -u` of EXT_OBJS lists them up front).  Define them
 * here, mirroring the Init_<name> lines that set them (cite file:line):
 *   VALUE myext_cParser = 0x1300, myext_eParseError = 0x1308;  -- tokens, as above
 *   ID myext_text_id, myext_start_id;     -- set in shim_init() from the ID table:
 *     void shim_init(void) { myext_text_id = shim_id("text"); myext_start_id = shim_id("start"); }
 * harness.cc calls shim_init() once from harness_init(), where Init_<name> would run.
 */

/* ---- exceptions: rb_raise longjmps to the nearest rb_ensure/rb_protect -------------
 * harness.cc must set shim_raised = NULL at the start of every run_one(): in persistent
 * mode it would otherwise carry the previous input's exception. */
static jmp_buf *shim_jb;
const char *shim_raised;                 /* what was raised; harness.cc turns it into err= */
void shim_raise(const char *what) {
    shim_raised = what;
    if (!shim_jb) {                      /* Ruby would unwind to the caller; the harness has none */
        fprintf(stderr, "AFL-HARNESS-RUBYPATH: raise outside rb_ensure/rb_protect: %s\n", what);
        __builtin_trap();
    }
    longjmp(*shim_jb, 1);
}
VALUE rb_ensure(VALUE (*b_proc)(VALUE), VALUE data1, VALUE (*e_proc)(VALUE), VALUE data2) {
    jmp_buf jb, *prev = shim_jb;
    volatile VALUE r = Qnil;
    shim_jb = &jb;
    int raised = setjmp(jb);
    if (!raised) r = b_proc(data1);
    shim_jb = prev;
    e_proc(data2);                       /* the ensure proc runs on both paths, as in Ruby */
    if (raised) {                        /* and the exception keeps propagating outward */
        if (prev) longjmp(*prev, 1);
        return Qundef;                   /* outermost: the harness reads shim_raised */
    }
    return r;
}
VALUE rb_protect(VALUE (*proc)(VALUE), VALUE data, int *state) {
    jmp_buf jb, *prev = shim_jb;
    volatile VALUE r = Qnil;
    shim_jb = &jb;
    if (0 == setjmp(jb)) { r = proc(data); if (state) *state = 0; }
    else if (state) *state = 1;          /* caller checks *state, as with Ruby's TAG_RAISE */
    shim_jb = prev;
    return r;
}
/* If the input path calls rb_raise itself (not only the extension's own error helper),
 * mirror it -- the class decides err=:
 *   void rb_raise(VALUE exc, const char *fmt, ...) { (void)fmt; shim_raise(<name for exc>); }
 * rb_raise is noreturn; so is shim_raise in effect. */

/* ---- IDs: a table, so an ID maps back to its name ----------------------------------
 * ID 0 is reserved (no name).  Ruby's own IDs are opaque, so any small distinct integer
 * works as long as the same name always gets the same one.  Define rb_intern /
 * rb_intern2 / rb_intern_const (whichever `nm -u` shows) on top of it when the path
 * interns names at run time; mirror rb_intern's US-ASCII rule (above) there. */
#define SHIM_MAX_IDS 512
static const char *shim_id_names[SHIM_MAX_IDS];
static int shim_id_count = 1;
ID shim_id(const char *name) {
    for (int i = 1; i < shim_id_count; i++)
        if (0 == strcmp(shim_id_names[i], name)) return (ID)i;
    if (shim_id_count == SHIM_MAX_IDS) {
        fprintf(stderr, "AFL-HARNESS-RUBYPATH: ID table full at %s\n", name);
        __builtin_trap();
    }
    shim_id_names[shim_id_count] = name;  /* names are string literals or interned copies */
    return (ID)shim_id_count++;
}

/* ---- a handler-recording rb_funcall: the event stream harness.cc hashes ------------
 * A callback-driven parser reports each event by rb_funcall(handler, id, argc, ...).
 * Record it instead: method name (from the ID table), then each argument, tagged and
 * length-prefixed, appended to shim_ev.  harness.cc hashes shim_ev (on an error too:
 * the events before it are part of the artifact) and calls shim_ev_reset() per run.
 * real_harness.rb's handler writes the same bytes into COLLECTED, one method per
 * callback the extension calls:  def text(s) = rec("text", s)  with
 *   def rec(m, *a) = COLLECTED << m << "(" << a.map { ser(_1) }.join << ")\n"
 * Format per argument: n; t; f; i<num>; s<len>:<bytes>; y<len>:<bytes>; ?; (unknown).
 * A call on any other receiver (an IO's #read, a user object) is not an event: trap. */
VALUE shim_handler = 0x1100;             /* the token harness.cc passes as the handler */
unsigned char *shim_ev;
size_t shim_ev_n;
static size_t shim_ev_cap;
void shim_ev_reset(void) { shim_ev_n = 0; }
static void shim_put(const void *p, size_t n) {
    if (shim_ev_n + n > shim_ev_cap) {
        shim_ev_cap = (shim_ev_n + n) * 2 + 256;
        shim_ev = realloc(shim_ev, shim_ev_cap);
        if (!shim_ev) abort();
    }
    memcpy(shim_ev + shim_ev_n, p, n);
    shim_ev_n += n;
}
static void shim_putf(const char *fmt, long v) {
    char b[32];
    int k = snprintf(b, sizeof b, fmt, v);
    shim_put(b, (size_t)k);
}
static void shim_ser(VALUE v) {
    if (v == Qnil) shim_put("n;", 2);
    else if (v == Qtrue) shim_put("t;", 2);
    else if (v == Qfalse) shim_put("f;", 2);
    else if (FIXNUM_P(v)) shim_putf("i%ld;", FIX2LONG(v));
    else if (shim_is_node(v)) {
        const shim_node *x = (const shim_node *)v;
        shim_putf(x->tag == SHIM_SYM ? "y%ld:" : "s%ld:", (long)x->n);
        shim_put(x->p, x->n);
        shim_put(";", 1);
    } else shim_put("?;", 2);
}
static VALUE shim_event(VALUE recv, ID mid, int argc, const VALUE *argv) {
    if (recv != shim_handler || mid == 0 || mid >= (ID)shim_id_count) {
        fprintf(stderr, "AFL-HARNESS-RUBYPATH: rb_funcall on a non-handler or unknown ID\n");
        __builtin_trap();
    }
    const char *name = shim_id_names[mid];
    shim_put(name, strlen(name));
    shim_put("(", 1);
    for (int i = 0; i < argc; i++) shim_ser(argv[i]);
    shim_put(")\n", 2);
    return Qnil;                         /* what the handler returns, if the parser reads it */
}
#undef rb_funcall                        /* a macro in some ruby.h versions */
#undef rb_funcallv
VALUE rb_funcallv(VALUE recv, ID mid, int argc, const VALUE *argv) { return shim_event(recv, mid, argc, argv); }
VALUE rb_funcall(VALUE recv, ID mid, int argc, ...) {
    VALUE a[16];
    va_list ap;
    if (argc < 0 || argc > 16) { fprintf(stderr, "AFL-HARNESS-RUBYPATH: rb_funcall argc=%d\n", argc); __builtin_trap(); }
    va_start(ap, argc);
    for (int i = 0; i < argc; i++) a[i] = va_arg(ap, VALUE);
    va_end(ap);
    return shim_event(recv, mid, argc, a);
}

/* ---- calls with a fixed answer for this caller ------------------------------------- */
int rb_block_given_p(void) { return 0; }           /* the API under test is called without a block */
VALUE rb_data_typed_object_wrap(VALUE klass, void *datap, const rb_data_type_t *type) {
    (void)klass; (void)datap; (void)type;
    return Qnil;                         /* only kept for GC marking; check the caller tolerates Qnil */
}

/* ---- the xmalloc family: malloc here --------------------------------------------------
 * Ruby's own raises NoMemoryError where malloc returns NULL, and may run the GC first
 * (see harness_template.cc, step 3).  Define the ones the objects reference. */
void *ruby_xmalloc(size_t n) { return malloc(n); }
void *ruby_xmalloc2(size_t n, size_t size) { return malloc(n * size); }
void *ruby_xcalloc(size_t n, size_t size) { return calloc(n, size); }
void *ruby_xrealloc(void *p, size_t n) { return realloc(p, n); }
void *ruby_xrealloc2(void *p, size_t n, size_t size) { return realloc(p, n * size); }
void ruby_xfree(void *p) { free(p); }
int ruby_vsnprintf(char *str, size_t n, const char *fmt, va_list ap) { return vsnprintf(str, n, fmt, ap); }

/* ---- encodings: from the runtime's own table (gen_enc_table.rb) ----------------------
 * enc_names[] ENDS WITH A {0, -1} SENTINEL: loop `for (i = 0; enc_names[i].name; i++)`,
 * never over sizeof(enc_names) -- the sentinel's NULL name went into strcasecmp and the
 * harness died with rc=139 on the first unknown encoding (measured).
 *
 * static char shim_enc[ENC_COUNT];     -- one distinct pointer per encoding, never dereferenced
 * rb_encoding *rb_enc_find(const char *name) {
 *     for (int i = 0; enc_names[i].name; i++)
 *         if (0 == strcasecmp(enc_names[i].name, name)) return (rb_encoding *)&shim_enc[enc_names[i].idx];
 *     return (rb_encoding *)&shim_enc[ENC_ASCII_8BIT_INDEX];   -- unknown -> ASCII-8BIT, not NULL (measured)
 * }
 * int rb_enc_find_index(const char *name) { ... same lookup, -1 when unknown ... }
 */
