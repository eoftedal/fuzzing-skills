/* Walk a library's error enum through its own error-string function
 * (X_ErrorString(), X_getErrorName(), a Status::CodeText()) and print
 * "<code> <name-as-token>" per line.  Fill in the two names, build it, run it, and diff
 * column 2 against the `err` values in maps_<base>/.results to get the list of errors
 * your corpus never provokes.
 *
 * Building it: the AFL-instrumented objects in out/<v>/ will NOT link into a plain
 * program (undefined __afl_area_ptr); use the pristine variant's objects, or simply
 * compile the library's error-string source file in with this one.  The function may
 * live in a different source file than the error enum (a "common" file), and it may be
 * C++ (a static member): then rename this file .cc and build with the C++ compiler.
 *
 *   cc -o errenum errenum_template.c <lib>/src/errors.c -I<lib include>      # or the pristine .o files
 *   ./errenum | sort > errs.all
 *   cut -f2 maps_final/.results | grep -oE 'err=[^ ]*' | sort -u | sed 's/err=//' > errs.hit
 *   (lib_err= instead of err= when the binding collapses every error into one message)
 *   comm -23 <(cut -d' ' -f2 errs.all | sort) errs.hit       # never reached, by name
 *
 * The token form (spaces -> '_') matches what the harness template prints for `err`.
 */
#include <stdio.h>
#include <string.h>
/* #include <lib.h>                           e.g. LIB_ErrorString(code)        */
/* #include <lib.h> + <lib_errors.h>          e.g. LIB_getErrorString(code)     */
/* Check the signature: some libraries' obvious *_getErrorName() takes the ENCODED return
 * value (a size_t that is an error only when a predicate says so), not the enum code, and
 * then prints the same filler for every code; use the *_getErrorString(code) that takes
 * the enum, usually beside the enum in a "common" or "errors" source file.           */
/* C++ returning std::string: ERROR_STRING(code) = Status::CodeText((Code)code).c_str()
 * (rename this file .cc); every result is COPIED below before the temporary dies.   */
#define ERROR_STRING(code)  LIBRARY_ErrorString(code)     /* <-- fill in */
#define MAX_CODE            128                           /* <-- past the last enum member: read the enum, some run past 100 */
#define MIN_CODE            (-64)                         /* <-- codes can be NEGATIVE (some decoders number errors below 0): set
                                                             below the lowest member, or 0 when the enum starts there */
int main(void) {
  /* Most such functions return a filler ("unknown error", "unspecified error code") for
   * codes that are not enum members, and it is non-empty, so skip whatever the function
   * says about a code that is certainly out of range. */
  char filler[256] = "", s[256];
  snprintf(filler, sizeof filler, "%s", ERROR_STRING(MAX_CODE) ? ERROR_STRING(MAX_CODE) : "");
  for (int c = MIN_CODE; c < MAX_CODE; c++) {      /* from MIN_CODE: error codes are often negative */
    if (!ERROR_STRING(c)) continue;
    snprintf(s, sizeof s, "%s", ERROR_STRING(c));
    if (!*s) continue;
    if (*filler && !strcmp(s, filler)) continue;
    printf("%d ", c);
    for (const char* p = s; *p; p++) putchar(*p == ' ' ? '_' : *p);
    putchar('\n');
  }
  return 0;
}
