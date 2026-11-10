// Files from the phone, as PocketIDE's app sends them, in Codex's VS Code at a phone's size with the
// app's page script (pocket/app/src/main/assets/workspace/pagescript.js). CI runs it after the Cloud
// Shell set-up, with that set-up's home folder (CLOUD_SHELL_HOME; else this one's):
//   CLOUD_SHELL_HOME=<home> node phone-files-check.js <folder for the screenshots>
// Codex's own "add files" (its webview asks its extension for vscode://codex/pick-files) must open
// the phone's picker on the same tap, and Codex must get the file sent to its uploads folder, with
// no VS Code dialog. Asking for a folder must stay VS Code's dialog, with no picker. Any other
// extension's VS Code file dialog (here File: Open File) must open the picker by itself and take the
// file. PocketIDE's door, which passes /__pocketide/drop/ on a page's own address to Cloud Shell's
// file drop, is played here by Playwright. And the other way: VS Code's own Download of a small
// file gives only a blob: address, which the page script must keep, whole, for the app to read in
// pieces. Any miss is an error, and the screenshots show it.
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { chromium } = require('playwright');

const out = process.argv[2] || 'phone-screens';
const script = fs.readFileSync(path.join(__dirname, '../app/src/main/assets/workspace/pagescript.js'), 'utf8');
const VS_CODE = 'http://127.0.0.1:8081/'; // Codex's, whose "add files" uses this dialog
const DROP = 'http://127.0.0.1:6081/';
const PHONE = { viewport: { width: 360, height: 700 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true };

const fail = (message) => {
  throw new Error(message);
};

// Cline, an agent the owner added (node phone-files-check.js <folder> cline:<its port>): its "add
// files" asks its extension for files (FileService.selectFiles); the phone's picker must open on the
// tap, a picture come back as a data: URL and any other file as its path in Cline's uploads folder.
async function cline(port) {
  const home = process.env.CLOUD_SHELL_HOME || os.homedir();
  const picture = path.join(os.tmpdir(), 'from-phone.png');
  // A 1x1 PNG.
  fs.writeFileSync(picture, Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC', 'base64'));
  const note = path.join(os.tmpdir(), `for-cline-${process.pid}.txt`);
  fs.writeFileSync(note, 'For Cline\n');
  const browser = await chromium.launch();
  const page = await browser.newPage(PHONE);
  await page.addInitScript(script);
  await page.route('**/__pocketide/drop/**', async (route) => {
    const url = route.request().url().replace(/^http:\/\/127\.0\.0\.1:\d+\/__pocketide\/drop\//, DROP);
    // As PocketIDE's door passes an agent's VS Code page on: from the drop's own address.
    await route.fulfill({ response: await route.fetch({ url, headers: { ...route.request().headers(), origin: DROP.replace(/\/$/, '').replace('127.0.0.1', 'localhost') } }) });
  });
  await page.goto(`http://127.0.0.1:${port}/`);
  await page.waitForSelector('.monaco-workbench', { timeout: 90000 });
  let panel;
  for (let tries = 0; tries < 120 && !panel; tries++) {
    for (const frame of page.frames()) {
      if (frame !== page.mainFrame() && await frame.evaluate(() => typeof acquireVsCodeApi === 'function').catch(() => false)) panel = frame;
    }
    if (!panel) await page.waitForTimeout(1000);
  }
  if (!panel) fail('Cline\'s own panel did not load.');
  await panel.evaluate(() => {
    window.__answers = [];
    window.addEventListener('message', (event) => { if (event.data && event.data.type === 'grpc_response') window.__answers.push(event.data); });
  });
  const picker = page.waitForEvent('filechooser', { timeout: 10000 });
  await panel.click('body', { position: { x: 20, y: 20 } });
  await panel.parentFrame().evaluate(() => window.__vscode_post_message__('onmessage', { message: { type: 'grpc_request', grpc_request: {
    service: 'cline.FileService', method: 'selectFiles', message: { value: true }, request_id: 'phone-files', is_streaming: false } } }));
  const chooser = await picker.catch(() => fail('Cline\'s "add files" did not open the phone\'s picker on the tap.'));
  await chooser.setFiles([picture, note]);
  await panel.waitForFunction(() => window.__answers.some((answer) => answer.grpc_response.request_id === 'phone-files'), null, { timeout: 20000 })
    .catch(() => fail('Cline did not get the files sent from the phone.'));
  const { values1, values2 } = (await panel.evaluate(() => window.__answers.find((each) => each.grpc_response.request_id === 'phone-files'))).grpc_response.message;
  const arrived = path.join(home, 'projects', 'x-claude-dev', 'uploads', path.basename(note));
  if (values1.length !== 1 || !values1[0].startsWith('data:image/png;base64,')) fail(`Cline's picture came back as ${String(values1).slice(0, 60)}`);
  if (values2.length !== 1 || values2[0] !== arrived || fs.readFileSync(arrived, 'utf8') !== 'For Cline\n') fail(`Cline's file came back as ${values2}`);
  console.log('Cline: its "add files" opened the phone\'s picker on the tap; a picture came back as data, a file from its uploads folder.');
  await page.screenshot({ path: path.join(out, 'files-5-cline.png') });
  await browser.close();
}

// VS Code's own Download (the explorer's Download...) of a file under 32 MB: the page script keeps
// the file behind its blob: address, and the app reads it back in pieces of base64, as it does on
// the phone (AgentPages.kt, PageHeldFile). Several pieces, every byte the same.
async function toPhone(browser) {
  const name = `to-phone-${process.pid}.bin`;
  const file = path.join(process.env.CLOUD_SHELL_HOME || os.homedir(), 'projects', 'codex', name);
  const bytes = crypto.randomBytes(2_500_000);
  fs.writeFileSync(file, bytes);
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 }, acceptDownloads: true });
  await page.addInitScript(script);
  await page.goto(VS_CODE);
  await page.waitForSelector('.monaco-workbench', { timeout: 90000 });
  await page.waitForTimeout(5000);
  await page.keyboard.press('Control+Shift+E');
  const row = page.locator('.explorer-folders-view .monaco-list-row', { hasText: name }).first();
  await row.waitFor({ timeout: 30000 }).catch(() => fail(`The explorer does not show ${name}.`));
  await row.click({ button: 'right' });
  const item = page.locator('.context-view .action-label', { hasText: /^Download/ }).first();
  await item.waitFor({ timeout: 10000 }).catch(() => fail('The explorer\'s menu has no Download.'));
  await page.waitForTimeout(800);
  const [download] = await Promise.all([page.waitForEvent('download', { timeout: 20000 }), item.click()])
    .catch(() => fail('VS Code\'s Download did not hand over the file.'));
  const address = download.url();
  if (!address.startsWith('blob:')) fail(`VS Code's Download gave ${address}, not a blob: address.`);
  const about = await page.evaluate((url) => window.__pocketide.heldFile(url), address);
  if (!about || about.name !== name || about.size !== bytes.length) fail(`The page keeps ${JSON.stringify(about)} for VS Code's Download.`);
  const pieces = [];
  for (let index = 0, waited = 0; ;) {
    const piece = await page.evaluate(([url, at]) => window.__pocketide.piece(url, at), [address, index]);
    if (piece === null) break;
    if (piece === '') {
      if ((waited += 20) > 30000) fail(`The page did not read piece ${index}.`);
      await page.waitForTimeout(20);
      continue;
    }
    pieces.push(Buffer.from(piece, 'base64'));
    index += 1;
  }
  if (pieces.length < 3 || !Buffer.concat(pieces).equals(bytes)) fail(`What the page gave (${pieces.length} pieces) is not the file.`);
  if (!await page.evaluate((url) => window.__pocketide.letGo(url), address) || await page.evaluate((url) => window.__pocketide.heldFile(url), address)) {
    fail('The page still keeps the file after the app had it all.');
  }
  console.log(`To phone: VS Code's Download of ${name} (2.5 MB) came out of the page whole, in ${pieces.length} pieces.`);
  await page.close();
  fs.rmSync(file);
}

