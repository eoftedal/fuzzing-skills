// Skeleton for a direct AFL++ harness against a NAN/N-API dependency.
// Replace the marked sections; the structure around them is what you want.
// Each section you MUST edit (1 the headers, 4 the MODE switch and library init,
// 6 the boundary call, 7 forcing the work) carries an #error line, so this file does
// not compile until all four are filled in: delete each line with its section.  The
// rest (the drivers, fnv1a, set_err) may legitimately stay as it is.
//
// Build BOTH binaries from this one file with $R/link_harness.sh, which
// compiles it twice (persistent, and -DNO_PERSISTENT for the fork twin) with the
// flags lifted from the addon's generated makefile.  -D feature macros and -fno-rtti
// matter: the latter must match the object you link.
//
// OUTPUT CONTRACT (single-shot mode): ONE line of key=value pairs,
//   in_len= status= err= out_len= out_hash= lossy= invariant=
// The real-stack harness prints the same keys; gate.sh compares the ones you name in
// FIELDS, and the corpus skill's validate.sh groups seeds by `err`.
//   status    0 ok, 1 rejected: your own small enum
//   err       the LIBRARY's own error, as ONE TOKEN, identical on both sides:
//             its numeric code if the package exposes one (e.code / a status enum),
//             otherwise its error NAME or message with spaces replaced by '_'
//             (the library's own error-string function).  "0" when status == 0.
//             Never a hash of a message that embeds the input: that makes err unique
//             per seed and useless for the corpus skill's histograms.
//   lossy     always 0 on this side; the real stack sets 1 when it cannot report faithfully

// --- 1. the library's own headers, and the addon header holding your boundary ---
// #include <library.h>
// #include "common.h"        // the addon's header; it may pull in napi.h/nan.h --
//                            // fine, you never call them, the stubs catch it.
#error "harness_template: fill in section 1 (the library headers) and delete this line"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

