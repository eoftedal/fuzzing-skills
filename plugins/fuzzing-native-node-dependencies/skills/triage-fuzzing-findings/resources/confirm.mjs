// Confirm one crash against the package AS `npm install` DELIVERS IT, and decide
// whether the package's own error handling catches it.  This is the question the direct
// harness cannot answer: the fuzzer crashes a C++ boundary with node deleted, but a real
// consumer reaches that code through the package's JavaScript, which may wrap the native
// call in try/catch, route failures into a rejected Promise, or convert a native error
// into a thrown JS Error.  A finding a user can never trigger is not a finding.
//
//   PKG=/abs/fresh-npm-install/node_modules/<pkg> [ADDON=/abs/out/asan/Release/x.node] \
//     [ENTRY=<name>] node confirm.mjs <crash file>
//
// Verdict (printed as `verdict=...`, and the process exit code):
//   CLEAN    (0)  the call returned / the Promise resolved with no error at all.  Printed
//                 with `evidence=` -- see "Do not believe a bare CLEAN" below.
//   CAUGHT  (10)  it threw synchronously, or rejected a Promise -- a `try{}catch` or a
//                 `.catch()` at the call site stops it.  A careful consumer is safe.
//   UNCAUGHT(20)  it surfaced ONLY through process 'uncaughtException' /
//                 'unhandledRejection' (an EventEmitter 'error' with no listener, a throw
//                 from an async callback the package did not tie to its Promise).  It
//                 escapes an ordinary try/catch; only a global process handler stops it.
//   HANG    (25)  it neither returned nor errored within TIMEOUT_MS.  An algorithmic DoS
//                 no try/catch can stop.  NOT a clean run.
//   SKIPPED (30)  the input asked the JS layer to allocate more than ALLOC_CEIL, so this
//                 run proves nothing either way.  Re-run with ALLOC_CEIL raised.
//
// A NATIVE crash (SIGSEGV/SIGABRT/SIGBUS, or an ASAN abort) kills node before ANY of these
// can run and before this file prints anything.  No JavaScript handler -- not try/catch,
// not process.on('uncaughtException'), not a domain -- can catch a signal.  confirm.sh
// detects that from node's exit status, and it is the most severe verdict.
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);

const PKG = process.env.PKG || '/path/to/fresh-npm-install/node_modules/<package>';

// ---- swap the ASAN addon under the package's published JS, and PROVE it happened ------
// Hook process.dlopen, not the module loader: EVERY native addon load funnels through it,
// whichever way the package resolves its binary -- `bindings`, `node-gyp-build`,
// node-pre-gyp, a plain relative require, or the package's OWN environment variable
// (a stylesheet-compiler binding requires a path its own code computes, honouring the
// package's own environment variable for its binary path, which a Module._load interception on 'bindings' never sees: the swap silently does not happen
// and the ASAN column becomes a duplicate of the prebuilt column, hiding exactly the
// memory bugs that column exists to find).
// ADDON_MATCH limits the swap when a package loads SEVERAL addons (a runtime plus a
// grammar): set it to a regex matching the one you built.
const ADDON = process.env.ADDON ? path.resolve(process.env.ADDON) : null;
const MATCH = process.env.ADDON_MATCH ? new RegExp(process.env.ADDON_MATCH) : /\.node$/;
// A package can load SEVERAL addons (a parser-runtime binding that loads a separate grammar
// addon; an image-processing binding over system codec libraries, which ships the library
// plus the binding).  One ADDON would then be swapped in for all of them, silently and
// wrongly.  ADDON_MAP handles that case -- `regex=path;regex=path`, first match wins -- and
// if a single ADDON ends up swapped into more than one distinct addon the verdict line says
// AMBIGUOUS-SWAP rather than pretending the column is meaningful.
const ADDON_MAP = (process.env.ADDON_MAP || '').split(';').filter(Boolean).map((e) => {
  const i = e.indexOf('=');
  return { re: new RegExp(e.slice(0, i)), to: path.resolve(e.slice(i + 1)) };
});
const loaded = [];            // every addon the package actually loaded, post-swap
const swappedFrom = new Set();
{
  const orig = process.dlopen;
  process.dlopen = function (...args) {
    const asked = args[1];
    const mapped = ADDON_MAP.find((m) => m.re.test(asked));
    if (mapped)                       { args[1] = mapped.to; swappedFrom.add(path.basename(asked)); }
    else if (ADDON && MATCH.test(asked)) { args[1] = ADDON;    swappedFrom.add(path.basename(asked)); }
    loaded.push(path.basename(args[1]));
    return orig.apply(this, args);
  };
}

