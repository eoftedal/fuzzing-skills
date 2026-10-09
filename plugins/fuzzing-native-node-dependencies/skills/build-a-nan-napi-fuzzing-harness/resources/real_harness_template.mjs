// The real stack, for the fidelity gate and differential triage only -- never for
// fuzzing.  Prints the SAME key=value line the direct harness prints:
//   in_len= status= err= out_len= out_hash= lossy=
//
//   PKG=/path/to/oracle/node_modules/<package> [ADDON=/abs/out/asan/Release/<name>.node] \
//     [ADDON_MATCH=<regex> | ADDON_MAP='<regex>=<path>;...'] [ALLOC_CEIL=<bytes>] \
//     node real_harness.mjs <input>
// With ADDON, run node with the sanitizer runtime preloaded:
//   LD_PRELOAD=$($R/find_asan_rt.sh) ADDON=... node real_harness.mjs <input>
// (fuzz.env's REAL and REAL_ASAN hold both command lines.)
// By hand: `. ./fuzz.env && $REAL <file>` (REAL carries PKG=, which this file needs).
import { readFileSync, existsSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);   // ESM has no `require`

// 1. Load the package as `npm install` delivers it, not your build tree -- your
//    build script overwrites that per variant, and agreeing with an independently
//    installed copy (different version, different compiler) is a far stronger claim.
//    For a binding over SYSTEM libraries, install that oracle with
//    `npm install <pkg> --build-from-source`: the npm prebuilt bundles its own copies of
//    the libraries (other builds of its codecs) and is a different back end.
const PKG = process.env.PKG || '/path/to/oracle/node_modules/<package>';

// 1b. To swap just the addon (e.g. an ASAN build) while keeping the package's own
//     published JS, hook process.dlopen -- not the module loader.  EVERY native addon
//     load funnels through process.dlopen, whichever way the package resolves its
//     binary: `bindings`, `node-gyp-build`, node-pre-gyp, a plain relative require, or a
//     path the package computes itself (a stylesheet-compiler binding requires a path
//     built from its own environment variable).  A Module._load interception on
//     'bindings' never sees that last kind: the swap silently does not happen, the
//     "sanitized" real side runs the prebuilt, and the memory bugs it exists to see vanish.
//       ADDON        the addon to load instead (made absolute here)
//       ADDON_MATCH  regex on the path the package asks for (default /\.node$/): set it
//                    when the package loads SEVERAL addons and only one is yours
//       ADDON_MAP    `regex=path;regex=path`, first match wins: one replacement per addon
//                    (a runtime plus a grammar, a host plus a plugin)
//     The swap is PROVEN, not assumed: with ADDON or ADDON_MAP set, no result line is
//     printed unless a dlopen was actually redirected (ADDON-NOT-SWAPPED otherwise, or
//     ADDON-NEVER-LOADED when the package answered without dlopening any addon), and
//     a single ADDON redirected into two distinct addons is AMBIGUOUS-SWAP.
const ADDON = process.env.ADDON ? path.resolve(process.env.ADDON) : null;
const MATCH = process.env.ADDON_MATCH ? new RegExp(process.env.ADDON_MATCH) : /\.node$/;
const ADDON_MAP = (process.env.ADDON_MAP || '').split(';').filter(Boolean).map((e) => {
  const i = e.indexOf('=');
  return { re: new RegExp(e.slice(0, i)), to: path.resolve(e.slice(i + 1)) };
});
const die = (why) => {   // stderr, "Error:" first so gate.sh / smoke.sh quote it; no result line
  process.stderr.write(`Error: ${why}\n`);
  process.exit(4);
};
for (const p of [ADDON, ...ADDON_MAP.map((m) => m.to)])
  if (p && !existsSync(p)) die(`ADDON-MISSING: ${p} does not exist`);
