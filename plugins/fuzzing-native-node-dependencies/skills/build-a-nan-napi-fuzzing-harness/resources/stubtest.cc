// Build-time proof that the generated stubs abort.  Pick any symbol that appears
// in your stubs.cc and put it in SYMBOL.
//
//   afl-clang-fast++ -o stubtest stubtest.cc stubs.o -DSYMBOL='"napi_throw"'
//   ./stubtest   # must exit non-zero AND print AFL-HARNESS-STUB
//
// Without this, "the gate ran and no stub was hit" is unfalsifiable.
#ifndef SYMBOL
#error "define SYMBOL to a symbol present in your generated stubs.cc"
#endif
extern "C" void afl_stub_probe(void) __asm__(SYMBOL);
int main(void) { afl_stub_probe(); return 0; }
