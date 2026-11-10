// Each agent's VS Code in Cloud Shell, as PocketIDE's app shows it on a phone: a 360 x 700 screen,
// with the app's own page script (pocket/app/src/main/assets/workspace/pagescript.js). CI runs it
// after the Cloud Shell set-up script, against the VS Code it installed:
//   node phone-layout-check.js <folder for the screenshots> [name:port:title, for one agent only]
// It checks what the owner sees: the agent's own panel alone, full screen; the terminal full screen
// over it; the IDE button's whole IDE around the agent; Back (the app's) returning to the agent, with
// an editor left behind it; a page (Settings) opened from the whole IDE getting the whole screen, closed
// by Back, by the IDE button and by the agent's, in front again whenever it opens, and alone again when
// the Explorer opens beside it; a file opened
// again after the agent, alone (VS Code would split the screen); the command palette inside
// the screen and closed by Back's Escape, then the agent's own notice, if any, by the next Back. Any
// miss is an error, and the screenshots show it.
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const out = process.argv[2] || 'phone-screens';
// One agent only, as name:port:title (an agent the owner added, say x-claude-dev:8083:Cline).
const only = process.argv[3] && /^([a-z0-9-]+):(\d{4,5}):(\w[\w ]*)$/.exec(process.argv[3]);
const script = fs.readFileSync(path.join(__dirname, '../app/src/main/assets/workspace/pagescript.js'), 'utf8');
// Each agent's VS Code and the title of the agent's own panel (VS Code's own Chat is not the agent).
const AGENTS = only ? [[only[1], Number(only[2]), new RegExp(only[3])]]
  : [['claude-code', 8080, /Claude/], ['codex', 8081, /Codex/], ['antigravity', 8082, /Antigravity/]];
const PHONE = {
  viewport: { width: 360, height: 700 },
  deviceScaleFactor: 2,
  isMobile: true,
  hasTouch: true,
  userAgent: 'Mozilla/5.0 (Linux; Android 13; Phone; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/140.0.0.0 Mobile Safari/537.36',
};

let failures = 0;
const fail = (message) => {
  console.log(`::error::${message}`);
  failures += 1;
  process.exitCode = 1;
};

// The width of each part of VS Code's window that is on screen (0 when hidden), and the title of
// what the secondary side bar (the agent's place) shows.
const parts = (page) => page.evaluate(() => {
  const widths = Object.fromEntries(['auxiliarybar', 'editor', 'sidebar', 'panel'].map((name) => {
    const part = document.querySelector(`.monaco-workbench .part.${name}`);
    const shown = part && part.getClientRects().length > 0 && getComputedStyle(part).display !== 'none';
    return [name, shown ? Math.round(part.getBoundingClientRect().width) : 0];
  }));
  const title = document.querySelector('.monaco-workbench .part.auxiliarybar .composite.title h2');
  return { ...widths, title: title ? title.textContent : '' };
});
const editorAlone = (p) => p.editor > 300 && p.auxiliarybar < 40 && p.sidebar < 40 && p.panel < 40;
// The IDE button: the project's files beside the agent, as VS Code shows them.
const wholeIde = (p) => p.sidebar > 100 && p.auxiliarybar > 100;

