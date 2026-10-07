// Skeleton for a direct AFL++ harness against the C library behind a Ruby C extension.
// Replace the marked sections; the structure around them is what you want.
//
// Build BOTH binaries from this one file with resources/link_harness.sh, which
// compiles it twice (persistent, and -DNO_PERSISTENT for the fork twin) with the
// include paths and -D macros lifted from the extension's mkmf Makefile.  The HAVE_*
// macros extconf.rb set matter: they change struct layouts and which code is compiled.
// The extension's headers are C: wrap them in extern "C" { } if they do not do it
// themselves.
//
// OUTPUT CONTRACT (single-shot mode): ONE line of key=value pairs,
//   in_len= status= err= out_len= out_hash= lossy= invariant=
// The real-stack harness prints the same keys; gate.sh compares the ones you name in
// FIELDS, and the corpus skill's validate.sh groups seeds by `err`.
//   status    0 ok, 1 rejected: your own small enum
//   err       the LIBRARY's own error, as ONE TOKEN, identical on both sides:
//             its numeric code if the gem exposes one (an error #code / a status enum),
//             otherwise its error NAME or message with spaces replaced by '_'
//             (the library's own error-string function).  "0" when status == 0.
//             Never a hash of a message that embeds the input: that makes err unique
//             per seed and useless for the corpus skill's histograms.
//   lossy     always 0 on this side; the real stack sets 1 when it cannot report faithfully

// --- 1. the library's own headers, and the extension header holding your boundary ---
// #include <ruby.h>          // FIRST and OUTSIDE any extern "C": ruby.h has C++ templates
// #include <ruby/encoding.h> // (stdalign.h) and fails inside one -- "templates must have
//                            // C++ linkage" (measured).  ruby.h guards itself.
// extern "C" {               // only around headers that do not do it themselves; many
// #include <library.h>       // have their own extern "C" block (check before wrapping)
// #include "myext.h"         // the extension's header; it usually pulls in ruby.h --
// }                          // fine, you never call it, the stubs catch it.  Inline
//                            // helpers from ruby.h (rb_class_of / CLASS_OF) read rb_c*
//                            // globals: those are data stubs and fault if reached.
// #undef snprintf            // ruby.h maps snprintf/vsnprintf to ruby_snprintf/
// #undef vsnprintf           // ruby_vsnprintf, which the harness does not link
//                            // ("undefined reference to `ruby_snprintf'", measured)

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

// --- 2. anything the real stack reaches only through the binding must be
//        unreachable here, and must say so loudly rather than returning ---
static void binding_path_reached(const char* what) {
  (void)!write(2, "AFL-HARNESS-RUBYPATH: ", 22);
  (void)!write(2, what, strlen(what));
  (void)!write(2, "\n", 1);
  __builtin_trap();
}

// --- 3. configuration.  NEVER an input byte: keeping modes and options out of the
//        input means a corpus file is byte-for-byte what the real API consumes, so
//        any seed, queue entry or crash can be replayed on the real stack unchanged.
//        Read them from the environment (MODE=buffer|file, ...); the corpus skill
//        sweeps `getenv` names it finds in this file.
static int    g_mode = 0;          /* e.g. buffer vs file entry point */
// Attacker-declared allocations (a decompressor's declared content size, an image
// header's dimensions): NO cap by default.  Mirror what the real stack does, with its
// own error tokens so the gate agrees.  Which allocator makes the allocation decides it:
//   * the extension allocates the output through Ruby (rb_str_new / rb_str_buf_new /
//     ALLOC_N / ruby_xmalloc): Ruby raises ArgumentError for a negative or too-large
//     string size and NoMemoryError ("failed to allocate memory") when the allocator
//     refuses, after retrying once behind a GC.  Report err=NoMemoryError at that site;
//     the real harness reports the exception class.
//   * the library allocates with plain malloc (or the extension handed it ruby_xmalloc
//     through a MemSetup hook -- then it is the case above): malloc returns NULL under
//     ASAN's max_allocation_size_mb and the library's own error path follows.
// Then let the FUZZER bound the run (afl-fuzz -m for the plain
// build, ASAN max_allocation_size_mb + allocator_may_return_null=1 for the sanitized
// one, which campaign.sh sets from ALLOC_CAP_MB).  An invented cap rejects inputs the
// real gem accepts.  See references/four-layers.md, layer 2.
// OPT-IN only: ALLOC_CEIL=<bytes>, set identically for real_harness.rb, refuses
// above it AT THE ATTACKER-DECLARED SITE ONLY (call over_ceiling() where you mirror
// that allocation, and report err=alloc-ceiling).  Never on malloc in general.
static size_t g_alloc_ceil = 0;    /* 0 = off */
static inline bool over_ceiling(size_t declared) { return g_alloc_ceil && declared > g_alloc_ceil; }
// Attacker-chosen WORK (a cost/rounds exponent, an iteration count in the input) is the
// same thing in time: mirror the gem's own bound if it has one, else an OPT-IN
// WORK_CEIL=<units> applied at that field on both arms (err=work-ceiling), never a silent
// clamp.  An unbounded one is a finding for triage (input-controlled work factor).
static unsigned long g_work_ceil = 0;  /* 0 = off; e.g. the maximum cost exponent to run */
static inline bool over_work(unsigned long units) { return g_work_ceil && units > g_work_ceil; }

