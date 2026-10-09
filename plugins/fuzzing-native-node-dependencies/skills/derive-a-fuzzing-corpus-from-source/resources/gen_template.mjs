#!/usr/bin/env node
// Skeleton for a corpus generator.  Copy it, fill in the record builder and the
// families, run it.  The scaffolding already does what every generator needs and
// what every hand-rolled one got wrong at least once:
//
//   * one output file per seed, named <family>-<nnn>-<name>, so validate.sh PREFIX=
//     can slice a family out and a broken family cannot hide among healthy ones;
//   * a MANIFEST written OUTSIDE the corpus directory (a manifest inside it is a seed),
//     mapping each file to the branch, bound or hazard that motivated it;
//   * every written integer CLAMPED to its field width, so a value derived from a
//     deliberately extreme one cannot make the writer throw before the target sees it;
//   * the DECLARED value separated from the ACTUAL layout, so a length field can say
//     0xFFFFFFF0 while the buffer stays small;
//   * a default record that must parse to completion -- byte-diff it against the real
//     writer's output BEFORE writing families (`od -An -tx1` both; see SKILL.md);
//   * de-duplication of identical bytes across families.
//
//   node gen.mjs OUT=./corpus-derived [MANIFEST=./corpus-derived.manifest.tsv] [ONLY=fam]
//   With ONLY=fam the default manifest is ${OUT}.manifest.<fam>.tsv, so iterating on one
//   family does not overwrite the full manifest with that family's rows.
import { writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

const args = Object.fromEntries(process.argv.slice(2).map(a => a.split(/=(.*)/s).slice(0, 2)));
const OUT      = args.OUT ?? './corpus-derived';
const ONLY     = args.ONLY;                       // emit one family, for iterating
const MANIFEST = args.MANIFEST ?? (ONLY ? `${OUT}.manifest.${ONLY}.tsv` : `${OUT}.manifest.tsv`);
mkdirSync(OUT, { recursive: true });

// ---- clamps: every value you WRITE goes through one of these -------------------
const u8  = v => Math.max(0, Math.min(0xff,        Math.floor(Number(v) || 0)));
const u16 = v => Math.max(0, Math.min(0xffff,      Math.floor(Number(v) || 0)));
const u32 = v => Math.max(0, Math.min(0xffffffff,  Math.floor(Number(v) || 0)));
const i32 = v => Math.max(-0x80000000, Math.min(0x7fffffff, Math.floor(Number(v) || 0)));
// 64-bit fields (content sizes, offsets) are BigInt: clamp the same way, write with
// buf.writeBigUInt64LE(u64(v), off).  Boundaries worth a seed each: 2n**32n, 2n**53n
// (the largest exact JS double, which the JS layer may sum sizes in), 2n**63n, 2n**64n-1n.
const U64_MAX = (1n << 64n) - 1n;
const u64 = v => {
  const n = Number(v);
  const b = typeof v === 'bigint' ? v
          : n === Infinity ? U64_MAX : BigInt(Number.isFinite(n) ? Math.floor(n) : 0);
  return b < 0n ? 0n : b > U64_MAX ? U64_MAX : b;
};
// Check every size field's ENCODING against the real writer before deriving from it:
// one frame format stores (size - 256) under one flag value; one compressed container stores
// (n + 1) * 4 in a header length byte.  A wrong encoding rule kills a whole family while every seed "runs".

// ---- emit --------------------------------------------------------------------
const seen = new Map(); const manifest = []; let n = 0;
let family = 'misc';
function fam(name) { family = name; }
function emit(name, bytes, why) {
  if (ONLY && family !== ONLY) return;
  const buf = Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes);
  const key = buf.toString('base64');
  if (seen.has(key)) { manifest.push([family, name, `DUP of ${seen.get(key)}`, why]); return; }
  const file = `${family}-${String(++n).padStart(3, '0')}-${name.replace(/[^A-Za-z0-9._-]+/g, '_')}`;
  writeFileSync(join(OUT, file), buf);
  seen.set(key, file);
  manifest.push([family, file, `${buf.length}B`, why]);
}

// ---- 1. the record builder ----------------------------------------------------
// Defaults produce a record that parses TO COMPLETION.  Every dependent field is
// DERIVED from the code's own rule, never a plausible constant.  Each field can be
// overridden with a declared value that differs from the actual layout.
function mkrecord(o = {}) {
  const version = o.version ?? 1;
  const payload = o.payload ?? Buffer.from('hello');
  const count   = o.count ?? 1;
  // actual layout
  const body    = Buffer.concat([payload]);
  // declared values (what we WRITE), defaulting to the truth
  const declLen = o.declaredLen ?? body.length;
  const hdr = Buffer.alloc(8);
  hdr.write('MAGC', 0, 'ascii');          // replace with the real signature
  hdr.writeUInt8(u8(version), 4);
  hdr.writeUInt8(u8(count), 5);
  hdr.writeUInt16LE(u16(declLen), 6);
  return Buffer.concat([hdr, body]);
}

// ---- 2. families: one axis each, varied from the fully-parsing default ----------
fam('default');
emit('default', mkrecord(), 'fully parsing record; byte-diff this against the real writer first');

fam('sniff');
for (const len of [0, 1, 2, 3, 4]) emit(`len${len}`, mkrecord().subarray(0, len), 'sub-minimum input reaching the sniffer');

fam('version');
for (const v of [0, 1, 2, 0xff]) emit(`v${v}`, mkrecord({ version: v }), 'every accepted value, one unlisted (default: arm)');

fam('len');
for (const d of [0, 1, 4, 5, 6, 0xffff]) emit(`decl${d}`, mkrecord({ declaredLen: d }), 'declared length vs actual: both sides of the boundary');

fam('count');
for (const c of [0, 1, 2, 50, 255]) emit(`count${c}`, mkrecord({ count: c }), 'repetition count is an axis: 1 and ~50 differ');

// ---- 3. manifest, outside the corpus directory ---------------------------------
writeFileSync(MANIFEST, ['family\tfile\tsize\twhy', ...manifest.map(r => r.join('\t'))].join('\n') + '\n');
console.log(`${n} seeds -> ${OUT}  (${manifest.length - n} duplicates dropped; manifest: ${MANIFEST}` +
            (ONLY ? `, family ${ONLY} only; the full manifest is left as it was)` : ')'));
