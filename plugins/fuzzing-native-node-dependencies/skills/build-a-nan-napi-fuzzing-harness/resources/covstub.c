/* Weak no-op coverage symbols.  Only needed when the dependency is a SEPARATE
 * SHARED LIBRARY that you instrument yourself (an image-processing library, a codec, a system .so you
 * rebuilt) rather than object files compiled into the addon.
 *
 * Why: instrument that library with
 *     clang -fsanitize-coverage=trace-pc-guard
 * which leaves __sanitizer_cov_trace_pc_guard{,_init} undefined.  Shared libraries
 * can tolerate that (meson -Db_lundef=false, or just no -Wl,--no-undefined), but
 * most projects also build executables that cannot, and giving those the real AFL
 * runtime would put two runtimes in one process -- the "forkserver is already up"
 * FATAL.
 *
 * Link this into every target of that library instead.  It costs nothing at
 * runtime: default visibility means the calls go through the PLT, so the real AFL
 * runtime in your harness interposes at load time.  Verify rather than assume --
 * compare afl-fuzz's reported map size and corpus growth against a build that left
 * the symbols undefined; they should be identical.
 *
 * Payoff: ONE instrumented build of the library serves both link products -- your
 * AFL harness (real runtime, full coverage) and the addon loaded by plain node
 * (stubs used, no coverage, no forkserver, loads with no special handling).
 *
 *   clang -O2 -fPIC -c covstub.c -o covstub.o
 *   meson setup build -Db_lundef=false \
 *       -Dc_args="-fsanitize-coverage=trace-pc-guard" \
 *       -Dc_link_args="/path/to/covstub.o"      # same for cpp_args/cpp_link_args
 */
__attribute__((weak)) void __sanitizer_cov_trace_pc_guard(unsigned int *guard) {
	(void) guard;
}
__attribute__((weak)) void __sanitizer_cov_trace_pc_guard_init(unsigned int *start,
	unsigned int *stop) {
	(void) start;
	(void) stop;
}