const loaded = [];              // every addon actually loaded, post-swap
const swappedFrom = new Set();  // the paths the package asked for that were redirected
{
  const orig = process.dlopen;
  process.dlopen = function (...args) {
    const asked = String(args[1]);
    const mapped = ADDON_MAP.find((m) => m.re.test(asked));
    if (mapped)                           { args[1] = mapped.to; swappedFrom.add(path.basename(asked)); }
    else if (ADDON && MATCH.test(asked)) { args[1] = ADDON;     swappedFrom.add(path.basename(asked)); }
    loaded.push(path.basename(String(args[1])));
    return orig.apply(this, args);
  };
}
// Called before the input runs AND before every result line: a package that loads its
// addon lazily (on first call) has not dlopened anything at the first check, so only
// the second one can decide for it.
const checkSwap = (final) => {
  if (!ADDON && !ADDON_MAP.length) return;
  if (swappedFrom.size === 0 && final && loaded.length === 0)
    die('ADDON-NEVER-LOADED: the package produced a result without dlopening any addon ' +
        '(rejected in JavaScript before native code?); nothing was swapped, so no result is printed under ADDON=');
  if (swappedFrom.size === 0 && (final || loaded.length))
    die(`ADDON-NOT-SWAPPED: ADDON is set but no dlopen was redirected (loaded: ${loaded.join(',') || 'none'}). ` +
        'Check ADDON_MATCH against the path the package loads, and that PKG is the package that loads it.');
  if (swappedFrom.size > 1 && !ADDON_MAP.length)
    die(`AMBIGUOUS-SWAP: one ADDON replaced ${[...swappedFrom].join(' and ')}; use ADDON_MATCH or ADDON_MAP`);
};
// `require`, NOT `await import(PKG)`: PKG is a DIRECTORY, and ESM has no directory
// resolution, so `import()` fails with ERR_UNSUPPORTED_DIR_IMPORT for every CJS addon.
const ns  = require(PKG);
const lib = ns && ns.default ? ns.default : ns;
checkSwap(false);

function fnv1a(buf) {
  let h = 0xcbf29ce484222325n;
  const m = 0x100000001b3n, mask = 0xffffffffffffffffn;
  for (let i = 0; i < buf.length; i++) h = ((h ^ BigInt(buf[i])) * m) & mask;
  return h.toString(16).padStart(16, '0');
}
const ZERO = '0'.repeat(16);

// 1c. Attacker-declared allocations (a decompressor's declared content size, an image
//     header's dimensions): NO cap by default.  The package's own behaviour IS the
//     oracle -- node throws a range error above buffer.kMaxLength and an allocation
//     error when the allocator refuses -- and the fuzz run is bounded by the fuzzer's
//     memory limit (afl-fuzz -m, ASAN max_allocation_size_mb), not by a constant here.
//     An invented cap was measured to reject inputs the real package accepts.
//     OPT-IN only, and only at the attacker-declared site: with ALLOC_CEIL=<bytes> set
//     identically on both arms, read the size the package will allocate from the input
//     the same way the direct harness does, and refuse BEFORE the call.  Never wrap
//     Buffer.alloc* globally: that also hits the package's internal buffers and this
//     file's own input copy below.
const ALLOC_CEIL = process.env.ALLOC_CEIL ? Number(process.env.ALLOC_CEIL) : 0;   // 0 = off
const overCeiling = (declared) => ALLOC_CEIL > 0 && declared > ALLOC_CEIL;
// Same for attacker-chosen WORK (a cost/rounds field): WORK_CEIL=<units>, read from the
// input the way the package does, refused BEFORE the call with err=work-ceiling.
const WORK_CEIL = process.env.WORK_CEIL ? Number(process.env.WORK_CEIL) : 0;        // 0 = off
const overWork = (units) => WORK_CEIL > 0 && units > WORK_CEIL;
// const declaredSize = (b) => Number(b.readBigUInt64LE(OFFSET));   // the field the package sizes by