struct Result {
  int      status;           // 0 ok, 1 rejected, ... ; your own small enum
  char     err[64];          // the library's own error token; "0" when status == 0
  size_t   out_len;
  uint64_t out_hash;
  long     invariant;        // e.g. the library's open-handle/alloc counter delta; want 0
};

static uint64_t fnv1a(const unsigned char* p, size_t n) {
  uint64_t h = 0xcbf29ce484222325ull;
  for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 0x100000001b3ull; }
  return h;
}
static void set_err(Result* r, const char* name) {   // "Data corruption detected" -> Data_corruption_detected
  size_t i = 0;
  for (; name[i] && i < sizeof r->err - 1; i++) r->err[i] = (name[i] == ' ' ? '_' : name[i]);
  r->err[i] = 0;
}

// --- 4. module init: mirror what the extension's Init_<name> installs ---
//     grep -rn "^Init_\|void Init_" ext/
//     then grep the library calls it makes for the globals they set:
//     grep -rniE "MemSetup|SetAllocator|RegisterNode|_default\(|SetErrorFunc|GenericError" ext/
// Custom allocators matter most: they decide heap layout, and therefore what a
// sanitizer can see at all.  A Ruby extension often points the library at Ruby's
// allocator (xxxMemSetup(ruby_xfree, ruby_xmalloc, ruby_xrealloc, ruby_strdup)); in
// the harness those names are stubs, so mirror the hook with malloc/free/realloc/
// strdup, and say so: ruby_xmalloc raises NoMemoryError where malloc returns NULL
// (step 3), and it can run the GC, which the harness never does.
//
// If the real stack keeps ONE context across calls (a streaming compression binding's
// shared decoder context, reset per call), decide which you fuzz: the gate compares
// single-shot runs, where both arms start fresh, so a fresh context per iteration is
// gate-faithful and stable; keeping the context across __AFL_LOOP iterations fuzzes the
// multi-call state the real process accumulates (a bug class of its own: a failed call
// that leaves the shared context mid-frame poisons every later call), at the cost of
// persistent-mode stability.  Say which you chose; the fork driver sidesteps it.
static void harness_init(void) {
  const char* m = getenv("MODE");
  if (m && !strcmp(m, "file")) g_mode = 1;
  if (getenv("ALLOC_CEIL")) g_alloc_ceil = strtoull(getenv("ALLOC_CEIL"), 0, 0);
  if (getenv("WORK_CEIL"))  g_work_ceil  = strtoul(getenv("WORK_CEIL"), 0, 0);
  // LIBRARY_INIT();
  // mirror xxxMemSetup(...) / xxxRegisterXDefault(...) / error handlers here
}
// Free what init created.  The single-shot path calls this before exit so the ASAN
// variant does not die in LeakSanitizer before printing (gate.sh also sets
// detect_leaks=0, but a clean exit is cheaper to reason about).
static void harness_fini(void) {
  // LIBRARY_CLEANUP();
}