async function check(browser, agent, port, name) {
  const failed = failures;
  const agentAlone = (p) => p.auxiliarybar > 300 && p.editor < 40 && p.sidebar < 40 && p.panel < 40 && name.test(p.title);
  const context = await browser.newContext(PHONE);
  await context.addInitScript({ content: script });
  const page = await context.newPage();
  const shot = (name) => page.screenshot({ path: path.join(out, `${agent}-${name}.png`) });
  const until = async (what, test, ms = 60000) => {
    for (let waited = 0; waited < ms; waited += 500) {
      if (test(await parts(page))) return true;
      await page.waitForTimeout(500);
    }
    fail(`${agent}: ${what} (on screen: ${JSON.stringify(await parts(page))})`);
    return false;
  };
  // [action] again every 5 seconds until [test] holds: the layout extension starts a little after the page.
  const after = async (what, action, test) => {
    for (let tries = 0; tries < 24; tries++) {
      await action();
      for (let waited = 0; waited < 5000; waited += 500) {
        if (test(await parts(page))) return true;
        await page.waitForTimeout(500);
      }
    }
    fail(`${agent}: ${what} (on screen: ${JSON.stringify(await parts(page))})`);
    return false;
  };
  const target = () => page.evaluate(() => window.__pocketide.backTarget());
  // A notification (an agent downloading its parts, say) is what Back hides first; nothing else is up.
  const toastOnly = () => page.evaluate(() => {
    const shown = (selector) => [...document.querySelectorAll(selector)].some((el) => el.getClientRects().length > 0);
    return shown('.notifications-toasts .notification-toast') &&
      !shown('.quick-input-widget') && !shown('.monaco-dialog-box') && !shown('.context-view .monaco-menu');
  });
  const run = (name) => page.evaluate((command) => window.__pocketide.run(command), name);
  // One of VS Code's commands, from the palette as the owner runs it. An agent's webview that is still
  // starting can take the focus once, which closes the palette: a second tap opens it, as for the owner.
  const command = async (title) => {
    for (let tries = 0; tries < 3; tries++) {
      await run('commands');
      if (!(await page.waitForSelector('.quick-input-widget input', { timeout: 5000 }).then(() => true, () => false))) continue;
      await page.waitForTimeout(800);
      if (!(await page.isVisible('.quick-input-widget input'))) continue;
      await page.keyboard.type(title);
      await page.waitForTimeout(1000);
      await page.keyboard.press('Enter');
      return;
    }
    throw new Error(`the command palette did not stay open to run "${title}"`);
  };
  try {
    await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.monaco-workbench', { timeout: 120000 });
    await until('the agent opens alone, full screen', agentAlone, 120000);
    await shot('1-agent');
    const first = await target();
    if (first !== 'none' && !(first === 'overlay' && (await toastOnly()))) fail(`${agent}: with the agent alone, Back leaves the screen`);

    // The terminal steps aside on Back and keeps running behind the agent: the whole IDE, left by Back
    // or by the IDE button again, must not bring it (or any editor behind) over the agent.
    await after('the terminal opens full screen, alone', () => run('terminal'), editorAlone);
    if ((await target()) === 'none') fail(`${agent}: with the terminal open, Back returns to the agent`);
    await shot('2-terminal');
    await after('Back from the terminal returns to the agent', () => run('back'), agentAlone);

    await after('the IDE button shows the whole IDE around the agent', () => run('ide'), wholeIde);
    if ((await target()) === 'none') fail(`${agent}: with the whole IDE on screen, Back returns to the agent`);
    await shot('3-ide');
    await run('back');
    await until('Back from the whole IDE returns to the agent', agentAlone, 10000);
    await after('the IDE button shows the whole IDE again', () => run('ide'), wholeIde);
    await run('agent');
    await until('the IDE button again returns to the agent, with the terminal still behind it', agentAlone, 10000);
    await page.waitForTimeout(2000);
    if (!agentAlone(await parts(page))) fail(`${agent}: the editor behind the whole IDE came over the agent`);

    // A page made for a computer's width (VS Code's own Settings here; Antigravity's settings are one
    // too), opened from the whole IDE, gets the whole screen, not a third of it; Back closes it.
    await after('the IDE button shows the whole IDE once more', () => run('ide'), wholeIde);
    await after('a page opened from the whole IDE gets the whole screen', () => page.keyboard.press('Control+Comma'), editorAlone);
    await shot('3-page');
    await run('back');
    await until('Back from the page returns to the agent', agentAlone, 10000);
    if (/^Settings\b/.test(await page.title())) fail(`${agent}: Back left the page open behind the agent`);
    // A page is only ever in front, full screen, or closed: the IDE button over it closes it and shows
    // the whole IDE; opened again (from there, or after the agent), it is in front, full screen again.
    const pageOpen = async () => /^Settings\b/.test(await page.title());
    await after('the IDE button shows the whole IDE before a page', () => run('ide'), wholeIde);
    await after('the page gets the whole screen again', () => page.keyboard.press('Control+Comma'), editorAlone);
    await after('the IDE button over the page closes it and shows the whole IDE', () => run('ide'), wholeIde);
    if (await pageOpen()) fail(`${agent}: the page stayed open behind the whole IDE`);
    await run('agent');
    await until('the agent comes back from there', agentAlone, 10000);
    await after('a page opened again after the agent is in front, full screen', () => page.keyboard.press('Control+Comma'), editorAlone);
    // Something that opens a side bar beside the page (an agent focusing its own panel, the Explorer
    // for a folder link) tells the layout extension nothing: the page script sees it, and the page
    // has the whole screen again within seconds.
    await command('View: Show Explorer');
    let beside = false;
    for (let waited = 0; waited < 3000 && !beside; waited += 200) {
      beside = (await parts(page)).sidebar > 100;
      if (!beside) await page.waitForTimeout(200);
    }
    if (!beside) fail(`${agent}: the Explorer did not open beside the page, which this check needs`);
    await until('the page has the whole screen again after the Explorer opened beside it', editorAlone, 10000);
    await shot('3-page-alone-again');
    await run('agent');
    await until('the agent button closes the page', agentAlone, 10000);
    if (await pageOpen()) fail(`${agent}: the page stayed open behind the agent`);
    // A file opened again after the agent came back (a file link tapped twice): alone, full screen. (Left
    // open behind the agent, VS Code would split the screen between them: nothing stays behind it now.)
    const userSettings = () => command('Preferences: Open User Settings (JSON)');
    await after('a file opens full screen', userSettings, editorAlone);
    await run('agent');
    await until('the agent covers the file', agentAlone, 10000);
    await userSettings();
    await until('the same file, opened again, is alone, full screen (not beside the agent)', editorAlone, 15000);
    await shot('3-file-again');
    await run('back');
    await until('Back from the file returns to the agent', agentAlone, 10000);

    // A webview that is still starting can take the focus once, which closes the palette: a second
    // tap opens it, as it would for the owner.
    let palette = false;
    for (let tries = 0; tries < 3 && !palette; tries++) {
      await run('commands');
      for (let waited = 0; waited < 5000 && !palette; waited += 500) {
        await page.waitForTimeout(500);
        palette = (await target()) === 'overlay' && (await page.evaluate(() => {
          const widget = document.querySelector('.quick-input-widget');
          return !!widget && widget.getClientRects().length > 0 && getComputedStyle(widget).display !== 'none';
        }));
      }
    }
    if (!palette) fail(`${agent}: the command palette opens, and it is what Back closes first`);
    const outside = await page.evaluate(() => [...document.querySelectorAll('.quick-input-widget, .monaco-dialog-box, .notifications-toasts, .context-view')]
      .filter((el) => el.getClientRects().length > 0)
      .map((el) => el.getBoundingClientRect())
      .filter((box) => box.left < -1 || box.right > window.innerWidth + 1).length);
    if (outside) fail(`${agent}: ${outside} floating part(s) of VS Code run off the screen`);
    await shot('4-commands');
    await page.evaluate(() => window.__pocketide.escape());
    await page.waitForTimeout(1000);
    const paletteShown = () => page.evaluate(() => [...document.querySelectorAll('.quick-input-widget')]
      .some((el) => el.getClientRects().length > 0 && getComputedStyle(el).display !== 'none'));
    if (await paletteShown()) fail(`${agent}: Back's Escape closes the command palette`);
    // What can be left is the agent's own notice (Cline's welcome, say): the next Back closes it.
    for (let backs = 0; backs < 3 && (await target()) === 'overlay'; backs++) {
      if (!(await toastOnly())) break;
      await page.evaluate(() => window.__pocketide.escape());
      await page.waitForTimeout(1000);
    }
    if ((await target()) === 'overlay') fail(`${agent}: after the palette, Back closes what is left, one thing at a time`);
    if (failures === failed) console.log(`${agent}: one thing at a time, Back and the palette work at a phone's size.`);
  } catch (error) {
    fail(`${agent}: ${error.message}`);
    await shot('error').catch(() => undefined);
  } finally {
    await context.close();
  }
}

(async () => {
  fs.mkdirSync(out, { recursive: true });
  const browser = await chromium.launch();
  try {
    for (const [agent, port, name] of AGENTS) await check(browser, agent, port, name);
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.log(`::error::${error.stack || error}`);
  process.exit(1);
});
