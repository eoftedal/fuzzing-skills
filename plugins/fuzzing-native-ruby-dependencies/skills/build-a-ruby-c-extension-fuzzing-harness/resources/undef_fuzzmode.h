/* afl-clang-fast / afl-cc inject -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION=1 into
 * every compile.  Libraries use that macro to COMPILE OUT checks the shipped build
 * performs (a compression library drops its dictionary-ID check; a regex engine relaxes
 * limits in its parser), so
 * an instrumented library accepts inputs the real extension rejects and the gate fails on
 * exactly the seeds that reach those checks -- or, worse, the gate corpus is too small
 * to reach them and the harness fuzzes a different library.
 *
 * -U on the command line does not help: the wrapper re-adds the define.  Forcing this
 * header with -include (build_ext.sh and link_harness.sh do it for the AFL variants)
 * undefines it after the wrapper's definition.
 *
 * Check it yourself:  echo | afl-clang-fast -dM -E -x c - | grep FUZZING
 * See who cares:      grep -rl FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION <library src>
 */
#undef FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION
