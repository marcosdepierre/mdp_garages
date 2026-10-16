// P1F-R2-L4: error-code lists in sync: NUI_ERROR_CODES ↔ shared/constants.lua ↔ docs/architecture.md, and every code has
// an err_* fallback; all ui keys exist in en.lua and es.lua; in i18n.tsx and locales/en.lua (with identical English text). No browser needed.
import { readFileSync } from 'node:fs';
const R = (p) => readFileSync(new URL(`../../${p}`, import.meta.url), 'utf8');
const words = (s) => new Set([...s.matchAll(/'([a-z_]+)'/g)].map((m) => m[1]));
const ts = R('web/src/types/index.ts'); const nui = words(ts.slice(ts.indexOf('NUI_ERROR_CODES'), ts.indexOf('] as const')));
const lua = R('shared/constants.lua'); const con = words(lua.slice(lua.indexOf('Constants.ErrorCodes'), lua.indexOf('Constants.ErrorCodes[c]')));
const doc = R('docs/architecture.md'); const sec = doc.slice(doc.indexOf('Error codes (single source of truth)')); const docs = new Set([...sec.slice(0, sec.search(/\n## [^#]/) >>> 0).matchAll(/^- `([a-z_]+)`/gm)].map((m) => m[1]));
const i18n = Object.fromEntries([...R('web/src/i18n.tsx').matchAll(/^\s*(err_[a-z_]+): "(.*)",?$/gm)].map((m) => [m[1], m[2]]));
const en = Object.fromEntries([...R('locales/en.lua').matchAll(/^\s*(err_[a-z_]+) = '(.*)',?$/gm)].map((m) => [m[1], m[2]]));
let fail = 0;
const cmp = (name, a, b) => { const d = [...a].filter((x) => !b.has(x)).concat([...b].filter((x) => !a.has(x)).map((x) => `+${x}`)); console.log(`${d.length ? 'FAIL' : 'PASS'} NUI_ERROR_CODES == ${name}${d.length ? ' — ' + d.join(', ') : ''}`); fail += !!d.length; };
cmp('Constants.ErrorCodes', nui, con);
cmp('architecture.md', nui, docs);
for (const c of nui) {
  const k = `err_${c}`;
  if (!i18n[k]) { console.log(`FAIL i18n fallback missing ${k}`); fail++; }
  else if (en[k] !== undefined && en[k] !== i18n[k]) { console.log(`FAIL ${k} differs: i18n "${i18n[k]}" vs en.lua "${en[k]}"`); fail++; }
}
// P1F-R3-L1: every NUI fallback key + every key Lua passes (_L / titleKey) must exist in en.lua AND es.lua.
const luaKeys = (f) => new Set([...R(f).matchAll(/^\s*([a-z_]+)\s*=\s*['"]/gm)].map((m) => m[1]));
const nuiKeys = [...R('web/src/i18n.tsx').matchAll(/^\s*([a-z_]+): "/gm)].map((m) => m[1]);
const clientSrc = ['client/zones.lua', 'client/main.lua', 'client/props.lua'].map(R).join('\n');
const clientKeys = [...clientSrc.matchAll(/(?:titleKey\s*=\s*|_L\()'([a-z_]+)'/g)].map((m) => m[1]);
for (const f of ['locales/en.lua', 'locales/es.lua']) {
  const have = luaKeys(f);
  const miss = [...new Set([...nuiKeys, ...clientKeys, ...[...nui].map((c) => `err_${c}`)])].filter((k) => !have.has(k));
  console.log(`${miss.length ? 'FAIL' : 'PASS'} all ui keys present in ${f}${miss.length ? ' — missing: ' + miss.join(', ') : ''}`);
  fail += !!miss.length;
}
console.log(fail ? `${fail} failure(s)` : 'error codes in sync');
process.exit(fail ? 1 : 0);