static void run_one(const unsigned char* data, size_t len, Result* r) {
  memset(r, 0, sizeof *r);
  r->err[0] = '0';

  // Reset only what is safe to reset.  READ the implementation of any "reset"
  // you call in a loop: an image library's cache-drop call reads like a reset and is
  // really a teardown that leaves a NULL hash table behind.
  // library_error_clear();

  // --- 5. the input buffer: copy into an EXACTLY sized block ---
  // Reading straight out of AFL's shared-memory testcase buffer means an over-read
  // stays inside the shm mapping and is never reported.  And do NOT add a NUL
  // terminator unless the real extension relies on one -- check how it takes the
  // String:
  //   * RSTRING_PTR + RSTRING_LEN / StringValuePtr: length-delimited; copy exactly.
  //     (Ruby usually keeps a terminator after the bytes, but a shared substring does
  //     not have to; a library that reads to NUL is a finding, not a harness choice.)
  //   * StringValueCStr: NUL-terminated, and the real stack raises ArgumentError
  //     ("string contains null byte") for any input with an embedded NUL -- mirror
  //     that rejection (status=1, err=ArgumentError) before the call.
  //   * rb_str_export_to_enc / rb_str_encode / StringValue after #encode in lib/: the
  //     bytes are transcoded first; mirror it or mark those inputs lossy.
  char* input = (char*)malloc(len ? len : 1);
  if (!input) return;
  memcpy(input, data, len);

  // --- 6. call the boundary function, with the option layer mirrored ---
  // The option values almost always come from Ruby, one or two levels above the C:
  // keyword-argument defaults and option bitmasks in lib/**/*.rb (a DEFAULT options
  // constant, a parse(str, opts = {}) wrapper).  Read them there.
  //
  // If the boundary is a METHOD on a wrapped object (TypedData_Get_Struct /
  // Data_Get_Struct of the receiver), do not try to construct the Ruby object: copy
  // the method body here minus its rb_* calls, with a comment naming the source lines,
  // and re-check it when the gem updates.  If the dispatch lives in lib/**/*.rb (which
  // native method, chunk size, fast path vs streaming loop), mirror that state machine
  // here in the same order.
  //
  //   if (over_ceiling(declared_size)) { r->status = 1; set_err(r, "alloc-ceiling"); goto done; }  // opt-in only
  //   status = ext_open_input(&descriptor);
  //   if (status != OK) { r->status = 1; set_err(r, library_error_name(status)); goto done; }

  // --- 7. make the library actually do the work ---
  // An open is not a decode and a parse is not an evaluation.  Lazy/demand-driven
  // libraries return a handle and do nothing until you ask for the result; a
  // harness that stops here fuzzes header parsers while looking perfectly healthy.
  // Force it, then record something only real work could produce.
  //
  // For a callback-driven (event-handler) library, the artifact IS the event stream:
  // append every event and every argument the real handlers read to a buffer
  // (tag, name bytes length-prefixed, attribute pairs in order, text bytes, a
  // position trailer) and hash that; real_harness.rb serialises identically.
  // In a Ruby extension the real handlers are Ruby methods (a handler object's
  // per-event method) called through rb_funcall: the artifact is what those methods
  // receive, after the extension has converted the library's arguments to Strings.
  // For a streaming API fed in chunks, concatenate every output chunk and hash it.
  //
  //   out = force_result(handle, &n);
  //   r->out_len = n; r->out_hash = fnv1a(out, n);

  // --- 8. teardown: copy the library's own cleanup, minus the binding calls ---
  // Check each setter's ownership convention, not just the field: some copy the
  // string, some store your pointer.
  free(input);
}

// ---------------------------------------------------------------------------
// Drivers.  Two binaries from one TU: persistent (default) and fork mode
// (-DNO_PERSISTENT).  Always build both -- the fork binary re-checks every crash
// the persistent one reports, and its `stability` tells you whether persistent mode
// is even usable for this target.
// ---------------------------------------------------------------------------
#if !defined(NO_PERSISTENT) && defined(__AFL_FUZZ_TESTCASE_LEN)
# define HARNESS_PERSISTENT 1
__AFL_FUZZ_INIT();
#endif

int main(int argc, char** argv) {
  harness_init();

  if (argc > 1) {                       // single shot: the gate and triage path
    FILE* f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    if (sz < 0) sz = 0;
    unsigned char* buf = (unsigned char*)malloc((size_t)sz + 1);
    size_t len = fread(buf, 1, (size_t)sz, f);
    fclose(f);

    Result r;
    run_one(buf, len, &r);
    free(buf);

    printf("in_len=%zu status=%d err=%s out_len=%zu out_hash=%016llx lossy=0 invariant=%ld\n",
           len, r.status, r.err, r.out_len, (unsigned long long)r.out_hash, r.invariant);
    harness_fini();

    // Assert ONLY genuinely impossible states here, and only ones you have checked
    // against the library: do not encode "rejected inputs produce no output" (an
    // error-recovering parser does) or "valid inputs produce some" (many do not).
    // The gate judges by comparison against the real stack, not by your guess.
    // keep status < 64: smoke.sh reads 86 and >127 as a crash, the gate reads 124 as a timeout
    return r.status;
  }

#ifdef HARNESS_PERSISTENT
  __AFL_INIT();
  const unsigned char* shm = __AFL_FUZZ_TESTCASE_BUF;
  while (__AFL_LOOP(1000)) {            // cap it: bounds leaks you cannot avoid
    size_t len = (size_t)__AFL_FUZZ_TESTCASE_LEN;
    Result r;
    run_one(shm, len, &r);
    __asm__ volatile("" :: "r"(&r) : "memory");
  }
  return 0;
#else
  fprintf(stderr, "usage: %s <input>\n", argv[0]);
  return 2;
#endif
}