// 2. Re-home the input into an exactly sized, unpooled backing store.  Same bytes
//    and same length, so semantics cannot change -- but Buffer.from() and
//    readFileSync() may hand back a slice of node's shared 8 KiB pool, where a read
//    past the end of the input lands in a neighbour's bytes and ASAN sees nothing.
const raw = readFileSync(process.argv[2]);
const buf = Buffer.allocUnsafeSlow(raw.length);
raw.copy(buf);

// 2b. For a PATH entry point: write the bytes to a fresh temp file and return its path,
//     so every arm takes the same buffer.  `ext` is for a package that sniffs the
//     extension.  Removed at exit, so a gate over thousands of seeds leaves nothing behind.
const tmpDirs = [];
process.on('exit', () => { for (const d of tmpDirs) rmSync(d, { recursive: true, force: true }); });
const asFile = (b, ext = '') => {
  const d = mkdtempSync(path.join(os.tmpdir(), 'real-harness-'));
  tmpDirs.push(d);
  const p = path.join(d, 'input' + ext);
  writeFileSync(p, b);
  return p;
};

const emit = (f) => checkSwap(true) || process.stdout.write(
  `in_len=${raw.length} status=${f.status} err=${f.err ?? 0} out_len=${f.out_len ?? 0} ` +
  `out_hash=${f.out_hash ?? ZERO} lossy=${f.lossy ?? 0}\n`);
// `err` is ONE TOKEN identical to what the direct harness prints, one per error path and
// never per input: the gate compares it and the corpus
// skill's histograms and error inventory key on it.  Never a hash of a message that
// embeds the input -- that makes err unique per seed and useless for the corpus skill.
// Default: e.code when present (numeric or a string code), else a numeric e.errno, else
// the message up to the first ": " (messages shaped "<text>: <argument>" carry the input
// after it), else the whole message; whitespace becomes '_'.  Override it when the input
// sits elsewhere in the message (" at line 3", a quoted fragment) or a stable field
// exists, and print the same token from the direct harness.
// node's own failures come through here too, and the direct harness prints the same
// token: ERR_OUT_OF_RANGE (a Buffer above kMaxLength), ERR_MEMORY_ALLOCATION_FAILED (the
// allocator refused a legal length -- the asan gate's max_allocation_size_mb path),
// ERR_ASSERTION (a package-side assert).
const errToken = (e) => {
  if (typeof e?.code === 'number') return e.code;
  if (typeof e?.code === 'string' && e.code) return e.code.replace(/\s+/g, '_').slice(0, 63);
  if (typeof e?.errno === 'number') return e.errno;
  const m = String(e?.message ?? e), i = m.indexOf(': ');
  return (i > 0 ? m.slice(0, i) : m).replace(/\s+/g, '_').slice(0, 63);
};

// 3. THE CONSUMER CALLS, one arm per entry point, keyed by the harness's MODE value
//    ('default' when MODE is unset).  This object is the chain's shared contract:
//      * the direct harness selects the same entry point from the same MODE value;
//      * the campaign skill records each mode's `entry` as this key (MODE=file -> file);
//      * the triage skill's confirm.mjs ENTRIES is THIS object, pasted unchanged:
//        confirm.mjs also calls each arm with the input buffer and defines the same
//        asFile(b, ext), so a `file` arm needs no edit there.
//    So write the arm once, here, where the gate proves it matches the native call, and
//    name the mode after the entry point it reaches.  Call the package the way a consumer
//    does, with NO options -- the gate compares your mirrored defaults against the real
//    ones -- and no error listener a user would not add.
//    `collected` is the partial-output buffer.  A one-shot arm returns its result and
//    leaves `collected` empty.  A callback arm pushes each serialised event (a Buffer)
//    onto `collected` as it arrives and returns Buffer.concat(collected); when the
//    package throws mid-stream, the catch below still hashes the events delivered before
//    the error (out_len/out_hash; 0 and all-zero when none were).  The direct harness
//    must hash the same partial stream on error (harness_template.cc section 7), or
//    every rejected seed mismatches.
const collected = [];   // callback arms push Buffers here; see above
const ENTRIES = {
  default: (b) => lib.doTheThing(b),                 // SYNC one-shot API: the common case
  // events: (b) => { lib.parse(b, { onEvent: (t, s) => collected.push(Buffer.from(t), Buffer.from(s)) });
  //                  return Buffer.concat(collected); },   // a callback arm
  // file:   (b) => lib.doTheThingFromFile(asFile(b)), // the path entry point (raw bytes, no JS string)
  // string: (b) => lib.doTheThing(b.toString('utf8')), // the JS-string entry point: lossy for invalid UTF-8
};
const MODE = process.env.MODE || 'default';
if (!ENTRIES[MODE]) { process.stderr.write(`Error: no entry for MODE=${MODE}\n`); process.exit(4); }

