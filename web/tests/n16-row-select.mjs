// QC N16 e2e: run against `npm run dev` (mock mode). Not part of the build (tsconfig/vite only include src/).
// Usage: npx vite --port 5190 &  BASE_URL=http://localhost:5190 node tests/n16-row-select.mjs
import { chromium } from 'playwright-core';

const BASE = process.env.BASE_URL ?? 'http://localhost:5173';
const CHROME = process.env.CHROME_PATH ?? '/usr/bin/google-chrome';
const results = [];
const check = (name, ok, extra = '') => { results.push({ name, ok }); console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${extra ? ' — ' + extra : ''}`); };

const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
const errors = [];
page.on('pageerror', (e) => errors.push(e.message));

const detailOpen = async (label) => (await page.locator('h2', { hasText: new RegExp(`^${label}$`, 'i') }).count()) > 0
  && (await page.getByRole('button', { name: /take out/i }).count()) > 0;
const row = (name) => page.getByRole('row', { name: new RegExp(name) });

// 1. single click
await page.goto(BASE); await page.waitForSelector('text=Karin Sultan');
await row('Karin Sultan').click();
await page.waitForTimeout(200);
check('single click opens detail', await detailOpen('Karin Sultan'));
check('clicked row highlighted (aria-selected)', (await row('Karin Sultan').getAttribute('aria-selected')) === 'true');

// 1b. single click on another row switches detail
await row('Pegassi Bati 801').click(); await page.waitForTimeout(200);
check('second single click switches detail', await detailOpen('Pegassi Bati 801'));

// 2. keyboard: focus row + Enter
await page.goto(BASE); await page.waitForSelector('text=Karin Sultan');
await row('Truffade Adder').focus();
await page.keyboard.press('Enter'); await page.waitForTimeout(200);
check('focus + Enter opens detail', await detailOpen('Truffade Adder'));

// 3. retired row: click does nothing
await page.goto(BASE); await page.waitForSelector('text=Albany Emperor');
await row('Albany Emperor').click({ force: true }); await page.waitForTimeout(200);
check('retired row click does not open detail', !(await detailOpen('Albany Emperor')) && (await page.getByText('Select a vehicle from the list').count()) > 0);
check('retired row not selectable', (await row('Albany Emperor').getAttribute('aria-selected')) !== 'true');

check('no page errors', errors.length === 0, errors.join(' | '));
await browser.close();
const failed = results.filter((r) => !r.ok).length;
console.log(`\n${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);