// The attacker-declared-allocation ceiling, in bytes: confirm.sh sets ALLOC_CEIL to the
// SAME number as the sanitizer's max_allocation_size_mb for this bucket, so a declared-huge
// input fails the same bounded way in the JS layer and in the addon instead of hitting two
// different limits (an earlier default of 64 MiB here made the JS layer SKIP inputs the
// ASAN column reported as allocation-size-too-big).  Unset = no ceiling, as the harness
// skill's templates do.  The throw is TAGGED, because absorbing it into CAUGHT would
// manufacture the one verdict that says "a careful consumer is safe" out of a limit this
// script imposed itself.
const ALLOC_CEIL = process.env.ALLOC_CEIL ? Number(process.env.ALLOC_CEIL) : Infinity;
for (const fn of ['allocUnsafe', 'alloc', 'allocUnsafeSlow']) {
  const orig = Buffer[fn];
  Buffer[fn] = function (size, ...rest) {
    if (size > ALLOC_CEIL) { const e = new Error('alloc-ceiling'); e.code = 'alloc-ceiling'; throw e; }
    return orig.call(Buffer, size, ...rest);
  };
}

// `require`, NOT `await import(PKG)`: PKG is a DIRECTORY, ESM has no directory resolution,
// and import() would bypass the CJS loader the addon travels through.
const ns  = require(PKG);
const lib = ns && ns.default ? ns.default : ns;
const tok = (e) => String(e && (e.code ?? e.message) || e).replace(/\s+/g, '_').slice(0, 60);

// Re-home the input into an exactly sized, UNPOOLED backing store.  readFileSync() and
// Buffer.from() may hand back a slice of node's shared 8 KiB pool, where a read past the
// end of the input lands in a neighbour's bytes and ASAN sees nothing at all.  This line
// is what keeps a 1-byte over-read observable on this side; do not "simplify" it away.
const raw = readFileSync(process.argv[2]);
const buf = Buffer.allocUnsafeSlow(raw.length); raw.copy(buf);

// Does the public API's byte space even contain this input?  A JS-string argument carries
// the bytes as `Buffer -> toString('utf8') -> UTF-8`, so invalid UTF-8 becomes U+FFFD and
// everything after the first NUL is cut off.  Computed, not asserted: a CLEAN row with
// expressible=0 is explained by the byte space (and belongs to the raw-byte entry point
// below), while a CLEAN row with expressible=1 is a harness defect to send back.
const expressible = Buffer.from(buf.toString('utf8'), 'utf8').equals(buf) && !buf.includes(0);

// A file holding the exact bytes, for an entry point that takes a path instead of a
// Buffer.  That path is not a formality: 25 of a stylesheet-compiler binding's 111
// confirmed crashes were reachable ONLY through its file-path entry point, because the
// binding's string entry point replaces invalid UTF-8 with U+FFFD before the library sees a byte.
const asFile = (ext = '') => {
  const p = path.join(mkdtempSync(path.join(os.tmpdir(), 'confirm-')), 'input' + ext);
  writeFileSync(p, buf); return p;
};

let done = false;
const finish = (v, code, extra = '') => {
  if (done) return; done = true;
  const swap = !ADDON && !ADDON_MAP.length ? 'absent'
             : swappedFrom.size === 0        ? 'NOT-SWAPPED'
             : (swappedFrom.size > 1 && !ADDON_MAP.length) ? 'AMBIGUOUS-SWAP'
             : 'swapped';
  process.stdout.write(`verdict=${v} entry=${process.env.ENTRY || 'default'} ` +
    `addon=${swap} loaded=${loaded.join(',') || 'none'} expressible=${expressible ? 1 : 0}${extra}\n`);
  process.exit(code);
};
// These fire only when nothing at the call site caught it.  They rank as UNCAUGHT, below
// a native crash and above a clean catch.
process.on('uncaughtException',  (e) => tok(e) === 'alloc-ceiling'
  ? finish('SKIPPED', 30, ' note=alloc-ceiling')
  : finish('UNCAUGHT', 20, ` via=uncaughtException err=${tok(e)}`));
process.on('unhandledRejection', (e) => finish('UNCAUGHT', 20, ` via=unhandledRejection err=${tok(e)}`));

