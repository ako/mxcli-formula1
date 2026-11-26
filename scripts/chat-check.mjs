// Hold a conversation with the F1 agent on /p/ask (model/frontend/18-chat-agent.mdl)
// and print what it answered, including which lake tools it called.
//
//   node scripts/chat-check.mjs <screenshot-prefix> "question 1" ["question 2" ...]
//
// Signs in as the demo user `fan`. Use localhost, not frontend.local: over plain
// HTTP, Conversational UI's streaming handler only finds the session cookie when
// the Host header contains "localhost" (FINDINGS §109). PLAYWRIGHT and BASE
// override the module path and the app URL.
const PLAYWRIGHT = process.env.PLAYWRIGHT
  || '/usr/lib/node_modules/@playwright/cli/node_modules/playwright/index.js';
const { chromium } = (await import(PLAYWRIGHT)).default;
const BASE = process.env.BASE || 'http://localhost:8180';
const [out, ...questions] = process.argv.slice(2);
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1400, height: 1100 }, colorScheme: 'dark' });
const errors = [];
page.on('console', m => { if (m.type() === 'error') errors.push(m.text().slice(0, 160)); });

await page.goto(`${BASE}/`, { waitUntil: 'networkidle' });
await page.fill('#usernameInput', 'fan'); await page.fill('#passwordInput', 'F1Enthusiast!2345');
await page.click('#loginButton'); await page.waitForTimeout(5000);
await page.goto(`${BASE}/p/ask`, { waitUntil: 'networkidle' }); await page.waitForTimeout(4000);

const chat = page.locator('.mx-name-dvChat');
const bodyText = async () => (await chat.innerText()).replace(/\n{2,}/g, '\n');
const input = chat.locator('textarea').first();
const results = [];
for (const q of questions) {
  const before = await bodyText();
  await input.fill(q);
  await input.press('Enter');
  const t0 = Date.now();
  // Done when the text has grown past the question and stopped changing for 6 s.
  let last = '', stableSince = Date.now();
  while (Date.now() - t0 < 240000) {
    await page.waitForTimeout(2000);
    const now = await bodyText();
    if (now !== last) { last = now; stableSince = Date.now(); continue; }
    if (now.length > before.length + q.length + 20 && Date.now() - stableSince > 6000) break;
  }
  results.push({ q, seconds: Math.round((Date.now() - t0) / 1000), transcriptTail: last.slice(before.length).slice(-1500) });
}
await page.screenshot({ path: `${out}.png`, fullPage: true });
const dialogs = await page.locator('.mx-dialog, .modal-dialog').allInnerTexts();
console.log(JSON.stringify({ results, dialogs, errors }, null, 1));
await browser.close();
