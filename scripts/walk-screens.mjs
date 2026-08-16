// Drive the six main screens of the running frontend, recording when each was
// on screen so collected spans can be attributed to the screen that caused them.
//
//   node scripts/walk-screens.mjs .mxcli-obs/marks.json
//
// The frontend has to be local, not behind --hub: the hub sets __Host-/Secure
// cookies and a headless browser over plain http can never hold a session
// (FINDINGS, open issue 6). Waits are generous because tracing roughly triples
// wall time — a page that settles in 8s unobserved needs the better part of 30.

import fs from 'fs';
import pw from '/opt/node22/lib/node_modules/playwright/index.js';
const OUT = process.argv[2];
const b = await pw.chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const p = await b.newPage({ viewport: { width: 1600, height: 1100 }, colorScheme: 'dark' });
p.setDefaultTimeout(120000);
const marks = [];
const open = async (label, fn, settle = 25000) => {
  const t0 = Date.now();
  try { await fn(); } catch (e) { console.log(`  ${label}: ${e.message.split('\n')[0].slice(0,80)}`); }
  await p.waitForTimeout(settle);
  marks.push({ label, from: t0, to: Date.now() });
  console.log(`  ${label.padEnd(18)} ${Date.now() - t0}ms`);
};

await p.goto('http://frontend.local:8180/', { waitUntil: 'domcontentloaded' });
await p.waitForTimeout(6000);
await p.fill('input[type=text]', 'fan'); await p.fill('input[type=password]', 'F1Enthusiast!2345');
await p.keyboard.press('Enter'); await p.waitForTimeout(20000);
console.log('logged in');

await open('Home', async () => { await p.goto('http://frontend.local:8180/p/home', { waitUntil: 'domcontentloaded' }); }, 12000);
await open('Live race', async () => { await p.goto('http://frontend.local:8180/p/live', { waitUntil: 'domcontentloaded' }); }, 20000);

await p.goto('http://frontend.local:8180/p/drivers-live', { waitUntil: 'domcontentloaded' });
await p.waitForTimeout(20000);
await p.locator('.mx-datagrid input, input.form-control, input[type="text"]').first().fill('Hamilton');
await p.waitForTimeout(14000);
await open('Driver career', async () => { await p.getByText('Career', { exact: true }).first().click(); }, 28000);

await p.goto('http://frontend.local:8180/p/seasons', { waitUntil: 'domcontentloaded' });
await p.waitForTimeout(14000);
await p.locator('button[aria-label*="last"], .paging-button').last().click().catch(()=>{});
await p.waitForTimeout(10000);
const sum = p.getByText('Summary', { exact: true });
await open('Season summary', async () => {
  await sum.nth(Math.max(0, (await sum.count()) - 3)).click();
}, 28000);

await open('Race weekend', async () => { await p.locator('.cal-card').nth(17).click(); }, 34000);

await p.goto('http://frontend.local:8180/p/constructors', { waitUntil: 'domcontentloaded' });
await p.waitForTimeout(14000);
await p.locator('.mx-datagrid input, input.form-control, input[type="text"]').first().fill('Ferrari');
await p.waitForTimeout(12000);
await open('Constructor', async () => { await p.getByText('Reliability', { exact: true }).first().click(); }, 28000);

fs.writeFileSync(OUT, JSON.stringify(marks, null, 1));
console.log('marks ->', OUT);
await b.close();
