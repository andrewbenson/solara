import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { launch, session, sleep } from "../../../scripts/lib/instance.mjs";

const [appArg, outputArg] = process.argv.slice(2);
assert.ok(appArg && outputArg, "usage: node apps/browser/scripts/native-page-commands-test.mjs <Debug app> <fresh output directory>");
const baseline = process.argv.includes("--baseline");
const appPath = resolve(appArg);
const output = resolve(outputArg);
assert.equal(execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print CFBundleIdentifier", join(appPath, "Contents/Info.plist")], { encoding: "utf8", timeout: 5000 }).trim(), "network.benson.solara.dev");
mkdirSync(output, { recursive: true });
const evidence = [];
const requests = new Map();
const server = createServer((req, res) => {
  const path = new URL(req.url, "http://x").pathname;
  requests.set(path, (requests.get(path) ?? 0) + 1);
  if (path === "/slow") {
    res.writeHead(200, { "content-type": "text/html", "cache-control": "no-store" });
    res.write("<!doctype html><title>Slow</title><body>slow");
    const hold = setTimeout(() => res.end("</body>"), 20000);
    res.on("close", () => clearTimeout(hold));
    return;
  }
  res.writeHead(200, { "content-type": "text/html", "cache-control": "no-store" });
  res.end(`<!doctype html><title>Page ${path}</title><link rel="icon" href="data:,"><body>${path}</body>`);
});
let app;
let handlerBaseline;
const run = (body) => app.eval(body, { timeout: 2000 });
const nativeState = async () => (await run(`
  const module = expo.modules.SolaraStoreAdapter;
  const status = module.status();
  if (!status.active || status.frozen !== false) throw new Error("native workspace ownership required");
  return JSON.parse(module.snapshot());
`)).data;
const menu = (windowId, command, arg = null) =>
  run(`return expo.modules.SolaraApp.devWorkspaceMenuCommand(${JSON.stringify(windowId)}, ${JSON.stringify(command)}, ${JSON.stringify(arg)});`);
const press = async (key, keyCode, modifiers) => {
  const result = await run(`return ac.shell.devKeyEquivalent("w1", ${JSON.stringify({ key, keyCode, modifiers, focus: "window", asKey: true, wait: 30 })});`);
  assert.equal(result.error, undefined, JSON.stringify(result));
  assert.notEqual(result.handledBy, "none", `${key}: shortcut was not handled`);
  return result;
};
const bridge = (command, windowId = "w1") =>
  run(`ac.runCommand({ command: ${JSON.stringify(command)}, arg: null, windowId: ${JSON.stringify(windowId)} }); return true;`);

async function until(label, accept, ms = 12000) {
  const deadline = Date.now() + ms;
  let last;
  while (Date.now() + 1000 < deadline) {
    assert.ok(app.alive, `${label}: owned instance exited`);
    last = await nativeState();
    if (await accept(last)) return last;
    await sleep(50);
  }
  evidence.push({ label, failed: true, requests: Object.fromEntries(requests), tabs: last?.tabs });
  writeFileSync(join(output, "evidence.json"), JSON.stringify(evidence, null, 2));
  throw new Error(`${label}: deadline exceeded`);
}

async function handledNatively(label) {
  if (baseline) return;
  await sleep(200);
  const stats = await run("return ac.commandHandlers.stats();");
  assert.equal(stats.enabled, false, `${label}: JS handlers unexpectedly enabled`);
  assert.equal(stats.calls, handlerBaseline.calls, `${label}: JS handler made a decision`);
  assert.equal(stats.blocked, handlerBaseline.blocked, `${label}: command fell through to disabled JS`);
}

function pass(label, details = {}) {
  evidence.push({ label, ...details });
  writeFileSync(join(output, "evidence.json"), JSON.stringify(evidence, null, 2));
  console.log(`PASS ${label}`);
}

async function step(label, trigger, accept) {
  const before = await nativeState();
  await trigger();
  const after = await until(label, (state) => accept(before, state));
  await handledNatively(label);
  pass(label);
  return { before, after };
}

const tab = (s, id) => s.tabs[id];
const loads = (path) => requests.get(path) ?? 0;
async function reloads(label, path, trigger) {
  const before = loads(path);
  await trigger();
  const deadline = Date.now() + 12000;
  while (loads(path) <= before) {
    assert.ok(Date.now() < deadline, `${label}: the page never asked the server again`);
    await sleep(50);
  }
  await handledNatively(label);
  pass(label, { requests: loads(path) - before });
}

try {
  await new Promise((done, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", done); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const other = `http://localhost:${server.address().port}`;
  app = await launch(appPath, {
    data: join(output, "data"), fresh: true, onboarded: true, probe: true, keepData: true,
    env: { SOLARA_NATIVE_WINDOW_LAYOUT: process.env.SOLARA_NATIVE_WINDOW_LAYOUT ?? "1" },
    session: session({
      windows: [{ id: "w1", frame: [80, 80, 1100, 800], activeTabIds: { default: "a" } }],
      tabs: [{ id: "a", url: `${base}/a`, title: "A" }, { id: "b", url: `${other}/b`, title: "B" }],
      settings: { sleepInactiveTabs: false, warnBeforeClosingWindow: false, warnBeforeClosingLastTab: false },
    }),
    ready: "return !!ac.commandHandlers && !!ac.runCommand && !!ac.shell.devKeyEquivalent && !!globalThis.acPerf && !!expo.modules.SolaraApp.devWorkspaceMenuCommand && !!ac.store.getState().windows.w1;",
  });
  const probe = await menu("w1", "noSuchCommand");
  assert.equal(probe?.debug, true, "devWorkspaceMenuCommand did nothing: this driver needs a Debug build (the hook is compiled out of Release)");
  const deadline = Date.now() + 15000;
  while (loads("/a") < 1) {
    assert.ok(Date.now() < deadline, "the first page never loaded");
    await sleep(100);
  }
  await sleep(500);
  handlerBaseline = await run(`const stats = ac.commandHandlers.stats(); ac.commandHandlers.setEnabled(${baseline}); return stats;`);

  pass("native layout capability", { layout: await run('return expo.modules.SolaraWindowShell.nativeLayout("w1");') });
  if (!baseline) {
    const probe = (action) => run(`return expo.modules.SolaraSettings.devLinkCommands(${JSON.stringify(action)});`);
    await probe("begin");
    try {
      await menu("w1", "copyUrl");
      assert.deepEqual(await probe("read"), [`${base}/a`]);
      await bridge("copyUrlAsMarkdown");
      assert.equal((await probe("read")).at(-1), `[Page /a](${base}/a)`);
      await press("C", 8, ["command", "shift"]);
      assert.equal((await probe("read")).at(-1), `${base}/a`);
      const page = await app.page("/a");
      await page.eval("getSelection().selectAllChildren(document.body); true");
      await menu("w1", "copyUrl");
      await until("quote offer then native toast action", async () => {
        await probe("quote");
        return (await probe("read")).at(-1)?.includes("#:~:text=");
      });
      await menu("w1", "copyUrl");
      await until("quote offer receipt", async () => (await probe("offer")).length > 0);
      const captured = (await probe("read")).length;
      await run(`ac.store.getState().navigate("a", ${JSON.stringify(`${base}/a?new-document`)}); return true;`);
      await until("quote source navigated", s => s.tabs.a.url === `${base}/a?new-document`);
      await probe("quote");
      assert.equal((await probe("read")).length, captured, "stale quote action copied from a newer document");
      await run(`ac.store.getState().navigate("a", ${JSON.stringify(`${base}/a`)}); return true;`);
      await until("copy fixture restored", s => s.tabs.a.url === `${base}/a`);
      await page.eval("getSelection().removeAllRanges(); true");
      const count = (await probe("read")).length;
      await menu("w1", "copyQuoteLink");
      await handledNatively("copy, Markdown, shortcut, quote toast and empty quote");
      assert.equal((await probe("read")).length, count);
      pass("native copy and quote effects use scoped clipboard capture");
    } finally { await probe("end"); }
  }
  const bookmark = await run(`return ac.bookmarks.addBookmark({ profileId: "default", title: "Command bookmark", url: ${JSON.stringify(`${base}/bookmark`)} });`);
  const folder = await run('return ac.bookmarks.addBookmarkFolder({ profileId: "default", title: "Command folder" });');
  async function openBookmarkIn(windowId, tabId) {
    const before = await nativeState();
    if (!baseline) {
      await run('return expo.modules.SolaraSettings.devLinkCommands("begin");');
      try { await menu(windowId, "copyUrl"); assert.deepEqual(await run('return expo.modules.SolaraSettings.devLinkCommands("read");'), before.tabs[tabId].url ? [before.tabs[tabId].url] : []); await handledNatively("copy routed native target"); }
      finally { await run('return expo.modules.SolaraSettings.devLinkCommands("end");'); }
    }
    await menu(windowId, "openBookmark", bookmark);
    await until("bookmark URL on routed native tab", (s) => s.tabs[tabId]?.url === `${base}/bookmark`);
    await handledNatively("openBookmark");
    const after = await nativeState();
    for (const [id, t] of Object.entries(before.tabs)) {
      if (id !== tabId) assert.equal(after.tabs[id]?.url, t.url, `bookmark changed unrelated tab ${id}`);
    }
    for (const id of [folder, "deleted-bookmark-id"]) {
      await menu(windowId, "openBookmark", id);
      await handledNatively("invalid bookmark consumed");
      assert.equal((await nativeState()).tabs[tabId]?.url, `${base}/bookmark`);
    }
    pass("bookmark menu target and consumed no-ops", { windowId, tabId });
  }
  await openBookmarkIn("w1", "a");
  await run(`ac.store.getState().navigate("a", ${JSON.stringify(`${base}/a`)}); return true;`);
  await until("bookmark leaves page ready for existing checks", (s) => s.tabs.a.url === `${base}/a`);
  await reloads("reload asks the page again", "/a", () => menu("w1", "reload"));
  await reloads("forceReload asks the page again", "/a", () => menu("w1", "forceReload"));
  await reloads("a real ⌘R reloads through the menu", "/a", () => press("r", 15, ["command"]));
  await reloads("reload through the JS bridge", "/a", () => bridge("reload"));
  await step("zoomIn zooms the active page", () => menu("w1", "zoomIn"), (_, s) => tab(s, "a").zoom > 1);
  assert.ok(Math.abs(tab(await nativeState(), "b").zoom - 1) < 0.001, "the background tab on another host keeps its zoom");
  await step("zoomOut zooms it back", () => menu("w1", "zoomOut"), (_, s) => Math.abs(tab(s, "a").zoom - 1) < 0.001);
  await step("zoomIn again", () => menu("w1", "zoomIn"), (_, s) => tab(s, "a").zoom > 1);
  await step("zoomReset resets it", () => menu("w1", "zoomReset"), (_, s) => Math.abs(tab(s, "a").zoom - 1) < 0.001);

  await step("toggleMute mutes the site", () => menu("w1", "toggleMute"), (_, s) => tab(s, "a").muted === true);
  await step("toggleMute unmutes it", () => menu("w1", "toggleMute"), (_, s) => tab(s, "a").muted === false);

  await step("viewSource opens the page's source beside it", () => menu("w1", "viewSource"),
    (b, s) => Object.values(s.tabs).some((t) => !b.tabs[t.id] && t.url === `view-source:${base}/a` && t.openerId === "a"));

  await run('ac.store.getState().activate("a"); return true;');
  await until("the first page is active again", (s) => s.windows.w1.activeTabIds[s.windows.w1.profileId] === "a");
  await menu("w1", "emailPageLocation");
  const external = await run("return expo.modules.SolaraSettings.devPageCommands();");
  assert.equal(external.debug, true, "devPageCommands needs a Debug build");
  assert.equal(external.lastExternal, `mailto:?subject=${encodeURIComponent("Page /a")}&body=${encodeURIComponent(`${base}/a`)}`, "the mail draft Swift would open");
  await handledNatively("emailPageLocation builds the mail draft natively (a hidden instance opens no mail app)");
  pass("emailPageLocation builds the mail draft natively (a hidden instance opens no mail app)");

  const small = await run(`return ac.store.getState().createWindow({ url: ${JSON.stringify(`${other}/c`)}, small: true });`);
  await until("Little Solara window", (s) => s.windows[small]?.kind === "small");
  const smallTab = (s) => s.windows[small].activeTabIds[s.windows[small].profileId];
  const loaded = Date.now() + 15000;
  while (loads("/c") < 1) {
    assert.ok(Date.now() < loaded, "Little Solara's page never loaded");
    await sleep(100);
  }
  await sleep(500);
  const mainZoom = tab(await nativeState(), "a").zoom;
  await step("zoomIn in Little Solara zooms its own page", () => menu(small, "zoomIn"), (_, s) => tab(s, smallTab(s)).zoom > 1);
  await sleep(500);
  assert.equal(tab(await nativeState(), "a").zoom, mainZoom, "the main window's page, on another host, keeps its zoom");
  await step("zoomReset in Little Solara", () => menu(small, "zoomReset"), (_, s) => Math.abs(tab(s, smallTab(s)).zoom - 1) < 0.001);
  const mainLoads = loads("/a");
  await reloads("reload in Little Solara reloads its own page", "/c", () => menu(small, "reload"));
  await sleep(500);
  assert.equal(loads("/a"), mainLoads, "the main window's page is not reloaded");

  await openBookmarkIn(small, smallTab(await nativeState()));
  const blank = await run('return ac.store.getState().newTab("w1", {});');
  await openBookmarkIn("w1", blank);
  await run('ac.store.getState().activate("a"); return true;');
  await run(`ac.runCommand({ command: "openBookmark", arg: ${JSON.stringify(bookmark)}, windowId: "w1" }); return true;`);
  await until("bookmark direct bridge", (s) => s.tabs.a.url === `${base}/bookmark`);
  await handledNatively("bookmark direct bridge");
  await run(`ac.store.getState().openPeek("a", ${JSON.stringify(`${base}/peek`)}); return true;`);
  const peek = await until("bookmark Peek ready", (s) => !!s.peeks?.w1?.tabId);
  await openBookmarkIn("w1", peek.peeks.w1.tabId);
  await run('ac.store.getState().closePeek("w1"); return true;');
  const privateWindow = await run('return ac.store.getState().createWindow({ incognito: true, profileId: "default", url: "about:blank" });');
  const privateState = await until("private bookmark window", (s) => !!s.windows[privateWindow]);
  await openBookmarkIn(privateWindow, privateState.windows[privateWindow].activeTabIds[privateState.windows[privateWindow].profileId]);
  await run(`ac.store.getState().navigate("a", ${JSON.stringify(`${base}/slow`)}); return true;`);
  await until("the slow page is loading", (s) => s.live?.a?.isLoading === true);
  await step("stop ends the load", () => menu("w1", "stop"), (_, s) => s.live?.a?.isLoading === false);

  const services = (action, urls = []) => run(`return expo.modules.SolaraSettings.devBrowserServiceCommands(${JSON.stringify(action)}, ${JSON.stringify(urls)});`);
  async function pick(windowId, urls, trigger = () => menu(windowId, "openFile"), mutate = null) {
    if (baseline) {
      await run(`globalThis.filePickerOriginal = expo.modules.SolaraShell.pickFiles; expo.modules.SolaraShell.pickFiles = () => new Promise(resolve => { globalThis.finishFilePicker = resolve; }); return true;`);
    } else await services("begin");
    try {
      await trigger();
      if (baseline) await until("baseline picker pending", async () => await run("return typeof finishFilePicker === 'function';"));
      if (!baseline) assert.deepEqual(await services("read"), ["picker"]);
      if (mutate) await mutate();
      if (baseline) await run(`finishFilePicker(${JSON.stringify(urls)}); return true;`);
      else await services("complete", urls);
      await handledNatively("Open File picker completion");
    } finally {
      if (baseline) await run(`expo.modules.SolaraShell.pickFiles = filePickerOriginal; delete globalThis.finishFilePicker; delete globalThis.filePickerOriginal; return true;`);
      else await services("end");
    }
  }
  await run('ac.store.getState().activate("a"); return true;');
  const cancelBefore = await nativeState();
  await pick("w1", []);
  assert.deepEqual((await nativeState()).windows.w1.tabIds, cancelBefore.windows.w1.tabIds);
  pass("file picker cancellation creates no tabs");
  const files = ["file:///solara-fixture-one.html", "file:///solara-fixture-two.html"];
  await pick("w1", files, () => press("o", 31, ["command"]));
  await until("two files with last active", s => s.tabs[s.windows.w1.activeTabIds[s.windows.w1.profileId]]?.url === files[1]);
  assert.equal(Object.values((await nativeState()).tabs).filter(t => files.includes(t.url)).length, 2);
  pass("Open File shortcut opens all files and activates last");
  await run('ac.store.getState().activate("a"); return true;');
  const staleURL = "file:///solara-stale-picker.html";
  await pick("w1", [staleURL], () => bridge("openFile"), () => run('ac.store.getState().activate("b"); return true;'));
  if (baseline) await until("baseline picker retargets after active tab change", s => Object.values(s.tabs).some(t => t.url === staleURL));
  else assert.ok(!Object.values((await nativeState()).tabs).some(t => t.url === staleURL));
  pass("picker active-target race", { baselineRetargets: baseline });
  const promotedSmallTab = smallTab(await nativeState());
  await menu(small, "openFile");
  await until("Open File expands Little Solara without picker", s => !s.windows[small] && s.tabs[promotedSmallTab]?.windowId !== small);
  await handledNatively("Little Solara Open File");
  await run('ac.store.getState().activate("a"); return true;');
  await run(`ac.store.getState().openPeek("a", ${JSON.stringify(`${base}/service-peek`)}); return true;`);
  const servicePeek = (await until("service Peek", s => !!s.peeks.w1)).peeks.w1.tabId;
  await menu("w1", "openFile");
  await until("Open File promotes Peek without picker", s => !s.peeks.w1 && s.windows.w1.activeTabIds[s.windows.w1.profileId] === servicePeek);
  await handledNatively("Peek Open File");
  await until("autofill source ready", async () => !!(await run(`return JSON.parse(expo.modules.SolaraStoreAdapter.pageFacts(${JSON.stringify(servicePeek)}) || "null")?.ready;`)));
  if (!baseline) {
    await services("begin");
    try {
      await services("shown");
      await menu("w1", "autofill");
      assert.deepEqual(await services("read"), ["field"]);
      await services("refused");
      await menu("w1", "autofill", "passwords");
      assert.deepEqual((await services("read")).slice(-2), ["passwords", "settings:passwords:default"]);
      await menu(privateWindow, "autofill");
      assert.equal((await services("read")).at(-1), "settings:autofill:default");
      await handledNatively("autofill shown/refused and private Settings profile");
      pass("native autofill modes, successful suggestion suppresses Settings, private refusal uses original profile");
    } finally { await services("end"); }
  } else {
    await run(`globalThis.autofillOriginals = [expo.modules.SolaraChromeUI.showAutofillSuggestions, expo.modules.SolaraSettings.navigate, expo.modules.SolaraShell.openWindow];
      globalThis.autofillCalls = []; globalThis.autofillShown = true;
      expo.modules.SolaraChromeUI.showAutofillSuggestions = (id, passwords) => { autofillCalls.push(passwords ? "passwords" : "field"); return Promise.resolve(autofillShown); };
      expo.modules.SolaraSettings.navigate = (pane, profile) => { autofillCalls.push("settings:" + pane + ":" + profile); return Promise.resolve(); };
      expo.modules.SolaraShell.openWindow = () => Promise.resolve(); return true;`);
    try {
      await menu("w1", "autofill");
      await until("baseline autofill shown", async () => (await run("return autofillCalls;")).length === 1);
      assert.deepEqual(await run("return autofillCalls;"), ["field"]);
      await run("autofillShown = false; return true;");
      await menu("w1", "autofill", "passwords");
      await until("baseline passwords Settings", async () => (await run("return autofillCalls;")).at(-1) === "settings:passwords:default");
      assert.deepEqual((await run("return autofillCalls;")).slice(-2), ["passwords", "settings:passwords:default"]);
      await menu(privateWindow, "autofill");
      await until("baseline private Settings", async () => (await run("return autofillCalls;")).at(-1) === "settings:autofill:null");
      assert.equal((await run("return autofillCalls;")).at(-1), "settings:autofill:null");
      pass("baseline autofill success/refusal and private default Settings profile");
    } finally {
      await run(`expo.modules.SolaraChromeUI.showAutofillSuggestions = autofillOriginals[0]; expo.modules.SolaraSettings.navigate = autofillOriginals[1]; expo.modules.SolaraShell.openWindow = autofillOriginals[2]; delete globalThis.autofillOriginals; delete globalThis.autofillCalls; delete globalThis.autofillShown; return true;`);
    }
  }
  const pickerWindow = await run(`return ac.store.getState().createWindow({ url: ${JSON.stringify(`${base}/picker-window`)} });`);
  await until("second picker window", s => !!s.windows[pickerWindow]);
  const mainTabs = (await nativeState()).windows.w1.tabIds;
  await pick(pickerWindow, ["file:///solara-second-window.html"]);
  await until("picker stays in invoking window", s => Object.values(s.tabs).some(t => t.windowId === pickerWindow && t.url === "file:///solara-second-window.html"));
  assert.deepEqual((await nativeState()).windows.w1.tabIds, mainTabs);
  const closedURL = "file:///solara-closed-picker.html";
  await pick(pickerWindow, [closedURL], () => menu(pickerWindow, "openFile"), async () => {
    await menu(pickerWindow, "closeWindow");
    await until("picker invoking window closed", s => !s.windows[pickerWindow]);
  });
  if (baseline) await until("baseline closed picker reroutes", s => Object.values(s.tabs).some(t => t.url === closedURL));
  else assert.ok(!Object.values((await nativeState()).tabs).some(t => t.url === closedURL));
  pass("picker second-window isolation and closed-window receipt");
  for (const id of [...(await nativeState()).windowOrder]) await run(`ac.store.getState().closeWindow(${JSON.stringify(id)}); return true;`);
  await until("no browser windows", s => s.windowOrder.length === 0);
  const noWindowFiles = ["file:///solara-no-window-one.html", "file:///solara-no-window-two.html"];
  await pick(null, noWindowFiles, () => bridge("openFile", null));
  const created = await until("no-window picker creates window", s => s.windowOrder.length === 1);
  const createdWindow = created.windowOrder[0];
  const expected = baseline ? noWindowFiles[0] : noWindowFiles[1];
  assert.equal(created.tabs[created.windows[createdWindow].activeTabIds[created.windows[createdWindow].profileId]]?.url, expected);
  assert.equal(Object.values(created.tabs).filter(t => noWindowFiles.includes(t.url)).length, baseline ? 1 : 2);
  pass("no-window multiple-file behavior", { expectedFiles: baseline ? 1 : 2 });

  writeFileSync(join(output, "result.json"), JSON.stringify({ passed: true, checks: evidence.map((e) => e.label) }, null, 2));
  console.log(`${evidence.length}/${evidence.length} passed`);
} finally {
  if (app) await app.quit();
  server.closeAllConnections();
  await new Promise((done) => server.listening ? server.close(done) : done());
}
