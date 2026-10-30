// node summarize.mjs: the matrix of out/*/*/*.json (compilations) and results/*/*/*.json
// (runs), as Markdown.
import fs from 'node:fs';
import path from 'node:path';
const dir = path.dirname(new URL(import.meta.url).pathname);
const read = (f) => (fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, 'utf8')) : null);
const items = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'H2', 'I'];
// (the labels of the builds, in the order they were made)
const envs = fs.readdirSync(path.join(dir, 'out')).sort((a, b) => fs.statSync(path.join(dir, 'out', a)).mtimeMs - fs.statSync(path.join(dir, 'out', b)).mtimeMs);
const kb = (n) => `${(n / 1024).toFixed(0)} KB`;

function cell(env, js, item) {
  const b = read(path.join(dir, 'out', env, js, item + '.json'));
  if (!b) return null;
  if (!b.ok) {
    const u = read(path.join(dir, 'out', env, js, item + '.unsafe.json'));
    const r = read(path.join(dir, 'results', env, js, item + '.unsafe.json'));
    const m = /(\d+) unsupported constructs \((\d+) distinct\)/.exec(b.error);
    let s = `doesn't compile (${m ? `${m[2]} distinct unsupported` : b.error_type})`;
    if (r) s += `; unsafe build: ${r.verdict} (${r.counts.match + r.counts.exc_both}/${Object.values(r.counts).reduce((a, x) => a + x, 0)} runs ok)`;
    else if (u && !u.ok) s += '; unsafe build fails too';
    return { s, b };
  }
  const r = read(path.join(dir, 'results', env, js, item + '.json'));
  if (!r) return { s: `compiles (${kb(b.bytes)}), not run`, b };
  const n = Object.values(r.counts).reduce((a, x) => a + x, 0);
  const v = r.verdict === 'correct' ? 'compiles + correct' : r.verdict === 'traps' ? 'compiles, traps' : 'compiles, wrong output';
  return { s: `${v} (${r.counts.match + r.counts.exc_both}/${n})`, b, r };
}

for (const js of ['base', 'reg']) {
  console.log(`\n### ${js === 'base' ? 'Base.JuliaSyntax (Julia 1.13.3)' : 'JuliaSyntax.jl (registered)'}\n`);
  console.log('| Item | ' + envs.map((e) => e).join(' | ') + ' | size | compile (s) | Wasm best of 3 | native best of 3 | ratio |');
  console.log('|---|' + envs.map(() => '---').join('|') + '|---|---|---|---|---|');
  for (const item of items) {
    const cells = envs.map((e) => cell(e, js, item));
    if (cells.every((c) => !c)) continue;
    const best = cells[2]?.r ? cells[2] : cells[1]?.r ? cells[1] : cells[0]?.r ? cells[0] : null;
    const perf = best ? `${kb(best.b.bytes)} | ${best.b.seconds.toFixed(0)} | ${best.r.best_ms.toFixed(0)} ms | ${best.r.native_best_ms.toFixed(0)} ms | ${(best.r.best_ms / best.r.native_best_ms).toFixed(1)}×` : ' | | | | ';
    console.log(`| ${item} | ` + cells.map((c) => (c ? c.s : '—')).join(' | ') + ` | ${perf} |`);
  }
}
