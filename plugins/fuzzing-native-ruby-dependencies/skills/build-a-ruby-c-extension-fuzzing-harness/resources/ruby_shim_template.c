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
 *     that variant's compiler, sanitizer and the lifted flags (plus -I its own dir),
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

/* ---- data the extension reads ------------------------------------------------------
 * Ruby's class/exception VALUEs are data symbols (rb_cObject, rb_eArgError, ...).  If
 * the path only PASSES them along (to TypedData_Wrap_Struct, to its own raise helper),
 * a distinct non-zero token is enough; harness.cc can decode it.  If the path
 * dereferences one, it must stay a (trapping) data stub instead.
 *   VALUE rb_cObject = 0x1201;
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
