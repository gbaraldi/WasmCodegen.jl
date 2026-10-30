// node blockers.mjs <env> <js> [item...]: the distinct unsupported constructs of failed builds,
// condensed to (construct, function), with the items each one blocks.
import fs from 'node:fs';
import path from 'node:path';
const dir = path.dirname(new URL(import.meta.url).pathname);
const [env, js, ...want] = process.argv.slice(2);
const by = new Map();
for (const f of fs.readdirSync(path.join(dir, 'out', env, js)).filter((f) => /^[A-Z0-9]+\.json$/.test(f))) {
  const b = JSON.parse(fs.readFileSync(path.join(dir, 'out', env, js, f)));
  if (b.ok || (want.length && !want.includes(b.item))) continue;
  const lines = b.error.split('\n');
  for (let i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('WasmCodegen: unsupported:')) continue;
    let j = i + 1; while (j < lines.length && lines[j].startsWith('    in ')) j++;
    const what = lines[i].replace('WasmCodegen: unsupported: ', '').replace(/\(GMP\) is not in Wasm\)/, '(GMP))').slice(0, 140);
    const where = lines[j - 1].replace(/^\s+in MethodInstance for /, '').replace(/^\s+in /, '').replace(/Base\.JuliaSyntax\./g, 'JS.').slice(0, 110);
    const key = what.replace(/%\d+/g, '%') + ' @ ' + where;
    if (!by.has(key)) by.set(key, new Set());
    by.get(key).add(b.item);
  }
}
for (const [k, s] of [...by].sort((a, b) => b[1].size - a[1].size)) console.log(`[${[...s].sort().join('')}] ${k}`);
