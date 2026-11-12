import assert from 'node:assert/strict';
import { execFile, execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { attach, session } from '../../../scripts/lib/instance.mjs';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const root = dirname(repo);
const exec = promisify(execFile);
const [appArg, metroPort, scratchArg] = process.argv.slice(2);
assert.ok(appArg && metroPort && scratchArg, 'usage: runtime-test.mjs app metroPort scratch');
const appPath = resolve(appArg);
const scratch = resolve(scratchArg);
assert.ok(appPath.startsWith(root + '/'));
assert.ok(scratch.startsWith(root + '/'));
mkdirSync(scratch, { recursive: true });
const data = join(scratch, 'data');
assert.equal(existsSync(join(data, 'WebKitContentRules')), false, 'use a fresh scratch directory for cold compilation');
const evidence = { started: new Date().toISOString(), checks: [] };
const folderBytes = (path) => {
  if (!existsSync(path)) return 0;
  return readdirSync(path, { withFileTypes: true }).reduce((sum, entry) => {
    const full = join(path, entry.name);
    return sum + (entry.isDirectory() ? folderBytes(full) : entry.isFile() ? statSync(full).size : 0);
  }, 0);
};
const record = (name, values) => {
  evidence.checks.push({ name, ...values });
  writeFileSync(join(scratch, 'results.json'), JSON.stringify(evidence, null, 2));
  console.log(JSON.stringify({ name, ...values }));
};
const requests = [];
const image = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6sZsAAAAASUVORK5CYII=', 'base64');
const server = createServer((req, res) => {
  requests.push({ url: req.url, time: Date.now() });
  res.setHeader('cache-control', 'no-store');
  if (req.url.startsWith('/xpopup/xpopup.js')) {
    res.writeHead(200, { 'content-type': 'text/javascript' });
    return res.end('document.documentElement.dataset.adLoaded="yes"');
  }
  if (req.url.startsWith('/allowed.js')) {
    res.writeHead(200, { 'content-type': 'text/javascript' });
    return res.end('document.documentElement.dataset.appLoaded="yes"');
  }
  if (req.url.startsWith('/favicon.ico')) {
    res.writeHead(200, { 'content-type': 'image/png' });
    return res.end(image);
  }
  const query = new URL(req.url, 'http://127.0.0.1').searchParams;
  if (req.url.startsWith('/redirect')) {
    res.writeHead(302, { location: query.get('to') });
    return res.end();
  }
  if (req.url.startsWith('/download')) {
    res.writeHead(200, { 'content-type': 'application/octet-stream', 'content-disposition': 'attachment; filename="fixture.bin"' });
    return res.end('fixture');
  }
  if (req.url.startsWith('/frame')) {
    res.writeHead(200, { 'content-type': 'text/html' });
    return res.end(`<!doctype html><title>Frame ${query.get('tag')}</title><iframe src="${query.get('inner')}"></iframe>`);
  }
  const tag = query.get('tag') ?? 'first';
  res.writeHead(200, { 'content-type': 'text/html' });
  res.end(`<!doctype html><title>Fixture ${tag}</title><body><div id="AC_ad" style="width:100px;height:40px">Cosmetic fixture</div><div id="allowed">Allowed content</div><script src="/allowed.js?tag=${tag}"></script><script src="/xpopup/xpopup.js?tag=${tag}"></script></body>`);
});
await new Promise((done) => server.listen(0, '127.0.0.1', done));
const origin = `http://127.0.0.1:${server.address().port}`;
const makeURL = (tag) => `${origin}/page?tag=${tag}`;
const otherOrigin = origin.replace('127.0.0.1', 'localhost');
const otherURL = (tag) => `${otherOrigin}/page?tag=${tag}`;
const downloads = join(scratch, 'downloads');
mkdirSync(downloads, { recursive: true });
const requested = (tag) => requests.some((r) => r.url === `/xpopup/xpopup.js?tag=${tag}`);
const settle = () => new Promise((done) => setTimeout(done, 2500));
const fixture = session({ windows: [{ id: 'w1', activeTabIds: { default: 'fixture' } }], tabs: [{ id: 'fixture', url: makeURL('first'), engine: 'webkit' }], settings: { pageEngine: 'webkit', warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false } });
const fixtureFile = join(scratch, 'fixture.json');
writeFileSync(fixtureFile, JSON.stringify(fixture));
let app;
const run = (body) => app.eval(body, { timeout: 15000 });
const poll = async (label, fn, duration = 60000) => {
  const deadline = Date.now() + duration;
  let last;
  while (Date.now() < deadline) {
    if (!app.alive) throw new Error(`instance died waiting for ${label}`);
    try { last = await fn(); } catch (error) { last = { error: error.message }; }
    if (last && !last.error) return last;
    await new Promise((done) => setTimeout(done, 150));
  }
  throw new Error(`${label} timeout: ${JSON.stringify(last)}`);
};
const status = () => run('return globalThis.expo.modules.SolaraCEF.devWebKitBlockerStatus("127.0.0.1")');
const ready = (after = -1) => poll('WebKit applied revision', async () => {
  const state = await status();
  return state.ready && !state.preparing && state.generation > after ? state : null;
}, 150000);
const changed = async (body) => {
  const before = (await status()).generation;
  await run(body);
  return ready(before);
};
const pageState = async () => {
  const value = await run('return ac.webviews.get("fixture").evaluate("post(\'result\', JSON.stringify({url:location.href,ad:document.documentElement.dataset.adLoaded??null,app:document.documentElement.dataset.appLoaded??null,display:getComputedStyle(document.querySelector(\'#AC_ad\')).display,title:document.title}))")');
  return typeof value === 'string' ? JSON.parse(value) : value;
};
const loaded = (tag, url = makeURL(tag)) => poll(`page ${tag}`, async () => {
  const state = await pageState();
  return state?.url === url && state.app === 'yes' ? state : null;
}, 30000);
const page = (method, ...args) => run(`return ac.webviews.get("fixture").${method}(${args.map((arg) => JSON.stringify(arg)).join(',')}).then(()=>true)`);
const lazyAd = async (tag) => {
  await run(`return ac.webviews.get("fixture").evaluate(${JSON.stringify(`(() => { const s = document.createElement('script'); s.src = '/xpopup/xpopup.js?tag=${tag}'; document.head.appendChild(s); return true; })()`)})`);
  await settle();
  return requested(tag);
};
const trust = async (host, on) => {
  await changed(`return globalThis.expo.modules.SolaraCEF.setContentBlockerAllowed(${JSON.stringify(host)}, ${on}).then(()=>true)`);
};
const expectRequest = (name, tag, wanted, extra = {}) => {
  const got = requested(tag);
  assert.equal(got, wanted, `${name}: ad request ${wanted ? 'missing' : 'reached the server'}`);
  record(name, { adRequested: got, ...extra });
};
const navigate = async (tag) => {
  await run(`return ac.webviews.get("fixture").loadUrl(${JSON.stringify(makeURL(tag))}).then(()=>true)`);
  return loaded(tag);
};
const expectBlocked = async (tag, navigatePage = true) => {
  const state = navigatePage ? await navigate(tag) : await loaded(tag);
  assert.equal(state.ad, null, `${tag}: ad script ran`);
  assert.equal(state.display, 'none', `${tag}: cosmetic not hidden`);
  assert.equal(requests.some((r) => r.url === `/xpopup/xpopup.js?tag=${tag}`), false, `${tag}: ad request reached fixture`);
  record(tag, { state, blocker: await status() });
};
const expectAllowed = async (tag) => {
  const state = await navigate(tag);
  assert.equal(state.ad, 'yes', `${tag}: ad script did not run`);
  assert.notEqual(state.display, 'none', `${tag}: cosmetic remains hidden`);
  assert.equal(requests.some((r) => r.url === `/xpopup/xpopup.js?tag=${tag}`), true, `${tag}: no ad request reached fixture`);
  record(tag, { state, blocker: await status() });
};
const mutate = async (method, args) => {
  const started = Date.now();
  const applied = await changed(`return globalThis.expo.modules.SolaraCEF.${method}(${args.map(JSON.stringify).join(',')}).then(()=>true)`);
  record(`apply-${method}-${args.join('-')}`, { applyMs: Date.now() - started, preparationMs: applied.preparationMs, compiled: applied.ruleListCount ? applied.compilations.slice(-applied.ruleListCount).filter((row) => !row.cached).length : 0 });
};
const settingsList = async (on) => {
  const command = JSON.stringify({ id: 'easylist', on });
  await run(`ac.openSettings("privacy"); return true`);
  await poll('native Settings privacy pane', async () => {
    const state = JSON.parse(await run('return globalThis.expo.modules.SolaraSettings.devSettings("state", null)'));
    return state.pane === 'privacy' ? state : null;
  }, 10000);
  const before = (await status()).generation;
  const started = JSON.parse(await run(`return globalThis.expo.modules.SolaraSettings.devSettings("filterList", ${JSON.stringify(command)})`));
  assert.ok(started.pending, JSON.stringify(started));
  const changed = await poll('native Settings filter-list action', async () => {
    const result = JSON.parse(await run('return globalThis.expo.modules.SolaraSettings.devSettings("filterListResult", null)'));
    if (result.pending) return null;
    assert.equal(result.applied, true, JSON.stringify(result));
    return result;
  }, 15000);
  await ready(before);
  record('settings-list-action', { ...changed, path: 'Settings privacy model setList, same action as Advanced Ad Block Settings checkbox' });
  await run('return globalThis.expo.modules.SolaraSettings.devSettings("close", null)');
};
const rss = () => {
  const rows = execFileSync('/bin/ps', ['-ax', '-o', 'pid=', '-o', 'ppid=', '-o', 'rss=', '-o', 'command='], { encoding: 'utf8', timeout: 20000 }).trim().split('\n').map((line) => /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/.exec(line)).filter(Boolean).map((match) => ({ pid: Number(match[1]), ppid: Number(match[2]), rssBytes: Number(match[3]) * 1024, command: match[4] }));
  const family = new Set([app.pid]);
  for (let pass = 0; pass < rows.length; pass++) for (const row of rows) if (family.has(row.ppid)) family.add(row.pid);
  const processes = rows.filter((row) => family.has(row.pid));
  return { bytes: processes.reduce((sum, row) => sum + row.rssBytes, 0), processes, scope: 'App pid and descendants at sample; RSS sums shared mappings repeatedly; launchd-reparented WebKit helpers may be excluded; Metro excluded.' };
};
const webKitProcesses = () => execFileSync('/bin/ps', ['-ax', '-o', 'pid=', '-o', 'rss=', '-o', 'command='], { encoding: 'utf8', timeout: 20000 }).trim().split('\n').map((line) => /^\s*(\d+)\s+(\d+)\s+(.+)$/.exec(line)).filter((match) => match && /com\.apple\.WebKit\.(WebContent|Networking|GPU)/.test(match[3])).map((match) => ({ pid: Number(match[1]), rssBytes: Number(match[2]) * 1024, command: match[3].split('/').pop() }));
let webKitBefore = new Set();
const webKitRSS = () => {
  const processes = webKitProcesses().filter((row) => !webKitBefore.has(row.pid));
  return { bytes: processes.reduce((sum, row) => sum + row.rssBytes, 0), processes, scope: 'WebKit WebContent, Networking and GPU processes started after this launch (launchd children, so outside processFamilyRSS); the uitest lock keeps other test instances from launching meanwhile' };
};
const launch = async (fresh) => {
  webKitBefore = new Set(webKitProcesses().map((row) => row.pid));
  const command = ['90', join(repo, 'scripts/agent/ac'), 'launch', appPath, '--data', data, '--js', `127.0.0.1:${metroPort}`, '--as', 'ub33', '--onboarded', '--env', 'SOLARA_NATIVE_SHELL=1', '--env', 'SOLARA_SHELL_PANES=1', '--env', 'SOLARA_NATIVE_PAGES_POOL=1', '--env', 'SOLARA_TAB_POOL=1', '--env', 'SOLARA_TEST_SCRIPT_POPUPS=1', '--env', `SOLARA_DOWNLOADS_DIR=${downloads}`, '--switch', '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1, EXCLUDE localhost'];
  if (fresh) command.push('--session', typeof fresh === 'string' ? fresh : fixtureFile);
  const start = Date.now();
  await exec('timeout', command, { encoding: 'utf8', timeout: 95000 });
  app = attach(data);
  return { started: start, harnessReadyMs: Date.now() - start };
};
const quit = async () => {
  if (!app && existsSync(join(data, 'instance.json'))) {
    try { app = attach(data); } catch {}
  }
  if (app?.alive) await app.quit();
  app = null;
};
try {
  const firstLaunch = await launch(true);
  const coldPage = await loaded('first');
  const coldLoadedMs = Date.now() - firstLaunch.started;
  const coldWaits = (await status()).waits ?? [];
  const coldWait = coldWaits.find((row) => row.firstLaunch);
  assert.ok(coldWait, `cold launch recorded no first navigation wait: ${JSON.stringify(coldWaits)}`);
  assert.ok(coldWait.ms <= 4000, `cold launch held the first navigation for ${Math.round(coldWait.ms)} ms`);
  assert.ok(coldWaits.every((row) => row.ms <= 4000), `a cold-launch navigation waited too long: ${JSON.stringify(coldWaits)}`);
  record('cold-first-navigation', { waitMs: coldWait.ms, rulesAppliedInTime: coldWait.applied, adRequested: requested('first'), loadedMsAfterLaunchStart: coldLoadedMs, harnessReadyMs: firstLaunch.harnessReadyMs, state: coldPage });
  await ready();
  const physical = await poll('physical WebKit page', () => run('return globalThis.expo.modules.SolaraTabPool.livePages().then((pages)=>pages.find((page)=>page.tabId==="fixture"))'), 10000);
  assert.equal(physical?.engine, 'webkit', 'fixture is not backed by the WebKit page pool');
  record('physical-engine', { page: physical });
  await expectBlocked('first-after-compile');
  assert.ok((await status()).compilations.some((row) => row.cached === false), 'fresh scratch did not compile any rules');
  record('first-launch', { compiledDiskBytes: folderBytes(join(data, 'WebKitContentRules')), launchMs: Date.now() - firstLaunch.started, harnessReadyMs: firstLaunch.harnessReadyMs, processFamilyRSS: rss(), webKitRSS: webKitRSS(), blocker: await status(), firstDocumentAt: requests.find((r) => r.url.startsWith('/page?tag=first'))?.time });
  await expectBlocked('restored-first');
  const before = await status();
  await quit();
  const cachedLaunch = await launch(false);
  await expectBlocked('restored-first', false);
  record('cached-first-navigation-blocked', { waits: ((await status()).waits ?? []).slice(0, 4), adRequests: requests.filter((r) => r.url === '/xpopup/xpopup.js?tag=restored-first').length });
  await ready();
  await expectBlocked('cached');
  const cached = await status();
  assert.ok(Array.isArray(cached.compilations) && cached.compilations.length > 0, 'cached launch returned no compilation evidence');
  assert.ok(cached.compilations.every((row) => row.cached === true), `cached launch recompiled: ${JSON.stringify(cached.compilations)}`);
  record('cached-launch', { compiledDiskBytes: folderBytes(join(data, 'WebKitContentRules')), launchMs: Date.now() - cachedLaunch.started, harnessReadyMs: cachedLaunch.harnessReadyMs, processFamilyRSS: rss(), before, blocker: cached });
  for (const [on, tag] of [[true, 'trusted'], [false, 'untrusted']]) {
    const started = Date.now();
    await run(`return globalThis.expo.modules.SolaraCEF.setContentBlockerAllowed("127.0.0.1", ${on}).then(()=>true)`);
    await (on ? expectAllowed : expectBlocked)(tag);
    record(`reload-right-after-${tag}`, { msUntilLoaded: Date.now() - started, ruleListCount: (await status()).ruleListCount });
  }
  await trust('127.0.0.1', true);
  await navigate('reload-base');
  await trust('127.0.0.1', false);
  await page('reload');
  await settle();
  const reloadBlocked = requests.filter((r) => r.url === '/xpopup/xpopup.js?tag=reload-base').length;
  assert.equal(reloadBlocked, 1, 'reload() after untrusting still let the ad through');
  await trust('127.0.0.1', true);
  await page('reload');
  await loaded('reload-base');
  await settle();
  assert.equal(requests.filter((r) => r.url === '/xpopup/xpopup.js?tag=reload-base').length, 2, 'reload() after trusting kept blocking the ad');
  record('real-reload', { adRequestsAfterUntrustedAndTrustedReloads: 2 });
  await trust('127.0.0.1', false);

  await trust('localhost', true);
  await navigate('popup-opener');
  const tabsBefore = await run('return Object.keys(ac.store.getState().tabs)');
  await run(`return ac.webviews.get("fixture").evaluate(${JSON.stringify(`window.open(${JSON.stringify(otherURL('popup-trusted'))}) ? true : false`)})`);
  await poll('trusted popup page', async () => requests.some((r) => r.url === '/page?tag=popup-trusted') || null, 30000);
  await settle();
  expectRequest('popup-trusted-from-untrusted-opener', 'popup-trusted', true);
  assert.equal(await lazyAd('popup-opener-lazy'), false, 'opening a trusted popup unblocked the untrusted opener');
  record('popup-opener-stays-blocked', { tabsBefore: tabsBefore.length, tabsAfter: (await run('return Object.keys(ac.store.getState().tabs)')).length });

  await page('loadUrl', otherURL('trusted-opener'));
  await loaded('trusted-opener', otherURL('trusted-opener'));
  expectRequest('trusted-opener', 'trusted-opener', true);
  await run(`return ac.webviews.get("fixture").evaluate(${JSON.stringify(`window.open(${JSON.stringify(makeURL('popup-untrusted'))}) ? true : false`)})`);
  await poll('untrusted popup page', async () => requests.some((r) => r.url === '/page?tag=popup-untrusted') || null, 30000);
  await settle();
  expectRequest('popup-untrusted-from-trusted-opener', 'popup-untrusted', false);
  assert.equal(await lazyAd('trusted-opener-lazy'), true, 'opening an untrusted popup blocked the trusted opener');
  record('trusted-opener-stays-trusted', {});
  await run(`const s = ac.store.getState(); for (const id of Object.keys(s.tabs)) if (id !== "fixture") s.closeTab(id); s.activate?.("fixture"); return true`);

  await page('loadUrl', `${origin}/frame?tag=frame-untrusted-top&inner=${encodeURIComponent(otherURL('frame-trusted-inner'))}`);
  await poll('inner frame', async () => requests.some((r) => r.url === '/page?tag=frame-trusted-inner') || null, 30000);
  await settle();
  expectRequest('trusted-iframe-in-untrusted-top', 'frame-trusted-inner', false);
  await page('loadUrl', `${otherOrigin}/frame?tag=frame-trusted-top&inner=${encodeURIComponent(makeURL('frame-untrusted-inner'))}`);
  await poll('inner frame', async () => requests.some((r) => r.url === '/page?tag=frame-untrusted-inner') || null, 30000);
  await settle();
  expectRequest('untrusted-iframe-in-trusted-top', 'frame-untrusted-inner', true);

  await page('loadUrl', `${origin}/redirect?to=${encodeURIComponent(otherURL('redirect-to-trusted'))}`);
  await loaded('redirect-to-trusted', otherURL('redirect-to-trusted'));
  await settle();
  expectRequest('redirect-untrusted-to-trusted', 'redirect-to-trusted', true);
  await page('loadUrl', `${otherOrigin}/redirect?to=${encodeURIComponent(makeURL('redirect-to-untrusted'))}`);
  await loaded('redirect-to-untrusted');
  await settle();
  expectRequest('redirect-trusted-to-untrusted', 'redirect-to-untrusted', false);

  await page('loadUrl', otherURL('history-trusted'));
  await loaded('history-trusted', otherURL('history-trusted'));
  await navigate('history-untrusted');
  await page('goBack');
  await loaded('history-trusted', otherURL('history-trusted'));
  assert.equal(await lazyAd('history-back-lazy'), true, 'going back to the trusted page kept it blocked');
  await page('goForward');
  await loaded('history-untrusted');
  assert.equal(await lazyAd('history-forward-lazy'), false, 'going forward to the untrusted page left it unblocked');
  record('back-forward', {});

  await page('loadUrl', `${otherOrigin}/download?tag=dl`);
  await poll('download request', async () => requests.some((r) => r.url === '/download?tag=dl') || null, 30000);
  await settle();
  assert.equal((await pageState()).url, makeURL('history-untrusted'), 'the download replaced the page');
  assert.equal(await lazyAd('download-lazy'), false, 'a download from a trusted host unblocked the untrusted page');
  record('download-navigation', {});
  await run(`return ac.webviews.get("fixture").evaluate(${JSON.stringify(`(() => { const a = document.createElement('a'); a.href = ${JSON.stringify(`${otherOrigin}/download?tag=dl-attr`)}; a.download = 'fixture.bin'; document.body.appendChild(a); a.click(); return true; })()`)})`);
  await poll('download-attribute request', async () => requests.some((r) => r.url === '/download?tag=dl-attr') || null, 30000);
  await settle();
  assert.equal((await pageState()).url, makeURL('history-untrusted'), 'the download link replaced the page');
  assert.equal(await lazyAd('download-attribute-lazy'), false, 'a download-attribute link to a trusted host unblocked the untrusted page');
  record('download-attribute-link', {});
  await trust('localhost', false);
  await trust(`${otherOrigin}/page?tag=wildcard-*`, true);
  await page('loadUrl', otherURL('wildcard-yes'));
  await loaded('wildcard-yes', otherURL('wildcard-yes'));
  await settle();
  expectRequest('wildcard-url-directive-trusts', 'wildcard-yes', true);
  await page('loadUrl', otherURL('outside-wildcard'));
  await loaded('outside-wildcard', otherURL('outside-wildcard'));
  await settle();
  expectRequest('wildcard-url-directive-stays-scoped', 'outside-wildcard', false);

  await mutate('setContentBlockerEnabled', [false]);
  await expectAllowed('blocking-off');
  await mutate('setContentBlockerEnabled', [true]);
  await expectBlocked('blocking-on');
  await settingsList(false);
  await expectAllowed('easylist-off');
  await settingsList(true);
  await expectBlocked('easylist-on');
  await mutate('setContentBlockerEnabled', [false]);
  await expectAllowed('without-lists');
  await quit();
  const withoutLaunch = await launch(false);
  await ready();
  await expectAllowed('without-lists-second');
  record('without-lists-launch', { launchMs: Date.now() - withoutLaunch.started, harnessReadyMs: withoutLaunch.harnessReadyMs, processFamilyRSS: rss(), webKitRSS: webKitRSS(), blocker: await status() });
  await mutate('setContentBlockerEnabled', [true]);
  await quit();
  const chromiumFile = join(scratch, 'chromium-fixture.json');
  writeFileSync(chromiumFile, JSON.stringify(session({ windows: [{ id: 'w1', activeTabIds: { default: 'chromium' } }], tabs: [{ id: 'chromium', url: makeURL('chromium-first'), engine: 'chromium' }], settings: { pageEngine: 'chromium', warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false } })));
  await launch(chromiumFile);
  const chromiumPage = await poll('Chromium fixture page', async () => (await app.page('/page?tag=', { timeout: 2000 })), 30000);
  const chromiumState = () => chromiumPage.eval(`JSON.stringify({url:location.href,ad:document.documentElement.dataset.adLoaded??null,app:document.documentElement.dataset.appLoaded??null,display:getComputedStyle(document.querySelector('#AC_ad')).display})`).then(JSON.parse);
  const chromiumLoad = async (tag) => {
    await chromiumPage.send('Page.navigate', { url: makeURL(tag) });
    return poll(`Chromium page ${tag}`, async () => { const state = await chromiumState(); return state.url === makeURL(tag) && state.app === 'yes' ? state : null; }, 30000);
  };
  const chromiumExpect = async (base, blocked) => {
    let attempt = 0;
    let state;
    let tag;
    const deadline = Date.now() + 30000;
    do {
      tag = `${base}-${attempt++}`;
      state = await chromiumLoad(tag);
      if ((state.ad === null) === blocked) break;
      await new Promise((done) => setTimeout(done, 1000));
    } while (Date.now() < deadline);
    const reached = requests.some((r) => r.url === `/xpopup/xpopup.js?tag=${tag}`);
    assert.equal(state.ad === null, blocked, `${tag}: Chromium ad script ${blocked ? 'ran' : 'did not run'}`);
    assert.equal(reached, !blocked, `${tag}: Chromium ad request ${blocked ? 'reached' : 'did not reach'} the fixture`);
    const cosmetic = await poll(`Chromium cosmetic ${tag}`, async () => { const now = await chromiumState(); return (now.display === 'none') === blocked ? now : null; }, 5000).then(() => 'as expected', () => 'not as expected (uBO cosmetic filtering, recorded only)');
    record(`chromium-${base}`, { state, attempts: attempt, cosmetic });
  };
  await chromiumExpect('blocked', true);
  await run('return globalThis.expo.modules.SolaraCEF.setContentBlockerAllowed("127.0.0.1", true).then(()=>true)');
  await chromiumExpect('trusted', false);
  await run('return globalThis.expo.modules.SolaraCEF.setContentBlockerAllowed("127.0.0.1", false).then(()=>true)');
  await chromiumExpect('untrusted', true);
  await run('return globalThis.expo.modules.SolaraCEF.setContentBlockerEnabled(false).then(()=>true)');
  await chromiumExpect('blocking-off', false);
  await run('return globalThis.expo.modules.SolaraCEF.setContentBlockerEnabled(true).then(()=>true)');
  await chromiumExpect('blocking-on', true);
  chromiumPage.close();
  await settle();
  const chromiumOnly = await status();
  assert.equal(chromiumOnly.generation, 0, 'a Chromium-only session started the WebKit blocker');
  record('chromium-only-session-leaves-webkit-idle', { generation: chromiumOnly.generation, compilations: chromiumOnly.compilations?.length ?? 0 });
  await quit();
  const warmFile = join(scratch, 'warm-fixture.json');
  writeFileSync(warmFile, JSON.stringify(session({ windows: [{ id: 'w1', activeTabIds: { default: 'chromium' } }], tabs: [{ id: 'chromium', url: makeURL('warm-chromium'), engine: 'chromium' }, { id: 'background-webkit', url: makeURL('background-webkit'), engine: 'webkit' }], settings: { pageEngine: 'chromium', warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false } })));
  const warmLaunch = await launch(warmFile);
  const warmed = await poll('blocker started at launch for a restored WebKit tab', async () => {
    const state = await status();
    return state.generation > 0 && state.ready ? state : null;
  }, 30000);
  const livePages = await run('return globalThis.expo.modules.SolaraTabPool.livePages()');
  const backgroundTabHasPage = Array.isArray(livePages) && livePages.some((page) => page.tabId === 'background-webkit');
  assert.equal(backgroundTabHasPage, false, 'the background WebKit tab had a page, so this does not show the launch warm-up');
  record('restored-webkit-tab-starts-blocker', { msAfterLaunchStart: Date.now() - warmLaunch.started, generation: warmed.generation, preparationMs: warmed.preparationMs, backgroundTabHasPage, backgroundDocumentRequested: requests.some((r) => r.url === '/page?tag=background-webkit') });
  evidence.passed = true;
} catch (error) {
  evidence.error = error.stack ?? String(error);
  process.exitCode = 1;
  console.error(evidence.error);
} finally {
  await quit();
  await new Promise((done) => server.close(done));
  evidence.requests = requests;
  evidence.finished = new Date().toISOString();
  writeFileSync(join(scratch, 'results.json'), JSON.stringify(evidence, null, 2));
}
