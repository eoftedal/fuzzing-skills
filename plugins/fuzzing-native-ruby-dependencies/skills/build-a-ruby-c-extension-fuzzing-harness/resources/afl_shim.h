/* Persistent-mode macros for a harness TU that CANNOT be compiled by afl-clang-fast.
 *
 * You normally do not need this: afl-clang-fast injects __AFL_INIT/__AFL_LOOP itself.
 * Use it when the extension's own headers (or a header it pulls in) refuse to compile
 * under clang at all but g++ accepts them.  The case that motivated it is from the Node
 * sibling plugin (node-addon-api 3.x: clang rejects an out-of-range enum static_cast
 * as a non-constant expression regardless of -std=); whether any Ruby extension
 * needs it is unverified on Ruby.  Compile the harness TU with g++ and still LINK with
 * afl-clang-fast++ -- the runtime ends up in the executable either way.
 *
 *   g++      -c -o harness.o harness.cc <lift_flags.sh flags>   # no instrumentation
 *   afl-clang-fast++ -o harness harness.o <extension objs> stubs.o <lib.a>
 *
 * Coverage then comes from the instrumented LIBRARY, not from the harness TU, which
 * is what you care about anyway.
 *
 * The two magic strings are not decoration: afl-fuzz greps the target binary for
 * ##SIG_AFL_PERSISTENT## to decide whether to drive it in persistent mode.  Omit them
 * and the child loops while afl-fuzz waits for it to exit, so every input is reported
 * as a crash or a timeout.  Copied verbatim from
 *     AFL_DEBUG=1 afl-clang-fast -c -x c /dev/null
 * so they stay in step with the installed AFL++; re-check after an AFL upgrade.
 *
 * ALL FIVE macros matter.  harness_template.cc enables persistent mode only when
 * __AFL_FUZZ_TESTCASE_LEN is defined, so a shim that supplies just __AFL_INIT and
 * __AFL_LOOP turns the "persistent" binary into a usage-printing fork binary without
 * any error.  Check with
 *     strings harness | grep -c SIG_AFL_PERSISTENT      # must be non-zero
 */
#ifndef AFL_SHIM_H
#define AFL_SHIM_H

#ifndef __AFL_INIT
#define __AFL_INIT() do { \
  static volatile const char *_A __attribute__((used,unused)); \
  _A = (const char*)"##SIG_AFL_DEFER_FORKSRV##"; \
  __attribute__((visibility("default"))) void _I(void) __asm__("__afl_manual_init"); \
  _I(); } while (0)
#endif

#ifndef __AFL_LOOP
#define __AFL_LOOP(_A) ({ \
  static volatile const char *_B __attribute__((used,unused)); \
  _B = (const char*)"##SIG_AFL_PERSISTENT##"; \
  extern __attribute__((visibility("default"))) int __afl_connected; \
  __attribute__((visibility("default"))) int _L(unsigned int) __asm__("__afl_persistent_loop"); \
  _L(__afl_connected ? _A : 1); })
#endif

#ifndef __AFL_FUZZ_INIT
#include <unistd.h>
#define __AFL_FUZZ_INIT() int __afl_sharedmem_fuzzing = 1;extern __attribute__((visibility("default"))) unsigned int *__afl_fuzz_len;extern __attribute__((visibility("default"))) unsigned char *__afl_fuzz_ptr;unsigned char __afl_fuzz_alt[1048576];unsigned char *__afl_fuzz_alt_ptr = __afl_fuzz_alt;
#define __AFL_FUZZ_TESTCASE_BUF (__afl_fuzz_ptr ? __afl_fuzz_ptr : __afl_fuzz_alt_ptr)
#define __AFL_FUZZ_TESTCASE_LEN (__afl_fuzz_ptr ? *__afl_fuzz_len : (*__afl_fuzz_len = read(0, __afl_fuzz_alt_ptr, 1048576)) == 0xffffffff ? 0 : *__afl_fuzz_len)
#endif

#endif
