// An agent's links to files, as the owner opens them in PocketIDE: Cloud Shell's files.py at a
// phone's size (360 x 760), after the set-up script. CI runs it in the Cloud Shell job:
//   CLOUD_SHELL_HOME=<the set-up's home> node files-check.js <folder for the screenshots>
// It makes a few files in the Codex agent's projects, links them with `pocketide link`, and checks
// each page: a folder's files, a picture, a PDF's pages (pdf.js, which the set-up fetched), Markdown,
// a table, a web page that runs in its sandbox (its own scripts too, which no other page may embed),
// and the Download a phone saves. Any miss is an error.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { chromium } = require('playwright');

const out = process.argv[2] || 'phone-screens';
const home = process.env.CLOUD_SHELL_HOME;
const base = `http://127.0.0.1:${process.env.FILES_PORT || 6081}`;
const folder = path.join(home, 'projects', 'codex', 'files check');
const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
const PDF = [
  '%PDF-1.4', '1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj', '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj',
  '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 200]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj',
  '4 0 obj<</Length 47>>stream', 'BT /F1 28 Tf 30 90 Td (PocketIDE report) Tj ET', 'endstream endobj',
  '5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj', 'trailer<</Root 1 0 R>>', '%%EOF', '',
].join('\n');

let failed = false;
const fail = (message) => {
  console.log(`::error::${message}`);
  failed = true;
};

function makeFiles() {
  fs.mkdirSync(path.join(folder, 'site'), { recursive: true });
  fs.writeFileSync(path.join(folder, 'screenshot.png'), Buffer.from(PNG, 'base64'));
  fs.writeFileSync(path.join(folder, 'report.pdf'), PDF);
  fs.writeFileSync(path.join(folder, 'README.md'), '# Built in Cloud Shell\n\nThe **APK** is [here](site/index.html).\n');
  fs.writeFileSync(path.join(folder, 'results.csv'), 'test,result\nlogin,pass\nupload,pass\n');
  fs.writeFileSync(path.join(folder, 'site', 'index.html'),
    '<!doctype html><title>Site</title><p id="state">static</p><script src="app.js"></script>');
  fs.writeFileSync(path.join(folder, 'site', 'app.js'),
    "document.getElementById('state').textContent = 'ran';" +
    "fetch('../README.md').then(() => document.title = 'read another file').catch(() => document.title = 'kept apart');");
}

(async () => {
  makeFiles();
  // The link an agent gives: named, with its size, to files.py's page for it.
  const linked = execFileSync(path.join(home, '.local', 'bin', 'pocketide'), ['link', path.join(folder, 'report.pdf')], {
    env: { ...process.env, HOME: home },
  }).toString().trim();
  if (!/^\[report\.pdf · \d+ bytes\]\(http:\/\/localhost:6081\/f\/codex\/files%20check\/report\.pdf\)$/.test(linked)) {
    fail(`pocketide link printed ${linked}`);
  }
  const at = (where) => base + new URL(where.replace(/^.*?\(http:\/\/localhost:6081/, '').replace(/\)$/, ''), base).pathname;
  fs.mkdirSync(out, { recursive: true });
  const browser = await chromium.launch();
  const context = await browser.newContext({ viewport: { width: 360, height: 760 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  const visit = async (name, url, check) => {
    errors.length = 0;
    const answer = await page.goto(url, { waitUntil: 'load' });
    try {
      await check(answer);
    } catch (error) {
      fail(`${name}: ${error.message.split('\n')[0]}`);
    }
    if (errors.length) fail(`${name}: the page failed: ${errors.join('; ')}`);
    await page.screenshot({ path: path.join(out, `files-${name}.png`) });
  };
  const text = () => page.evaluate(() => document.body.innerText);
  const folderUrl = `${base}/f/codex/files%20check`;

  await visit('1-folder', folderUrl, async () => {
    const shown = await text();
    for (const name of ['report.pdf', 'screenshot.png', 'README.md', 'results.csv', 'site', 'Download as zip']) {
      if (!shown.includes(name)) throw new Error(`the folder's page does not show ${name}`);
    }
  });
  await visit('2-pdf', at(linked), async () => {
    await page.waitForFunction(() => /1 page/.test(document.getElementById('pdf-note').textContent), null, { timeout: 30000 });
    await page.waitForFunction(() => {
      const canvas = document.querySelector('canvas.page');
      if (!canvas || !canvas.width) return false;
      const pixels = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data;
      for (let i = 0; i < pixels.length; i += 4) if (pixels[i] < 128) return true; // some ink on the white page
      return false;
    }, null, { timeout: 30000 });
  });
  await visit('3-picture', `${base}/f/codex/files%20check/screenshot.png`, async () => {
    await page.waitForFunction(() => document.querySelector('.preview img').naturalWidth === 1, null, { timeout: 10000 });
  });
  await visit('4-markdown', `${base}/f/codex/files%20check/README.md`, async () => {
    if ((await page.textContent('.md h2')) !== 'Built in Cloud Shell') throw new Error('the Markdown was not rendered');
    if ((await page.getAttribute('.md a', 'href')) !== '/f/codex/files%20check/site/index.html') throw new Error('its link is not the page of the file it names');
  });
  await visit('5-table', `${base}/f/codex/files%20check/results.csv`, async () => {
    if ((await page.locator('table tr').count()) !== 3) throw new Error('the CSV is not a table of 3 rows');
  });
  // A web page opens from its own page's Open page (/s/<files.py's secret>/...), where its own scripts load.
  const sitePage = await (await page.request.get(`${base}/f/codex/files%20check/site/index.html`)).text();
  const opened = (/href="(\/s\/[A-Za-z0-9_-]+\/codex\/files%20check\/site\/index\.html)"/.exec(sitePage) || [])[1];
  if (!opened) fail("the web page's own page has no Open page");
  await visit('6-site', `${base}${opened}`, async () => {
    await page.waitForFunction(() => document.title === 'kept apart' || document.title === 'read another file', null, { timeout: 10000 });
    if ((await page.textContent('#state')) !== 'ran') throw new Error("the page's own script did not run");
    if ((await page.title()) !== 'kept apart') throw new Error('a page opened from here read another of the owner\'s files');
  });
  // What the phone downloads: the file whole, as an attachment with its own name.
  const download = await page.request.get(`${base}/f/codex/files%20check/report.pdf?download`);
  if (download.status() !== 200 || !/^attachment; filename="report\.pdf"/.test(download.headers()['content-disposition'] || '')) {
    fail(`Download answered ${download.status()} ${download.headers()['content-disposition']}`);
  } else if ((await download.body()).toString() !== PDF) {
    fail('the downloaded file is not the file');
  }
  await browser.close();
  if (failed) process.exit(1);
  console.log("An agent's links open on the phone: a folder, a PDF's pages, a picture, Markdown, a table, a sandboxed page, a download.");
})().catch((error) => {
  console.log(`::error::${error.stack || error}`);
  process.exit(1);
});
