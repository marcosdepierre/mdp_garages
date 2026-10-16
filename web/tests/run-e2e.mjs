// Starts the Vite dev server (mock mode) on a free port, runs every tests/*.e2e.mjs, then stops it.
// Usage: npm run test:e2e   (CI-ready: exits non-zero on failure). Needs Chrome (CHROME_PATH, default /usr/bin/google-chrome).
import { createServer } from 'vite';
import { readdirSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const server = await createServer({ root, logLevel: 'error', server: { port: 0, strictPort: false } });
await server.listen();
const url = server.resolvedUrls.local[0].replace(/\/$/, '');
// warm-up: first request triggers dependency optimisation
for (let i = 0; i < 3; i++) { try { await fetch(url + '/'); await fetch(url + '/src/main.tsx'); break; } catch { await new Promise((r) => setTimeout(r, 1000)); } }
let failed = 0;
for (const f of readdirSync(path.join(root, 'tests')).filter((f) => f.endsWith('.e2e.mjs')).sort()) {
  console.log(`\n▶ ${f}`);
  // async spawn: the Vite server lives in THIS process and must keep serving while the suite runs
  const code = await new Promise((res) => spawn(process.execPath, [path.join(root, 'tests', f)], { stdio: 'inherit', env: { ...process.env, BASE_URL: url } }).on('exit', res));
  if (code !== 0) failed++;
}
await server.close();
console.log(failed ? `\n${failed} suite(s) failed` : '\nall suites passed');
process.exit(failed ? 1 : 0);