try {
  // Opt-in allocation ceiling (1c), only when the input declares a size:
  //   if (overCeiling(declaredSize(buf))) { emit({ status: 1, err: 'alloc-ceiling' }); process.exit(1); }
  // An arm may be async (an AsyncWorker entry point returns a Promise): await it, and
  // let a rejection fall into the catch below like a throw.  This file is an ES module,
  // so top-level await is fine.
  let result = ENTRIES[MODE](buf);
  if (result && typeof result.then === 'function') result = await result;
  //
  // STREAMING API (compression bindings): write the whole file as one chunk and
  // collect every 'data' chunk; the JS Transform may re-chunk it internally, and the
  // direct harness mirrors that.  Sketch:
  //   const chunks = []; const s = lib.createStream(...);
  //   s.on('data', c => chunks.push(c)); s.on('error', e => { emit({status:1, err:errToken(e)}); process.exit(1); });
  //   s.on('end', () => { const out = Buffer.concat(chunks); emit({status:0, out_len:out.length, out_hash:fnv1a(out)}); process.exit(0); });
  //   s.end(buf); setTimeout(() => { emit({status:3, err:'timeout'}); process.exit(3); }, 10000);
  //
  // CALLBACK-DRIVEN (SAX) API: register EVERY listener the package offers, serialise
  // each event exactly as the direct harness does (event tag, length-prefixed UTF-8
  // strings, attribute pairs in order, null/true/false, a position trailer), push it
  // onto `collected`, and hash the concatenation.  The event stream IS the artifact, on
  // the error path too.

  // Hash the DEEPEST artifact the API will give you, not a summary: a width and a
  // height can agree while every byte differs.
  const out = Buffer.from(result /* .toString() / .toBuffer() / ... */);

  // `lossy=1` marks the oracle's ceiling: set it when the package cannot report the
  // library's bytes faithfully (a JS-string round trip replacing invalid UTF-8 with
  // U+FFFD, a colour transform, ...).  The gate then drops the affected fields and
  // counts the seed separately instead of silently passing or failing.
  //   * TEXT output: test EVERY string the package handed you, not just the final one --
  //     for an event stream, each name/attribute/text argument as it is serialised
  //     (a U+FFFD inside an element name is as lossy as one in the body).
  //   * BINARY output (decompressed bytes, pixels): a JS string was never involved, so
  //     set lossy = 0; the byte 0xEF 0xBF 0xBD can occur legitimately.
  // A U+FFFD substitution changes the LENGTH too, so gate with SOFT_DROP="out_len out_hash".
  const lossy = typeof result === 'string' && result.includes('\uFFFD') ? 1 : 0;

  // success: hash even an empty output; all-zero out_hash is the error path's "nothing collected"
  emit({ status: 0, out_len: out.length, out_hash: fnv1a(out), lossy });
  process.exit(0);
} catch (e) {
  // the events a callback arm delivered before the error are part of the artifact
  const part = Buffer.concat(collected);
  emit({ status: 1, err: errToken(e), ...(part.length ? { out_len: part.length, out_hash: fnv1a(part) } : {}) });
  process.exit(1);
}
