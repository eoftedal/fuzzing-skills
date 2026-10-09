# Bug patterns to hold in mind while reading

SKILL.md step 4 points here. Each row is a code shape that breaks, why, and the seeds
that reach it. Seeds written from this table are expected to crash the sanitized harness
(step 5); they stay in the deliverable under the seed policy.

| Shape | Why it breaks | Seeds to write |
|---|---|---|
| Range check **before** a sign flip (`if (h > MAX) err; if (h < 0) h = -h;`) | the negation reintroduces the excluded value | large negatives for every signed field, especially `INT_MIN` |
| Allocation size computed in `int` from input fields | overflows long before any field looks unreasonable | factor backwards so the product **wraps to 0 or small positive** |
| `new T[n]` without `nothrow` plus a null check | plain `new[]` throws, so the guard is dead code | an unreasonable size aborts the process |
| `new (nothrow) T[n]` where arithmetic **wraps to 0** | allocation succeeds, every guard passes | a *negative* size is caught, zero is not |
| Two reader primitives, one checked and one not | some call site relies on one up-front check | pass the up-front check, then read more than was validated |
| A reader with no bounds checks plus a separate `hasBytes()` | a caller that does not use it; `_idx + n` wraps | an index so large the wrap reports "true" |
| Unsigned underflow in relative offsets (`skip(read32() - 8)`) | `value < constant` gives ~4 G | that field at `0`, `1`, `constant-1`, `UINT_MAX` |
| Table indexed by a raw byte, sized by a count field | index 0..255 into a 2-entry table | minimum legal table size, maximum index values |
| Loop bound from one structure, memory sized by another | declared vs actual, container vs element | mismatch the pair |
| Error paths that release without clearing the pointer | shared cleanup frees again | reach each early return |
| Anything parsed **before** validation | hand-written, rarely reviewed, cheap to reach | two bytes of magic plus crafted metadata |

Verify allocator behaviour on *your* toolchain with a ten-line program rather than
reasoning about it.
