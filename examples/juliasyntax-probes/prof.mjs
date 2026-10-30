// node --experimental-wasm-exnref --cpu-prof --cpu-prof-dir=prof prof.mjs <env> <js> <item> [passes]
// Runs the item over the corpus `passes` times (default 10) for a CPU profile; with
// `summary <file.cpuprofile>` instead, the functions by self time.
import fs from 'node:fs';
import path from 'node:path';
const dir = path.dirname(new URL(import.meta.url).pathname);
const args = process.argv.slice(2);

if (args[0] === 'summary') {
  const p = JSON.parse(fs.readFileSync(args[1], 'utf8'));
  const self = new Map();
  const byId = new Map(p.nodes.map((n) => [n.id, n]));
  const dt = new Map();
  for (let i = 0; i < p.samples.length; i++) dt.set(p.samples[i], (dt.get(p.samples[i]) || 0) + (p.timeDeltas[i] || 0));
  let total = 0;
  for (const [id, t] of dt) {
    const n = byId.get(id);
    const name = n.callFrame.functionName || `(${n.callFrame.url.split('/').pop()}:${n.callFrame.lineNumber})`;
    self.set(name, (self.get(name) || 0) + t);
    total += t;
  }
  const top = [...self].sort((a, b) => b[1] - a[1]).slice(0, +(args[2] || 30));
  for (const [name, t] of top) console.log(`${(100 * t / total).toFixed(1).padStart(5)}%  ${(t / 1000).toFixed(0).padStart(6)} ms  ${name.slice(0, 150)}`);
  process.exit(0);
}

const [envname, js, item, passes = '10'] = args;
const cases = JSON.parse(fs.readFileSync(path.join(dir, 'corpus.json'), 'utf8'));
const ref = JSON.parse(fs.readFileSync(path.join(dir, 'ref', js, item + '.json'), 'utf8'));
const mod = await WebAssembly.compile(fs.readFileSync(path.join(dir, 'out', envname, js, item + '.wasm')));
const instance = await WebAssembly.instantiate(mod, {});
const e = instance.exports;
const fn = e['item_' + item];
const modes = [...new Set(ref.results.map((r) => r.mode))];
const srcs = cases.map((c) => Buffer.from(c.src, 'base64'));
function setSrc(src) {
  e.src_resize(src.length);
  for (let i = 0; 4 * i < src.length; i++)
    e.src_set4(i + 1, (src[4 * i] | (src[4 * i + 1] << 8) | (src[4 * i + 2] << 16) | (src[4 * i + 3] << 24)) | 0);
}
let t = 0;
for (let p = 0; p < +passes; p++) {
  for (const src of srcs) {
    setSrc(src);
    for (const m of modes) { const t0 = performance.now(); fn(m); t += performance.now() - t0; }
  }
}
console.log(`${item} (${envname}): ${passes} passes, ${(t / +passes).toFixed(1)} ms per pass in the item's calls`);
