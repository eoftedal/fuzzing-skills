// Build-time proof that the generated stubs abort.  Pick a symbol that appears in
// your stubs.cc: a function stub as SYMBOL, or a data stub (AFL_DATA_STUB) as
// DATA_SYMBOL -- link_harness.sh builds and runs one of each kind that exists.
//
//   afl-clang-fast++ -o stubtest stubtest.cc stubs.o -DSYMBOL='"rb_raise"'
//   afl-clang-fast++ -o stubtest-data stubtest.cc stubs.o -DDATA_SYMBOL='"rb_cObject"'
//   ./stubtest   # must exit non-zero AND print AFL-HARNESS-STUB
//
// Without this, "the gate ran and no stub was hit" is unfalsifiable.
#if defined(SYMBOL)
extern "C" void afl_stub_probe(void) __asm__(SYMBOL);
int main(void) { afl_stub_probe(); return 0; }
#elif defined(DATA_SYMBOL)
extern "C" const unsigned char afl_stub_probe[] __asm__(DATA_SYMBOL);
int main(void) { return *(volatile unsigned long*)afl_stub_probe != 0; }
#else
#error "define SYMBOL (function stub) or DATA_SYMBOL (data stub) from your generated stubs.cc"
#endif
