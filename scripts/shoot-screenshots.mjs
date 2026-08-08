// Screenshot every page of the running frontend into docs/screenshots/.
//
//   node scripts/shoot-screenshots.mjs
//
// The frontend has to be up (scripts/run-app.sh Formula1Frontend ...) and the
// backend with it, because every page here is reading it over OData. The shots
// in the README are this script's output, regenerated rather than curated: a
// panel that is empty in one is empty in the app.
//
// Three things it has to work around, all of them real behaviour rather than
// test flakiness:
//
//   * the sidebar is off-canvas at this width, so a nav link has to be revealed
//     before it can be clicked and hidden again before the shot;
//   * charts and the wide session table finish well after the network goes
//     quiet — the weekend page needs the better part of a minute;
//   * Mendix reports a failed datasource as a modal, which would then swallow
//     every later click. Any dialog is recorded and reported at the end, so a
//     broken page shows up as a line of output instead of a silent screenshot.
//
// PLAYWRIGHT resolves to the container's global install; override it if yours
// lives somewhere else.

import fs from 'fs';

const PLAYWRIGHT = process.env.PLAYWRIGHT
  || '/opt/node22/lib/node_modules/playwright/index.js';
const { chromium } = (await import(PLAYWRIGHT)).default;

const BASE = 'http://frontend.local:8180';
const OUT = new URL('../docs/screenshots/', import.meta.url).pathname;
fs.mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch({
  executablePath: process.env.CHROME
    || '/opt/pw-browsers/chromium-1194/chrome-linux/chrome',
  args: ['--no-sandbox'],
});
const ctx = await browser.newContext({
  viewport: { width: 1600, height: 1100 },
  deviceScaleFactor: 2,
  colorScheme: 'dark',
});
const page = await ctx.newPage();

// Any Mendix error dialog is a finding, not something to click past silently.
const errors = [];
const dismiss = async () => {
  const dlg = page.locator('.mx-dialog, .modal-dialog').filter({ hasText: /error/i });
  if (await dlg.count()) {
    const txt = (await dlg.first().innerText()).replace(/\s+/g, ' ').slice(0, 120);
    errors.push(`${page.url()} :: ${txt}`);
    const ok = page.locator('.mx-dialog button, .modal-dialog button').filter({ hasText: /OK|Close/i }).first();
    if (await ok.count()) { await ok.click(); await page.waitForTimeout(600); }
  }
};

const shot = async (name) => {
  await page.waitForTimeout(7000);
  await dismiss();
  await page.waitForTimeout(500);
  await page.screenshot({ path: `${OUT}/${name}.png`, fullPage: true });
  console.log('  shot', name);
};

console.log('login...');
await page.goto(`${BASE}/`, { waitUntil: 'networkidle' });
await page.waitForTimeout(2000);
await page.screenshot({ path: `${OUT}/00-login.png` });
await page.fill('#usernameInput, input[name="username"], input[type="text"]', 'fan');
await page.fill('#passwordInput, input[name="password"], input[type="password"]', 'F1Enthusiast!2345');
await page.click('#loginButton, button[type="submit"], .login-btn');
await page.waitForTimeout(7000);
console.log('  logged in ->', page.url());

// The Atlas sidebar is an off-canvas overlay at this width: it has to be opened
// before its links are clickable, and it closes itself after a navigation.
const nav = async (label) => {
  console.log('nav ->', label);
  await dismiss();
  const link = page.locator('.mx-navigationtree a, .mx-navbar a, nav a').filter({ hasText: label }).first();
  const open = async () => {
    const w = await page.evaluate(() =>
      Math.round(document.querySelector('.region-sidebar').getBoundingClientRect().width));
    if (w < 100) {
      await page.locator('[aria-label="Toggle Menu"], .toggle-btn').first().click();
      await page.waitForTimeout(1400);
    }
  };
  await open();
  await link.click({ timeout: 15000 });
  await page.waitForTimeout(4500);
  // Close it again so the shot shows the page, not the menu over it.
  await page.locator('[aria-label="Toggle Menu"], .toggle-btn').first().click().catch(() => {});
  await page.waitForTimeout(1200);
};

const filterAndOpen = async (text, button) => {
  const f = page.locator('.mx-datagrid input, input.form-control, input[type="text"]').first();
  await f.fill(text);
  await page.waitForTimeout(4000);
  await page.locator(`text=${button}`).first().click();
  await page.waitForTimeout(12000);
};

await shot('01-home');

const steps = [
  ['02-live-race', async () => { await nav('Live race'); }],
  ['03-seasons', async () => { await nav('Seasons'); }],
  ['04-season-summary', async () => { await filterAndOpen('Verstappen', 'Summary'); }],
  ['05-race-weekend', async () => {
    // Exact match: the panel subtitle says "open one for the full weekend" and
    // a substring locator picks that up instead of the row link.
    await page.getByText('Weekend', { exact: true }).first().click();
    await page.waitForTimeout(45000);
  }],
  ['06-drivers', async () => { await nav('Drivers'); await nav('Live (CSV)'); }],
  ['07-driver-career', async () => { await filterAndOpen('Verstappen', 'Career'); }],
  ['08-constructors', async () => { await nav('Constructors'); }],
  ['09-constructor-detail', async () => { await filterAndOpen('Ferrari', 'Reliability'); }],
  ['10-race-results', async () => { await nav('Race results'); }],
  ['11-circuits', async () => { await nav('Circuits'); }],
];

for (const [name, go] of steps) {
  try { await go(); await shot(name); }
  catch (e) { console.log(`  FAILED ${name}: ${e.message.split('\n')[0].slice(0, 140)}`); }
}

await browser.close();
console.log('\nRuntime error dialogs seen:');
if (errors.length === 0) console.log('  none');
errors.forEach((e) => console.log('  -', e));
