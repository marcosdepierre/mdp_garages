// NUI-R5-1: ESC close, Take out success, disabled hint (mock mode).
import { BASE, suite } from './lib.mjs';

await suite(async ({ page, check }) => {
  const panelVisible = async () => (await page.getByRole('dialog').count()) > 0;

  await page.goto(BASE); await page.waitForSelector('text=Karin Sultan');
  check('panel visible on load (dev mock)', await panelVisible());
  await page.keyboard.press('Escape'); await page.waitForTimeout(1200);
  check('ESC hides the panel (after close callback)', !(await panelVisible()));

  await page.goto(`${BASE}/?view=detail&plate=MDP001`); await page.waitForSelector('text=Take out');
  await page.getByRole('button', { name: /take out/i }).click();
  await page.waitForTimeout(800);
  check('Take out ok hides the panel', !(await panelVisible()));

  await page.goto(`${BASE}/?view=detail&plate=MDP002`); await page.waitForSelector('text=Take out');
  check('Take out disabled for state 0', await page.getByRole('button', { name: /take out/i }).isDisabled());
  check('disabled hint shown (localized err_already_out)', (await page.getByText('This vehicle is already out').count()) > 0);
});