// --- 2. anything the real stack reaches only through the binding must be
//        unreachable here, and must say so loudly rather than returning ---
static void binding_path_reached(const char* what) {
  (void)!write(2, "AFL-HARNESS-V8PATH: ", 20);
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
// header's dimensions): NO cap by default.  Mirror what node itself does, with node's own
// error tokens so the gate agrees:
//   * above buffer.kMaxLength: node throws ERR_OUT_OF_RANGE.  A C harness cannot ask node
//     at run time, so the value comes in at build time and is never defaulted:
//       link_harness.sh ... EXTRA_FLAGS="-DNODE_KMAXLENGTH=$(node -p 'require(\"buffer\").kMaxLength')"
//       #ifndef NODE_KMAXLENGTH
//       #error "pass -DNODE_KMAXLENGTH=$(node -p 'require(\"buffer\").kMaxLength')"
//       #endif
//   * a legal length the allocator refuses (malloc returns NULL under ASAN's
//     max_allocation_size_mb): node throws ERR_MEMORY_ALLOCATION_FAILED; the package's own
//     error path, if it has one, comes after that.
// Then let the FUZZER bound the run (afl-fuzz -m for the plain
// build, ASAN max_allocation_size_mb + allocator_may_return_null=1 for the sanitized
// one, which campaign.sh sets from ALLOC_CAP_MB).  An invented cap rejects inputs the
// real package accepts.  See references/four-layers.md, layer 2.
// OPT-IN only: ALLOC_CEIL=<bytes>, set identically for real_harness.mjs, refuses
// above it AT THE ATTACKER-DECLARED SITE ONLY (call over_ceiling() where you mirror
// that allocation, and report err=alloc-ceiling).  Never on malloc in general.
static size_t g_alloc_ceil = 0;    /* 0 = off */
static inline bool over_ceiling(size_t declared) { return g_alloc_ceil && declared > g_alloc_ceil; }
// Attacker-chosen WORK (a cost/rounds exponent, an iteration count in the input) is the
// same thing in time: mirror the package's own bound if it has one, else an OPT-IN
// WORK_CEIL=<units> applied at that field on both arms (err=work-ceiling), never a silent
// clamp.  An unbounded one is a finding for triage (input-controlled work factor).
static unsigned long g_work_ceil = 0;  /* 0 = off; e.g. the maximum cost exponent to run */
static inline bool over_work(unsigned long units) { return g_work_ceil && units > g_work_ceil; }

struct Result {
  int      status;           // 0 ok, 1 rejected, ... ; your own small enum
  char     err[64];          // the library's own error token; "0" when status == 0
  size_t   out_len;
  uint64_t out_hash;
  long     invariant;        // e.g. the addon's node/alloc counter delta; want 0
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

// --- 4. module init: mirror what the addon's init block installs ---
//     grep -rn "NAN_MODULE_INIT\|NAPI_MODULE_INIT\|napi_register_module_v1" src/
//     then grep the library for the globals it sets:
//     grep -rniE "MemSetup|SetAllocator|RegisterNode|_default\(|SetErrorFunc" src/
// Custom allocators matter most: they decide heap layout, and therefore what a
// sanitizer can see at all.
//
// If the real stack keeps ONE context across calls (a streaming compression binding's
// shared decoder context, reset per call), decide which you fuzz: the gate compares
// single-shot runs, where both arms start fresh, so a fresh context per iteration is
// gate-faithful and stable; keeping the context across __AFL_LOOP iterations fuzzes the
// multi-call state the real process accumulates (a bug class of its own: a failed call
// that leaves the shared context mid-frame poisons every later call), at the cost of
// persistent-mode stability.  Say which you chose; the fork driver sidesteps it.
// Library-wide caches that grow across iterations (name or symbol caches, hash tables)
// are a common source of stability in the low 90s; they are not a harness bug, the
// campaign's fork fallback handles them.
static void harness_init(void) {
#error "harness_template: fill in section 4 (the MODE switch and library init in harness_init) and delete this line"
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
  // terminator unless the real binding does -- check how the binding hands the
  // buffer over (node::Buffer::Data() is raw and unterminated; a JS string via
  // Nan::Utf8String/napi_get_value_string_utf8 is NUL-terminated and transcoded).
  char* input = (char*)malloc(len ? len : 1);
  if (!input) return;
  memcpy(input, data, len);

  // --- 6. call the boundary function, with the option layer mirrored ---
  // The option values almost always come from JavaScript, one or two levels above
  // the C++.  Look for a default-constructed descriptor struct in the addon first:
  // it often already encodes the documented defaults exactly.
  //
  // If the boundary is a METHOD of an ObjectWrap / Nan::ObjectWrap class, do not try
  // to construct the object: copy the method body here minus its runtime calls, with
  // a comment naming the source lines, and re-check it when the package updates.
  // If the dispatch lives in lib/*.js (which native call, how big a buffer, fast path
  // vs streaming loop), mirror that state machine here in the same order.
  //
  //   if (over_ceiling(declared_size)) { r->status = 1; set_err(r, "alloc-ceiling"); goto done; }  // opt-in only
  //   status = addon_ns::OpenInput(&descriptor);
  //   if (status != OK) { r->status = 1; set_err(r, library_error_name(status)); goto done; }
#error "harness_template: fill in section 6 (the boundary call) and delete this line"

  // --- 7. make the library actually do the work ---
  // An open is not a decode and a parse is not an evaluation.  Lazy/demand-driven
  // libraries return a handle and do nothing until you ask for the result; a
  // harness that stops here fuzzes header parsers while looking perfectly healthy.
  // Force it, then record something only real work could produce.
  //
  // For a callback-driven (SAX-style) library, the artifact IS the event stream:
  // append every event and every argument the real handlers read to a buffer
  // (tag, name bytes length-prefixed, attribute pairs in order, text bytes, a
  // position trailer) and hash that; real_harness.mjs serialises identically.
  // On an error mid-stream, hash the events delivered so far, exactly as the real
  // side does (real_harness.mjs keeps them in `collected`), so rejected seeds compare too:
  // status=1, err=<token>, out_len/out_hash over the partial stream; out_len=0 and
  // out_hash=0 only on this ERROR path when nothing was collected.  On SUCCESS always
  // hash the output, even when empty (fnv1a of nothing), as both real templates do.
  // For a streaming API fed in chunks, concatenate every output chunk and hash it.
  //
  //   out = force_result(handle, &n);
  //   r->out_len = n; r->out_hash = fnv1a(out, n);
#error "harness_template: fill in section 7 (force the work, hash the artifact) and delete this line"

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