// Do not believe a bare CLEAN: a mis-wired consumer call returns successfully while
// decoding nothing, and then every crash in the table reads CLEAN and gets dropped.
// An image-decoding binding's first JS harness exited 0 for 18 files that had all failed,
// because the image object's `complete` getter it checked is hardcoded `return true`.  So every CLEAN carries
// evidence of what the call actually produced, and confirm.sh runs a known-good seed
// through each column before it believes a column of CLEANs.
const describe = (r) => {
  try {
    if (r == null) return `type=${r === null ? 'null' : 'undefined'}`;
    if (Buffer.isBuffer(r)) return `bytes=${r.length}`;
    if (typeof r === 'string') return `chars=${r.length}`;
    if (typeof r === 'object') {
      for (const k of ['css', 'data', 'buffer', 'output', 'length', 'width'])
        if (r[k] != null) return `${k}=${r[k].length ?? r[k]}`;
      return `keys=${Object.keys(r).slice(0, 4).join('|')}`;
    }
    return `value=${String(r).slice(0, 30)}`;
  } catch { return 'undescribable'; }
};

// An input that neither returns nor errors is a DoS, not a clean run.  Unref'd so a
// synchronous API that already answered does not wait it out.
setTimeout(() => finish('HANG', 25, ` note=no-answer-in-${process.env.TIMEOUT_MS ?? 10000}ms`),
           Number(process.env.TIMEOUT_MS ?? 10000)).unref();

// ---- THE CONSUMER CALLS ---------------------------------------------------------------
// One arm per entry point the binding exposes over the same engine, selected by ENTRY.
// Harness EVERY one: a string argument and a raw-bytes/path argument carry different byte
// spaces, and sync and async arms run on different threads with different stack limits.
// Each arm is exactly how a user invokes the package -- the same calls real_harness.mjs
// made for the gate, with NO options and NO error listener you would not expect a user to
// add.  Adding a `.on('error', ...)` here manufactures a CAUGHT verdict; leave it off so
// an EventEmitter that emits 'error' with no listener shows up honestly as UNCAUGHT.
//
// AN ARM THAT RETURNS undefined MUST ANSWER FROM ITS OWN CALLBACKS.  Nothing below calls
// finish() for an undefined return (that is the mis-wired-call trap), so an arm that
// forgets runs into the HANG timeout and reports an algorithmic DoS that does not exist.
// For the callback-property shape -- `obj.onload` / `obj.onerror`, the commonest NAN/N-API
// idiom and the one image-decoding bindings use -- the error IS delivered to a callback the consumer
// supplied, so it is CAUGHT (a consumer who wires onerror is safe), not UNCAUGHT and
// certainly not HANG.  `errback`/`okback` below are those two arms.
const errback = (e) => finish('CAUGHT', 10, ` via=callback err=${tok(e)}`);
const okback  = (r) => finish('CLEAN', 0, ` evidence=${describe(r)}`);
const ENTRIES = {
  default: () => lib.doTheThing(buf),
  // Uncomment / adapt the arms the package actually has, and confirm each:
  // file:  () => lib.doTheThingFromFile(asFile('.ext')),   // the RAW-BYTE path
  // async: () => lib.doTheThingAsync(buf),                 // libuv threadpool, own stack
  // callback: () => { const obj = new lib.Thing();         // the callback-property shape
  //                   obj.onerror = errback;               // the consumer's own handler
  //                   obj.onload  = () => okback(obj);
  //                   obj.src = buf; },                    // returns undefined
  // stream: () => { const s = lib.createStream();          // NO .on('error')
  //                 s.on('data', () => {}); s.on('end', () => okback('stream-end'));
  //                 s.end(buf); },
};
// ---------------------------------------------------------------------------------------

const entry = process.env.ENTRY || 'default';
const call = ENTRIES[entry];
if (!call) { process.stdout.write(`verdict=ERROR no-such-entry=${entry}\n`); process.exit(40); }

try {
  const result = call();
  if (result && typeof result.then === 'function') {
    result.then((r) => finish('CLEAN', 0, ` evidence=${describe(r)}`),
                (e) => finish('CAUGHT', 10, ` err=${tok(e)}`));
  } else if (result !== undefined) {
    finish('CLEAN', 0, ` evidence=${describe(result)}`);
  }
  // result === undefined: an emitter/callback arm answers through its own handlers or the
  // HANG timeout.  Do NOT call finish('CLEAN') here -- that is the mis-wired-call trap.
} catch (e) {
  if (tok(e) === 'alloc-ceiling') finish('SKIPPED', 30, ' note=alloc-ceiling');
  else finish('CAUGHT', 10, ` err=${tok(e)}`);   // a plain try/catch at the call site stops it
}
