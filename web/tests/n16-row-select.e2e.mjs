// QC N16: single click opens detail + highlight; focus + Enter opens detail; retired rows inert. Mock mode.
import { BASE, suite } from './lib.mjs';

await suite(async ({ page, check }) => {
  const detailOpen = async (label) => (await page.locator('h2', { hasText: new RegExp(`^${label}$`, 'i') }).count()) > 0
    && (await page.getByRole('button', { name: /take out/i }).count()) > 0;
  const row = (name) => page.getByRole('row', { name: new RegExp(name) });

  await page.goto(BASE); await page.waitForSelector('text=Karin Sultan');
  await row('Karin Sultan').click(); await page.waitForTimeout(200);
  check('single click opens detail', await detailOpen('Karin Sultan'));
  check('clicked row highlighted (aria-selected)', (await row('Karin Sultan').getAttribute('aria-selected')) === 'true');
  await row('Pegassi Bati 801').click(); await page.waitForTimeout(200);
  check('second single click switches detail', await detailOpen('Pegassi Bati 801'));

  await page.goto(BASE); await page.waitForSelector('text=Karin Sultan');
  await row('Truffade Adder').focus(); await page.keyboard.press('Enter'); await page.waitForTimeout(200);
  check('focus + Enter opens detail', await detailOpen('Truffade Adder'));

  await page.goto(BASE); await page.waitForSelector('text=Albany Emperor');
  await row('Albany Emperor').click({ force: true }); await page.waitForTimeout(200);
  check('retired row click does not open detail', !(await detailOpen('Albany Emperor')) && (await page.getByText('Select a vehicle from the list').count()) > 0);
  check('retired row not selectable', (await row('Albany Emperor').getAttribute('aria-selected')) !== 'true');
});