(async () => {
  fs.mkdirSync(out, { recursive: true });
  const only = /^cline:(\d{4,5})$/.exec(process.argv[3] || '');
  if (only) {
    await cline(Number(only[1]));
    return;
  }
  const name = `from-phone-${process.pid}.txt`;
  const sample = path.join(os.tmpdir(), name);
  fs.writeFileSync(sample, 'Sent from the phone\n');
  const browser = await chromium.launch();
  const page = await browser.newPage(PHONE);
  await page.addInitScript(script);
  await page.route('**/__pocketide/drop/**', async (route) => {
    const url = route.request().url().replace(/^http:\/\/127\.0\.0\.1:\d+\/__pocketide\/drop\//, DROP);
    // As PocketIDE's door passes an agent's VS Code page on: from the drop's own address.
    await route.fulfill({ response: await route.fetch({ url, headers: { ...route.request().headers(), origin: DROP.replace(/\/$/, '').replace('127.0.0.1', 'localhost') } }) });
  });
  await page.goto(VS_CODE);
  await page.waitForSelector('.monaco-workbench', { timeout: 90000 });
  await page.waitForTimeout(5000);
  const uploads = path.join(process.env.CLOUD_SHELL_HOME || os.homedir(), 'projects', 'codex', 'uploads');
  const dialogShown = () => page.evaluate(() => {
    const widget = document.querySelector('.quick-input-widget');
    return !!widget && widget.getClientRects().length > 0 && getComputedStyle(widget).display !== 'none';
  });

  // Codex's own "add files": its webview (VS Code removes window.parent there, so the request goes
  // out through the webview's host frame, as Codex's own call does) asks for files right after a tap.
  let codex;
  for (let tries = 0; tries < 120 && !codex; tries++) {
    for (const frame of page.frames()) {
      if (frame === page.mainFrame()) continue;
      if (await frame.evaluate(() => typeof acquireVsCodeApi === 'function' && document.title === 'ChatGPT').catch(() => false)) codex = frame;
    }
    if (!codex) await page.waitForTimeout(1000);
  }
  if (!codex) fail('Codex\'s own panel did not load.');
  const host = codex.parentFrame();
  await codex.evaluate(() => {
    window.__answers = [];
    window.addEventListener('message', (event) => { if (event.data && event.data.type === 'fetch-response') window.__answers.push(event.data); });
  });
  const ask = (id, params) => host.evaluate(({ id, params }) => window.__vscode_post_message__('onmessage', {
    message: { type: 'fetch', requestId: id, method: 'POST', url: 'vscode://codex/pick-files', body: JSON.stringify(params) },
  }), { id, params });
  const codexName = `codex-${name}`;
  const codexSample = path.join(os.tmpdir(), codexName);
  fs.writeFileSync(codexSample, 'Sent from the phone to Codex\n');
  const codexPicker = page.waitForEvent('filechooser', { timeout: 10000 });
  await codex.click('body', { position: { x: 20, y: 20 } });
  await ask('phone-files', { allowMultiple: true });
  const codexChooser = await codexPicker.catch(() => fail('Codex\'s "add files" did not open the phone\'s picker on the tap.'));
  await codexChooser.setFiles(codexSample);
  await codex.waitForFunction(() => window.__answers.some((answer) => answer.requestId === 'phone-files'), null, { timeout: 20000 })
    .catch(() => fail('Codex did not get the file sent from the phone.'));
  const answer = await codex.evaluate(() => window.__answers.find((each) => each.requestId === 'phone-files'));
  const files = JSON.parse(answer.bodyJsonString).files;
  const codexArrived = path.join(uploads, codexName);
  if (answer.status !== 200 || files.length !== 1 || files[0].path !== codexArrived || files[0].fsPath !== codexArrived) fail(`Codex got ${answer.bodyJsonString}`);
  if (fs.readFileSync(codexArrived, 'utf8') !== 'Sent from the phone to Codex\n') fail(`${codexArrived} did not arrive whole.`);
  if (await dialogShown()) fail('VS Code\'s file dialog opened as well.');
  console.log(`Codex: its "add files" opened the phone's picker on the tap, and it got ${codexName} from its uploads folder.`);
  await page.screenshot({ path: path.join(out, 'files-0-codex.png') });

  // Asking for a folder stays VS Code's: Cloud Shell's folders, no picker.
  let folderPicker = false;
  const noticeFolder = () => { folderPicker = true; };
  page.on('filechooser', noticeFolder);
  await codex.click('body', { position: { x: 20, y: 20 } });
  await ask('folder', { kind: 'directory' });
  await page.waitForFunction(() => {
    const widget = document.querySelector('.quick-input-widget');
    const box = widget && widget.querySelector('.quick-input-box input');
    return !!box && getComputedStyle(widget).display !== 'none' && box.value.startsWith('/');
  }, null, { timeout: 30000 }).catch(() => fail('Asking Codex for a folder did not open VS Code\'s folder dialog.'));
  await page.screenshot({ path: path.join(out, 'files-1-codex-folder.png') });
  page.off('filechooser', noticeFolder);
  if (folderPicker) fail('Asking for a folder opened the phone\'s picker.');
  await page.keyboard.press('Escape');
  await page.waitForTimeout(1500);
  console.log('A folder stays VS Code\'s dialog, with Cloud Shell\'s folders.');

  const palette = async (command) => {
    await page.keyboard.press('Control+Shift+P');
    await page.waitForSelector('.quick-input-widget input', { timeout: 15000 });
    await page.waitForTimeout(800);
    await page.keyboard.type(command);
    await page.waitForTimeout(800);
  };
  // Any other extension's file dialog (File: Open File here): a folder dialog stays Cloud Shell's.
  let pickerOpened = false;
  page.on('filechooser', () => { pickerOpened = true; });
  await palette('File: Open Folder');
  await page.keyboard.press('Enter');
  await page.waitForTimeout(3000);
  if (pickerOpened) fail('A folder dialog opened the phone\'s picker.');
  await page.screenshot({ path: path.join(out, 'files-2-folder-dialog.png') });
  await page.keyboard.press('Escape');
  await page.waitForTimeout(800);
  // The tap (here a key) that opens the file dialog opens the phone's picker by itself.
  await palette('File: Open File');
  const picker = page.waitForEvent('filechooser', { timeout: 15000 });
  await page.keyboard.press('Enter');
  const chooser = await picker.catch(() => fail('The file dialog did not open the phone\'s picker by itself.'));
  await page.screenshot({ path: path.join(out, 'files-3-dialog.png') });

  await chooser.setFiles(sample);
  await page.waitForFunction((file) => document.title.includes(file.replace(/\.txt$/, '')), name, { timeout: 20000 })
    .catch(() => fail('The dialog did not take the file sent from the phone.'));
  const arrived = path.join(uploads, name);
  if (!fs.existsSync(arrived) || fs.readFileSync(arrived, 'utf8') !== 'Sent from the phone\n') fail(`${arrived} did not arrive whole.`);
  console.log(`From phone: ${name} arrived in ~/projects/codex/uploads and the dialog took it.`);
  await page.screenshot({ path: path.join(out, 'files-4-taken.png') });

  await toPhone(browser);
  await browser.close();
})().catch((error) => {
  console.log(`::error::${error.message.split('\n')[0]}`);
  process.exit(1);
});
