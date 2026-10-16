// Phase 1: §8 mileage, §9 take-out lock/toast/inline error/Retry, §10 impound, §11 loading/error, Lua toast action.
import { BASE, suite } from './lib.mjs';

await suite(async ({ page, check }) => {
  const toastText = (s) => page.locator('[data-sonner-toaster]').getByText(s);

  // §8.3 mileage es-ES grouping 'always'
  await page.goto(`${BASE}/?view=detail&plate=MDP005&garage=impound:lspd`); await page.waitForSelector('text=Illegal parking');
  check('mileage es-ES grouped (40.110 km)', (await page.getByText(/40\.110\s?km/).count()) > 0);
  // §10 impound
  check('impound block shown', (await page.getByRole('note').getByText('Illegal parking').count()) > 0);
  check('Take out hidden when impounded', (await page.getByRole('button', { name: /take out/i }).count()) === 0);

  // §9 loading lock + success toast
  await page.goto(`${BASE}/?view=detail&plate=MDP001`); await page.waitForSelector('text=Take out');
  await page.getByRole('button', { name: /take out/i }).click();
  await page.waitForTimeout(150);
  check('dialog aria-busy during take-out', (await page.getByTestId('panel').getAttribute('aria-busy')) === 'true');
  check('close disabled during take-out', await page.locator('header').getByRole('button', { name: 'Close' }).isDisabled());
  await page.keyboard.press('Escape'); await page.waitForTimeout(100);
  check('ESC ignored during take-out', (await page.getByRole('dialog').count()) > 0);
  await toastText('Vehicle taken out').waitFor({ timeout: 5000 }).catch(() => {});
  check('success toast shown', (await toastText('Vehicle taken out').count()) > 0);

  // §9.4 error toast + inline alert + Retry (KEY 42 fails once with spawn_failed)
  await page.goto(`${BASE}/?view=detail&plate=KEY%2042`); await page.waitForSelector('text=Take out');
  await page.getByRole('button', { name: /take out/i }).click();
  const alert = page.getByRole('alert').filter({ has: page.getByRole('button', { name: /retry/i }) });
  await alert.waitFor({ timeout: 5000 }).catch(() => {});
  check('inline error with Retry for retryable code', (await alert.count()) > 0);
  check('error toast shown', (await page.locator('[data-sonner-toast]').count()) > 0);
  await alert.getByRole('button', { name: /retry/i }).click();
  await toastText('Vehicle taken out').waitFor({ timeout: 5000 }).catch(() => {});
  check('Retry succeeds', (await toastText('Vehicle taken out').count()) > 0);

  // §11 open without vehicles → loading → list
  await page.goto(`${BASE}/?fetch=1`);
  await page.getByText('Loading', { exact: false }).first().waitFor({ timeout: 3000 }).catch(() => {});
  check('loading indicator while fetching vehicles', (await page.getByText(/loading/i).count()) > 0);
  await page.waitForSelector('text=Karin Sultan', { timeout: 5000 }).catch(() => {});
  check('vehicles rendered after getVehicles', (await page.getByText('Karin Sultan').count()) > 0);

  // negative engine health clamps to 0%
  await page.goto(`${BASE}/?view=detail&plate=LS%208X%2088`); await page.waitForSelector('text=Dinka Blista');
  check('negative engine → 0%', (await page.getByRole('progressbar', { name: /0%/ }).count()) > 0 || (await page.getByText(/^0%$/).count()) > 0);

  // Lua 'toast' action (store feedback), panel closed
  await page.evaluate(() => window.postMessage({ action: 'toast', id: 'store', kind: 'error', titleKey: 'storing', error: 'occupied' }, '*'));
  await page.waitForTimeout(400);
  check('Lua toast rendered with localized title', (await toastText('Storing vehicle…').count()) > 0);
});
