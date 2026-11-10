// PocketIDE's browser in Cloud Shell, as the agents and the owner use it. CI runs it after
// `pocketide browser start`, against the Chrome and the view (relay.py) the launcher started:
//   node browser-check.js <folder for the screenshots>
// An agent drives Chrome through its DevTools protocol (127.0.0.1:9222, as Playwright's
// connectOverCDP does) and opens a page of its own dev server; the owner's view (127.0.0.1:6080, in
// a phone-sized Chromium as PocketIDE's app shows it) must show that page live, pass a tap and
// typing to it, switch it to a phone's size, follow a new tab the agent opens, list the tabs in the
// order they opened, show the one the owner picks, and keep taps out in Watch only. Any miss is an
// error, and the screenshots show it.
const http = require('http');
const path = require('path');
const { chromium } = require('playwright');

const out = process.argv[2] || 'phone-screens';
const VIEW = 'http://127.0.0.1:6080/';
const DEVTOOLS = 'http://127.0.0.1:9222';
// A dev server's page, as an agent would start one: a button and a text box at known places.
const SITE = `<!doctype html><title>Agent's page</title>
<body style="font:32px sans-serif;margin:0">
<button id=b style="position:absolute;left:100px;top:100px;width:400px;height:200px;font-size:40px"
 onclick="this.textContent='Tapped!'">Tap me</button>
<input id=i style="position:absolute;left:100px;top:400px;width:600px;height:80px;font-size:40px">
<div style="height:3000px"></div></body>`;
const PHONE = { viewport: { width: 360, height: 760 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true };

const say = (what) => fetch(VIEW + 'input', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(what) });

(async () => {
  const site = http.createServer((request, answer) => answer.writeHead(200, { 'Content-Type': 'text/html' }).end(SITE));
  await new Promise((done) => site.listen(0, '127.0.0.1', done));
  const address = `http://127.0.0.1:${site.address().port}/`;

  // The agent: Chrome's first tab, at its dev server.
  const agent = await chromium.connectOverCDP(DEVTOOLS);
  const context = agent.contexts()[0];
  const page = context.pages()[0] || await context.newPage();
  await page.goto(address);
  await say({ type: 'size', phone: false });

  // The owner: PocketIDE's view of that Chrome, on a phone.
  const viewer = await chromium.launch();
  const phone = await viewer.newPage(PHONE);
  await phone.goto(VIEW);
  await phone.waitForFunction(() => document.getElementById('picture').naturalWidth > 0, null, { timeout: 30000 });
  await phone.waitForFunction(() => document.getElementById('url').value.startsWith('http://127.0.0.1:'), null, { timeout: 10000 });
  await phone.screenshot({ path: path.join(out, 'browser-1-view.png') });

  // A tap on the picture lands on the page's button (the page is 1280 x 800).
  const box = await phone.locator('#picture').boundingBox();
  const tap = () => phone.mouse.click(box.x + box.width * 300 / 1280, box.y + box.height * 200 / 800);
  await tap();
  await page.waitForFunction(() => document.getElementById('b').textContent === 'Tapped!', null, { timeout: 10000 });
  console.log('A tap in the view reaches the page.');

  // Typing goes where the page's cursor is.
  await page.focus('#i');
  await phone.fill('#text', 'typed on the phone');
  await phone.click('#send');
  await page.waitForFunction(() => document.getElementById('i').value === 'typed on the phone', null, { timeout: 10000 });
  console.log('Typing in the view reaches the page.');

  // Phone size: the page sees a phone's screen, and the view shows it.
  await phone.click('#size');
  await page.waitForFunction(() => screen.width === 412, null, { timeout: 10000 });
  await phone.waitForTimeout(1500);
  await phone.screenshot({ path: path.join(out, 'browser-2-phone-size.png') });
  await say({ type: 'size', phone: false });
  await page.waitForFunction(() => screen.width !== 412, null, { timeout: 10000 });
  console.log('Phone size works, both ways.');

  // A tab the agent opens comes to the front of the view.
  const second = await context.newPage();
  await second.goto('data:text/html,<title>Second tab</title><h1 style="font-size:80px">Second tab</h1>');
  await phone.waitForFunction(
    () => [...document.querySelectorAll('#pages option')].some((option) => option.textContent === 'Second tab' && option.selected),
    null,
    { timeout: 15000 },
  );
  await phone.waitForTimeout(1000);
  await phone.screenshot({ path: path.join(out, 'browser-3-new-tab.png') });
  console.log('The view follows the tab the agent works in.');

  // The tabs are listed in the order they opened (Chrome's own list has no fixed order): the tab
  // the agent opened last comes last, after its first one.
  const tabs = await phone.$$eval('#pages option', (options) => options.map((option) => option.textContent));
  if (!tabs.includes("Agent's page") || tabs.at(-1) !== 'Second tab') {
    throw new Error(`The tabs are not in the order they opened: ${tabs.join(' | ')}`);
  }
  console.log('The tabs are in the order they opened.');

  // The owner picks the agent's first tab again: the view shows it (its address comes from the
  // relay, not from the list), and Watch only keeps their taps out of it.
  await phone.selectOption('#pages', { label: "Agent's page" });
  await phone.waitForFunction((shown) => document.getElementById('url').value === shown, address, { timeout: 10000 });
  await page.evaluate(() => { document.getElementById('b').textContent = 'Tap me'; });
  await phone.click('#watch');
  await tap();
  await phone.waitForTimeout(1500);
  if ((await page.textContent('#b')) !== 'Tap me') throw new Error('A tap in Watch only reached the page.');
  console.log('Watch only keeps taps out.');

  await second.close();
  await viewer.close();
  await agent.close();
  site.close();
})().catch((error) => {
  console.log(`::error::${error.message.split('\n')[0]}`);
  process.exit(1);
});
