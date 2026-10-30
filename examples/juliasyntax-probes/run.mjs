// node --experimental-wasm-exnref run.mjs <label> <js> <item> [unsafe]
// Runs out/<label>/<js>/<item>[.unsafe].wasm on the corpus, compares its output with the
// native one (ref/<js>/<item>.json), and times 3 more passes over the corpus (best of 3).
// Writes results/<label>/<js>/<item>[.unsafe].json.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
const dir = path.dirname(new URL(import.meta.url).pathname);
const [envname, js, item, unsafe] = process.argv.slice(2);
const stem = item + (unsafe === 'unsafe' ? '.unsafe' : '');
// (the host functions of this repository's WasmCodegen)
const hostDir = '../../js';
const cases = JSON.parse(fs.readFileSync(path.join(dir, 'corpus.json'), 'utf8'));
const ref = JSON.parse(fs.readFileSync(path.join(dir, 'ref', js, item + '.json'), 'utf8'));
const bytes = fs.readFileSync(path.join(dir, 'out', envname, js, stem + '.wasm'));

const t0 = performance.now();
const mod = await WebAssembly.compile(bytes);
const imports = WebAssembly.Module.imports(mod);
let stdout = [];
let inst;
if (WebAssembly.Module.exports(mod).some((x) => x.name === 'memory' && x.kind === 'memory')) {
  // a module for WASI (`Config(host = :wasi)`), with no files and no environment
  const { WASI } = await import('node:wasi');
  const wasi = new WASI({ version: 'preview1', returnOnExit: true, env: {}, args: [], preopens: {} });
  inst = await WebAssembly.instantiate(mod, wasi.getImportObject());
  wasi.initialize(inst);
} else if (imports.length === 0) {
  inst = await WebAssembly.instantiate(mod, {});
} else {
  const { createHost } = await import(path.join(dir, hostDir, 'julia.mjs'));
  const host = createHost({ write: (fd, b) => { for (const x of b) stdout.push(x); } });
  inst = await WebAssembly.instantiate(mod, { julia: host.imports.julia });
  host.attach(inst);
}
const instantiateMs = performance.now() - t0;
const e = inst.exports;
const fn = e['item_' + item];
const modes = [...new Set(ref.results.map((r) => r.mode))];
const srcs = cases.map((c) => Buffer.from(c.src, 'base64'));

function setSrc(src) {
  e.src_resize(src.length);
  for (let i = 0; 4 * i < src.length; i++) {
    const w = src[4 * i] | (src[4 * i + 1] << 8) | (src[4 * i + 2] << 16) | (src[4 * i + 3] << 24);
    e.src_set4(i + 1, w | 0);
  }
}
function readOut(n) {
  const out = Buffer.alloc(n);
  for (let i = 0; 4 * i < n; i++) {
    const w = e.out_word(i + 1);
    for (let k = 0; k < 4 && 4 * i + k < n; k++) out[4 * i + k] = (w >>> (8 * k)) & 0xff;
  }
  return out;
}
function call(m) {
  try {
    return { n: fn(m) };
  } catch (err) {
    if (err instanceof WebAssembly.Exception) return { exc: 'Julia exception' };
    return { trap: String(err && err.message || err) };
  }
}

const counts = { match: 0, mismatch: 0, exc_both: 0, exc: 0, exc_native_only: 0, trap: 0 };
const failures = [];
const refBy = new Map(ref.results.map((r) => [r.case + '\u0000' + r.mode, r]));
for (let ci = 0; ci < cases.length; ci++) {
  setSrc(srcs[ci]);
  for (const m of modes) {
    const r = refBy.get(cases[ci].name + '\u0000' + m);
    const got = call(m);
    let status, detail = '';
    if (got.trap !== undefined) { status = 'trap'; detail = got.trap; }
    else if (got.exc !== undefined) { status = r.exc ? 'exc_both' : 'exc'; detail = r.exc || ''; }
    else if (r.exc) { status = 'exc_native_only'; detail = r.exc; }
    else {
      const out = readOut(got.n);
      const sha = crypto.createHash('sha256').update(out).digest('hex');
      if (sha === r.sha) status = 'match';
      else {
        status = 'mismatch';
        detail = `${out.length} bytes, native ${r.len}`;
        if (r.out !== undefined) {
          const nat = Buffer.from(r.out, 'base64');
          let k = 0;
          while (k < out.length && k < nat.length && out[k] === nat[k]) k++;
          detail += `; first difference at byte ${k}: wasm ${JSON.stringify(out.subarray(Math.max(0, k - 40), k + 60).toString('latin1'))} native ${JSON.stringify(nat.subarray(Math.max(0, k - 40), k + 60).toString('latin1'))}`;
        } else {
          fs.mkdirSync(path.join(dir, 'mismatch'), { recursive: true });
          const f = path.join(dir, 'mismatch', `${envname}-${js}-${stem}-${cases[ci].name.replace(/\//g, '_')}-${m}.out`);
          fs.writeFileSync(f, out);
          detail += `; output written to ${path.relative(dir, f)}`;
        }
      }
    }
    counts[status]++;
    if (status !== 'match' && status !== 'exc_both') failures.push({ case: cases[ci].name, mode: m, status, detail });
  }
}

const times = [];
for (let pass = 0; pass < 3; pass++) {
  let t = 0;
  for (let ci = 0; ci < cases.length; ci++) {
    setSrc(srcs[ci]);
    for (const m of modes) {
      const t1 = performance.now();
      call(m);
      t += performance.now() - t1;
    }
  }
  times.push(t);
}

const verdict = counts.trap ? 'traps' : (counts.mismatch || counts.exc || counts.exc_native_only) ? 'wrong output' : 'correct';
const result = { env: envname, js, item, unsafe: unsafe === 'unsafe', node: process.version, verdict, counts,
                 wasm_bytes: bytes.length, instantiate_ms: instantiateMs, best_ms: Math.min(...times), times_ms: times,
                 native_best_ms: ref.best_ms, failures: failures.slice(0, 50), nfailures: failures.length };
fs.mkdirSync(path.join(dir, 'results', envname, js), { recursive: true });
fs.writeFileSync(path.join(dir, 'results', envname, js, stem + '.json'), JSON.stringify(result, null, 1));
console.log(`${item} (${js}, ${envname}${unsafe === 'unsafe' ? ', unsafe' : ''}, node ${process.version}): ${verdict} ` +
            JSON.stringify(counts) + ` best of 3: ${Math.min(...times).toFixed(1)} ms (native ${ref.best_ms.toFixed(1)} ms)`);
for (const f of failures.slice(0, 8)) console.log(`  ${f.status} ${f.case} mode ${f.mode}: ${f.detail.slice(0, 400)}`);
