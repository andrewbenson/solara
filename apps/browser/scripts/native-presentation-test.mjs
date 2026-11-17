import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { launch, session, sleep } from "../../../scripts/lib/instance.mjs";

const [appArg, outArg] = process.argv.slice(2);
assert.ok(appArg && outArg, "usage: node native-presentation-test.mjs <Debug app> <output directory>");
const appPath = resolve(appArg);
const output = resolve(outArg);
assert.equal(execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print CFBundleIdentifier", join(appPath, "Contents/Info.plist")], { encoding: "utf8" }).trim(), "network.benson.solara.dev");
assert.equal(existsSync(join(output, "data")), false, "use a fresh output directory");
mkdirSync(output, { recursive: true });
process.env.AC_UITEST_WAIT ??= "120";
const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<!doctype html><title>${req.url}</title><style>html{background:#204060}body{height:9000px;margin:0;color:white;font:24px sans-serif}a{display:block;padding:30px}</style><a href="https://example.com/">presentation ${req.url}</a><input id="field"><script>document.addEventListener('keydown',e=>{if(e.key==='f')document.documentElement.requestFullscreen()});</script>`);
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const base = `http://127.0.0.1:${server.address().port}`;
const evidence = { checks: [], samples: [] };
let app;
let windowNumber;
const connections = [];
const run = (body) => app.eval(body, { timeout: 10000 });
const read = () => run('return globalThis.expo.modules.SolaraWindowShell.describe("w1").then(JSON.parse);');
async function until(label, readValue, accepts, timeout = 20000) {
  const deadline = Date.now() + timeout;
  let last;
  while (Date.now() < deadline) {
    assert.ok(app.alive, `${label}: instance exited`);
    last = await readValue();
    if (accepts(last)) return last;
    await sleep(100);
  }
  throw new Error(`${label}: deadline; last ${JSON.stringify(last)}`);
}
async function sample(label, accepts = () => true) {
  const shell = await until(label, read, (shell) => shell?.nativeLayout && shell.layout?.current && accepts(shell.layout));
  assert.ok(shell.layout.maxError <= 0.5, `${label}: native endpoints ${JSON.stringify(shell.layout.errors)}`);
  assert.deepEqual((shell.layout.missing ?? []).filter(name=>name.startsWith("page:")||name.startsWith("pane:")), [], `${label}: every native page/pane endpoint exists`);
  for (const [id, leaf] of Object.entries(shell.split?.leaves ?? {})) {
    const overlay = shell.split.overlays?.[id];
    if (!overlay || overlay.hidden) continue;
    assert.ok(leaf.window.every((v, i) => Math.abs(v - overlay.window[i]) <= 0.5), `${label}: ${id} page/overlay endpoints`);
  }
  evidence.samples.push({ label, shell });
  return shell.layout;
}
async function check(label, body) {
  await body();
  evidence.checks.push(label);
  console.log(`PASS ${label}`);
}
const registrations = () => run('return globalThis.expo.modules.SolaraTabPool.livePages().then(pages=>pages.map(({tabId,sessionGeneration,registrationGeneration,ready})=>({tabId,sessionGeneration,registrationGeneration,browserId:ready?.browserId??null})).sort((a,b)=>a.tabId.localeCompare(b.tabId)));');
async function page(path) {
  const connection = await app.page(target => target.url === `${base}${path}`, { timeout: 20000 });
  connections.push(connection);
  return connection;
}
async function readyPage(connection) {
  await until("active fixture document committed", () => connection.eval("({url:location.href,ready:document.readyState,field:!!document.getElementById('field')})"),
    state => state.url.startsWith(`${base}/`) && state.ready === "complete" && state.field);
}
async function scroll(connection, direction) {
  await readyPage(connection);
  const key = direction === "down" ? { key: "End", code: "End", windowsVirtualKeyCode: 35, nativeVirtualKeyCode: 119 } : { key: "Home", code: "Home", windowsVirtualKeyCode: 36, nativeVirtualKeyCode: 115 };
  for (const type of ["keyDown", "keyUp"]) await connection.send("Input.dispatchKeyEvent", { type, ...key });
}
const key = (spec) => run(`return ac.shell.devKeyEquivalent("w1",${JSON.stringify(spec)});`);
async function focusPage() {
  await key({ key: "\u0000", keyCode: 0, modifiers: [], focus: "page", dry: true, wait: 20 });
}
async function closeFields() {
  await run('const s=ac.store.getState();s.closePanel("w1");for(const id of ["a","b"])if(s.tabs[id])s.setFind(id,{open:false});return true;');
  await key({ key: "\u001b", keyCode: 53, modifiers: [], asKey: true, wait: 50 });
}
async function enterFullscreen(connection, id) {
  await readyPage(connection);
  await connection.eval("document.documentElement.requestFullscreen().then(()=>true)", { userGesture: true });
  await sample(`renderer fullscreen ${id}`, (layout) => layout.fullscreenTabId === id);
}
async function engineFullscreen() {
  if (windowNumber === undefined) {
    const inventory = await run('return globalThis.expo.modules.SolaraApp.devWindowLifecycle("inventory",false);');
    windowNumber = inventory.windows.find((window) => window.id === "w1").number;
  }
  return run(`return globalThis.expo.modules.SolaraCEF.devWindow(${windowNumber},"fullScreen").then(JSON.parse);`);
}
async function engineFullscreenExited(label) {
  const state = await until(label, engineFullscreen, (state) => state.fullScreen === false && !state.pageFullScreen?.transitioning);
  evidence.samples.push({ label, engineWindow: state });
}
async function exitFullscreen(connection) {
  await connection.eval("document.fullscreenElement?document.exitFullscreen().then(()=>true):true");
  await sample("renderer fullscreen exited", (layout) => layout.fullscreenTabId === null && !layout.windowTransitioning);
  await engineFullscreenExited("engine fullscreen exit settled");
}
try {
  app = await launch(appPath, {
    data: join(output, "data"), onboarded: true, probe: true, keepData: true,
    session: session({ windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
      tabs: [{ id: "a", url: `${base}/a`, title: "A" }, { id: "b", url: `${base}/b`, title: "B" }],
      settings: { hideToolbarWhileScrolling: true, bookmarksBar: "always", warnBeforeClosingWindow: false, warnBeforeClosingLastTab: false, sleepInactiveTabs: false } }),
    env: { SOLARA_NATIVE_WINDOW_LAYOUT: "1", SOLARA_FAKE_FULLSCREEN_MS: "400" },
    ready: 'return !!ac.store.getState().windows.w1 && !!globalThis.expo.modules.SolaraWindowShell',
  });
  await run('ac.store.getState().updateSettings({hideToolbarWhileScrolling:true,bookmarksBar:"always"});return true;');
  const a = await page("/a");
  await readyPage(a);
  await sample("initial native presentation");
  await sleep(500);
  await a.eval("window.__toolbarResizes=[];addEventListener('resize',()=>window.__toolbarResizes.push({width:innerWidth,height:innerHeight,at:performance.now()}));true");
  await check("renderer scroll controls native toolbar and overlay tops", async () => {
    await focusPage();
    await a.eval("window.__toolbarResizes=[];true");
    await scroll(a, "down");
    const collapsed = await sample("collapsed", (layout) => layout.toolbarModes?.a === "collapsed" && Math.abs(layout.presentationFacts.a.top - 20) <= 0.5);
    assert.equal(collapsed.presentationFacts.a.scrolledDown, true);
    assert.ok(collapsed.shownTops.a > collapsed.presentationFacts.a.top);
    await sleep(150);
    const hideResizes = await a.eval("window.__toolbarResizes");
    await a.eval("window.__toolbarResizes=[];true");
    await scroll(a, "up");
    await sample("shown", (layout) => layout.toolbarModes?.a === "shown" && Math.abs(layout.presentationFacts.a.top - layout.shownTops.a) <= 0.5);
    await sleep(150);
    const showResizes = await a.eval("window.__toolbarResizes");
    evidence.rendererResizes = { hide: hideResizes, show: showResizes };
    assert.ok(hideResizes.length <= 1, `hide resized the renderer ${hideResizes.length} times: ${JSON.stringify(hideResizes)}`);
    assert.ok(showResizes.length <= 1, `show resized the renderer ${showResizes.length} times: ${JSON.stringify(showResizes)}`);
  });
  await run('const s=ac.store.getState();s.activate("b");return true;');
  const b = await page("/b");
  await readyPage(b);
  await run('ac.store.getState().activate("a");return true;');
  for (const spec of [{ key: "l", keyCode: 37, modifiers: ["command"] }, { key: "f", keyCode: 3, modifiers: ["command"] }]) {
    await check(`scroll then ⌘${spec.key.toUpperCase()} and switch preserves the newest field focus`, async () => {
      await closeFields();
      await run('ac.store.getState().activate("a");return true;');
      await sample("a selected", (layout) => layout.selectedTabId === "a");
      await focusPage();
      await scroll(a, "up");
      await sample("scroll reset", (layout) => layout.toolbarModes.a === "shown");
      await scroll(a, "down");
      await sample("scroll hidden before command", (layout) => layout.toolbarModes.a === "collapsed");
      await key({ ...spec, asKey: true, wait: 20 });
      await sample("command reveal", (layout) => layout.toolbarModes.a === "shown");
      await run(`ac.store.getState().activate("b");return ac.shell.devKeyEquivalent("w1",${JSON.stringify({ ...spec, asKey: true, wait: 80 })});`);
      await sample("new command target", (layout) => layout.selectedTabId === "b" && layout.toolbarModes.b === "shown");
      await sleep(450);
      const responder = await key({ key: "\u0000", keyCode: 0, modifiers: [], dry: true, wait: 10 });
      assert.ok(responder.firstResponder && !["RenderWidgetHostViewCocoa", "NSWindow", "SolaraCoreNSWindow"].includes(responder.firstResponder), JSON.stringify(responder));
      await closeFields();
    });
  }
  await run('const s=ac.store.getState();const id=s.createSplit(["a","b"]);s.activate("a");return id;');
  await sample("split installed", (layout) => layout.panes.a && layout.panes.b);
  const splitRegistrations = await registrations();
  assert.ok(splitRegistrations.filter((row) => ["a", "b"].includes(row.tabId)).every((row) => row.registrationGeneration > 0 && row.browserId !== null));
  await check("actual renderer fullscreen in the focused split pane preserves sibling pages", async () => {
    await run('ac.store.getState().activate("a");return true;');
    await enterFullscreen(a, "a");
    const layout = await sample("focused split fullscreen geometry", (layout) => layout.fullscreenTabId === "a");
    assert.ok(layout.panes.a && layout.panes.b, "both pane hosts survive the cover");
    assert.ok(layout.pages.a[2] >= layout.pages.b[2]);
    assert.equal(await b.eval("document.visibilityState"), "visible");
    assert.deepEqual(await registrations(), splitRegistrations);
    await exitFullscreen(a);
    assert.deepEqual(await registrations(), splitRegistrations);
  });
  await check("Chrome rejects background fullscreen; current native facts cover an unfocused split pane without changing focus", async () => {
    await run('ac.store.getState().activate("a");return true;');
    await sample("a selected before background request", (layout) => layout.selectedTabId === "a");
    const rejected = await b.eval("document.documentElement.requestFullscreen().then(()=>({granted:true}),error=>({granted:false,name:error.name,message:error.message}))", { userGesture: true });
    evidence.unfocusedRendererRequest = rejected;
    assert.equal(rejected.granted, false, "Chrome refuses the unfocused document request");
    await sample("background renderer request rejected", (layout) => layout.fullscreenTabId === null && layout.selectedTabId === "a");
    assert.equal(await b.eval("!!document.fullscreenElement"), false);
    const focusBefore = { pages: await Promise.all([a.eval("document.hasFocus()"), b.eval("document.hasFocus()")]), responder: (await key({ key: "\u0000", keyCode: 0, modifiers: [], dry: true, wait: 10 })).firstResponder };
    const accepted = await run('return globalThis.expo.modules.SolaraTabPool.devPageEvent("b","onFullscreen",{fullscreen:true});');
    assert.equal(accepted, true, "the current pooled registration accepts its native fullscreen fact");
    const layout = await sample("native unfocused split fullscreen fact", (layout) => layout.fullscreenTabId === "b" && layout.selectedTabId === "a");
    assert.ok(layout.panes.a && layout.panes.b, "both pane hosts survive the native cover");
    assert.ok(layout.pages.b[2] >= layout.pages.a[2]);
    assert.equal(await a.eval("document.visibilityState"), "visible");
    assert.deepEqual(await registrations(), splitRegistrations);
    const focusAfter = { pages: await Promise.all([a.eval("document.hasFocus()"), b.eval("document.hasFocus()")]), responder: (await key({ key: "\u0000", keyCode: 0, modifiers: [], dry: true, wait: 10 })).firstResponder };
    assert.deepEqual(focusAfter, focusBefore, "native presentation facts preserve the current responder");
    evidence.unfocusedNativeFact = { tabId: "b", name: "onFullscreen", accepted, selectedTabId: layout.selectedTabId, focusBefore, focusAfter };
    assert.equal(await run('return globalThis.expo.modules.SolaraTabPool.devPageEvent("b","onFullscreen",{fullscreen:false});'), true);
    await sample("native unfocused fullscreen fact cleared", (layout) => layout.fullscreenTabId === null && layout.selectedTabId === "a");
  });
  await check("closing an actual renderer fullscreen split tab removes its facts and restores the surviving pane", async () => {
    await run('ac.store.getState().activate("b");return true;');
    await sample("b selected for renderer fullscreen close", (layout) => layout.selectedTabId === "b");
    await run('return ac.webviews.get("b").focus().then(()=>true);');
    await enterFullscreen(b, "b");
    await run('ac.store.getState().closeTab("b");return true;');
    await sample("fullscreen tab closed", (layout) => layout.fullscreenTabId === null && layout.selectedTabId === "a" && !layout.presentationFacts.b);
    await engineFullscreenExited("engine fullscreen tab close settled");
    assert.equal(await run('return globalThis.expo.modules.SolaraTabPool.devPageEvent("b","onFullscreen",{fullscreen:true});'), false);
    const remaining = (await registrations()).find((row) => row.tabId === "a");
    assert.deepEqual(remaining, splitRegistrations.find((row) => row.tabId === "a"));
  });
  await check("Peek fullscreen closes without replacing the source page", async () => {
    const before = (await registrations()).find((row) => row.tabId === "a");
    const peek = await run(`return ac.store.getState().openPeek("a",${JSON.stringify(`${base}/peek`)});`);
    const peekPage = await page("/peek");
    await run(`return ac.webviews.get(${JSON.stringify(peek)}).focus().then(()=>true);`);
    await enterFullscreen(peekPage, peek);
    const layout = await sample("Peek fullscreen cover", (layout) => layout.fullscreenTabId === peek);
    assert.ok(layout.panes.a, "source pane remains mounted under Peek fullscreen");
    await run(`ac.store.getState().closeTab(${JSON.stringify(peek)});return true;`);
    await sample("Peek closed", (layout) => layout.fullscreenTabId === null && layout.selectedTabId === "a" && !layout.presentationFacts[peek]);
    await engineFullscreenExited("engine fullscreen Peek close settled");
    assert.deepEqual((await registrations()).find((row) => row.tabId === "a"), before);
  });
  await check("resize during acted Spaces transitions keeps window policy separate", async () => {
    const inventory = await run('return globalThis.expo.modules.SolaraApp.devWindowLifecycle("inventory",false);');
    const number = inventory.windows.find((window) => window.id === "w1").number;
    const act = (action) => run(`return globalThis.expo.modules.SolaraCEF.devWindow(${number},${JSON.stringify(action)});`);
    for (const entered of [true, false]) {
      await act(`fakeFullScreen:${entered ? 1 : 0}:1200`);
      await sample("Spaces transitioning", (layout) => layout.windowTransitioning);
      await run(`ac.store.getState().setWindowFrame("w1",[80,80,${entered ? 1140 : 1280},780]);return true;`);
      const layout = await sample("Spaces settled", (layout) => !layout.windowTransitioning && layout.windowFullscreen === entered);
      assert.equal(layout.fullscreenTabId, null);
      assert.equal(layout.toolbarModes.a, "shown");
    }
  });
  await check("native path mounts no React toolbar auto-hide or page layout decision hosts", async () => {
    const mounts = await run('return Object.fromEntries(["NativeAutoHide","AutoHideToolbar","LegacyContentCard","TabPane","WindowToolbar"].map(name=>[name,acPerf.findFibers(name,50).length]));');
    assert.ok(Object.values(mounts).every((count) => count === 0), JSON.stringify(mounts));
    const appearanceOnly = await run('return acPerf.findFibers("NativeAutoHideStyleFeed",50).every(fiber=>fiber.child===null);');
    assert.equal(appearanceOnly, true, "remaining auto-hide feeds provide appearance without layout children");
    await sample("final coherent native layout");
  });
} catch (error) {
  evidence.error = String(error.stack ?? error);
  process.exitCode = 1;
  console.error(evidence.error);
} finally {
  for (const connection of connections) connection.close();
  if (app) await app.quit();
  await new Promise((done) => server.close(done));
  writeFileSync(join(output, "native-presentation-result.json"), JSON.stringify(evidence, null, 2));
  console.log(`evidence: ${output}`);
}
