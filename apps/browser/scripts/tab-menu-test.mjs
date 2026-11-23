#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";
import { sidebarSession } from "./sidebar-position-test.mjs";

const args = process.argv.slice(2);
const positional = args.filter((arg) => !arg.startsWith("--"));
if (args.includes("--help") || positional.length !== 2) {
  console.log("usage: node apps/browser/scripts/tab-menu-test.mjs <Debug Solara.app> <scratch directory> [--keep-data]\n\nExercises the native single-tab context menu and its pin, group, profile and window commands. Each command is reversed by one applyState inverse transaction, matching PinnedRowsTests; Solara has no general store undo command. Playing-page and split moves are compared with the existing JavaScript actions. All test output stays under the supplied scratch directory.");
  process.exit(args.includes("--help") ? 0 : 2);
}
const appPath = resolve(positional[0]);
assert.ok(!appPath.startsWith("/Applications/") && !appPath.includes("/build-vista/"), "use an isolated Debug app");
mkdirSync(resolve(positional[1]), { recursive: true });
const scratch = mkdtempSync(join(resolve(positional[1]), "tab-menu-"));
const keep = args.includes("--keep-data");
const rep = reporter(join(scratch, "tab-menu-test.log"), { name: "tab-menu-test" });
const tone = (() => {
  const rate = 8000, samples = rate * 20;
  const bytes = Buffer.alloc(44 + samples * 2);
  bytes.write("RIFF", 0); bytes.writeUInt32LE(36 + samples * 2, 4); bytes.write("WAVE", 8); bytes.write("fmt ", 12);
  bytes.writeUInt32LE(16, 16); bytes.writeUInt16LE(1, 20); bytes.writeUInt16LE(1, 22); bytes.writeUInt32LE(rate, 24);
  bytes.writeUInt32LE(rate * 2, 28); bytes.writeUInt16LE(2, 32); bytes.writeUInt16LE(16, 34); bytes.write("data", 36); bytes.writeUInt32LE(samples * 2, 40);
  for (let i = 0; i < samples; i++) bytes.writeInt16LE(Math.round(Math.sin(2 * Math.PI * 440 * i / rate) * 32), 44 + i * 2);
  return bytes;
})();
const loads = new Map();
const server = createServer((req, res) => {
  if (req.url === "/tone.wav") {
    res.writeHead(200, { "content-type": "audio/wav", "content-length": String(tone.length) });
    return res.end(tone);
  }
  const count = (loads.get(req.url) ?? 0) + 1;
  loads.set(req.url, count);
  res.writeHead(200, { "content-type": "text/html", "cache-control": "no-store" });
  res.end(`<!doctype html><title>${req.url}</title><link rel="icon" href="data:,"><audio id="tone" src="/tone.wav" loop></audio><script>
window.loadToken = ${JSON.stringify(`${req.url}:${count}`)};
window.pauseCount = 0;
navigator.mediaSession.metadata = new MediaMetadata({ title: "Tab Menu Fixture" });
tone.addEventListener("play", () => { navigator.mediaSession.playbackState = "playing"; });
tone.addEventListener("pause", () => { window.pauseCount++; navigator.mediaSession.playbackState = "paused"; });
</script>`);
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const url = (id) => `http://127.0.0.1:${server.address().port}/${id}`;
const fixture = sidebarSession({
  profiles: ["Personal", "Work"],
  windows: [
    { id: "w1", profileId: "default", frame: [80, 80, 1100, 760], activeTabIds: { default: "a", work: "work" } },
    { id: "w2", profileId: "default", frame: [300, 120, 1000, 700], activeTabIds: { default: "other" } },
  ],
  tabs: [
    ...["a", "b", "c", "media", "split", "mate"].map((id) => ({ id, windowId: "w1", profileId: "default", url: url(id), title: id })),
    { id: "work", windowId: "w1", profileId: "work", url: url("work"), title: "work" },
    { id: "other", windowId: "w2", profileId: "default", url: url("other"), title: "other" },
  ],
  settings: { warnBeforeMovingTabsToProfile: false, warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, warnBeforeClosingTabGroup: false, cmdClickCreatesTabGroup: false, newTabOpens: "page", newTabPosition: "bottom" },
});
let app;
const HELPERS = `
const st = () => ac.store.getState();
const D = expo.modules.SolaraSidebarDrag;
const M = expo.modules.SolaraShell;
const A = expo.modules.SolaraStoreAdapter;
const snap = () => JSON.parse(A.snapshot());
const settle = (ms) => new Promise((done) => setTimeout(done, ms));
const projection = (s) => ({
  tabs: Object.fromEntries(Object.entries(s.tabs).map(([id,t]) => [id, Object.fromEntries(["id","windowId","profileId","url","pinned","pinnedAsRow","pinKey","pinListSpot","pinHome","pinnedUrl","customTitle","customIcon","muted","tileFolder","engine"].filter((k) => t[k] !== undefined).map((k) => [k,t[k]]))])),
  windows: Object.fromEntries(Object.entries(s.windows).map(([id,w]) => [id, { profileId:w.profileId, tabIds:w.tabIds, activeTabIds:w.activeTabIds }])),
  groups:s.groups, splits:s.splits, windowOrder:s.windowOrder,
});
`;
const run = (body, timeout = 20000) => app.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, read, accept = Boolean, ms = 10000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    assert.ok(app.alive, `${what}: the owned instance is alive`);
    last = await read().catch((error) => ({ error: error.message }));
    if (last && !last.error && accept(last)) return last;
    await sleep(100);
  }
  assert.fail(`${what}: timed out (${JSON.stringify(last)})`);
};
const shape = () => run("return projection(snap().data);");
const capture = () => run(`const s = snap().data; return Object.fromEntries(["tabs","windows","groups","splits","windowOrder","closedTabs","closedWindows","closedGroups","deletedGroups","cleanedTabs","parkedPins","pinChoices","pinSync","peeks","ui"].filter((k) => s[k] !== undefined).map((k) => [k,s[k]]));`);
const reverse = async (before, expected) => {
  const response = await run(`return JSON.parse(A.dispatch(JSON.stringify({name:"applyState", args:[${JSON.stringify(before)}]}), snap().rev));`);
  assert.ok(!response.error, `inverse transaction: ${JSON.stringify(response)}`);
  await until("one inverse transaction restores store structure", shape, (got) => {
    try { assert.deepEqual(got, expected); return true; } catch { return false; }
  });
};
const open = async (tabId, choice, windowId = "w1") => {
  const before = await run("return D.devTabMenus();");
  await run(`return M.devContextMenu("arm", ${JSON.stringify(choice)});`);
  assert.equal(await run(`return D.devTabMenu(${JSON.stringify(windowId)}, ${JSON.stringify(tabId)});`), true, "native store owns the menu");
  const menu = await until("context menu captured", () => run('return M.devContextMenu("read", null);'), (menu) => Array.isArray(menu.items));
  if (choice) assert.equal(menu.accepted, true, `menu accepted ${choice}: ${JSON.stringify(menu)}`);
  assert.equal(await run("return D.devTabMenus();"), before + 1, "Swift presented exactly one menu");
  await sleep(250);
  return menu;
};
const commandLeg = async (name, tabId, choice, setup, check) => rep.check(name, async () => {
  const beforeSetup = setup ? await capture() : null;
  const expectedSetup = setup ? await shape() : null;
  try {
    if (setup) await run(`${setup}; return settle(300);`);
    const before = await capture();
    const expected = await shape();
    await open(tabId, choice);
    await until(`${choice} store result`, () => run(`const s = st(); return ${check};`));
    await reverse(before, expected);
  } finally {
    if (setup) await reverse(beforeSetup, expectedSetup);
  }
});
const inPage = async (id, expression) => {
  const page = await app.page(url(id));
  try { return await page.eval(expression, { userGesture: true }); } finally { page.close(); }
};
const pageState = (id) => inPage(id, "({token:window.loadToken, paused:tone.paused, pauses:window.pauseCount, time:tone.currentTime})");
const mediaLeg = async (tabId, target) => rep.check(`${tabId} to ${target}: playing and split behavior matches JavaScript`, async () => {
  const observations = [];
  for (const path of ["JavaScript", "Swift"]) {
    await run(`st().activate(${JSON.stringify(tabId)}); return settle(400);`);
    if (tabId === "split") await run('st().createSplit(["split","mate"]); return settle(300);');
    await until("playing fixture loaded", () => inPage(tabId, "!!window.loadToken"));
    await inPage(tabId, "tone.play().then(() => true)");
    await until("fixture plays", () => pageState(tabId), (state) => !state.paused);
    const beforePage = await pageState(tabId);
    let beforeMate = null;
    if (tabId === "split") {
      await until("split sibling loaded", () => inPage("mate", "!!window.loadToken"));
      await inPage("mate", "tone.play().then(() => true)");
      beforeMate = await until("split sibling plays", () => pageState("mate"), (state) => !state.paused);
    }
    const before = await capture();
    const expected = await shape();
    if (path === "Swift") await open(tabId, target);
    else if (target.startsWith("window:")) await run(`ac.actions.moveTabToWindow(${JSON.stringify(tabId)}, ${JSON.stringify(target.slice(7))}); return true;`);
    else await run(`return ac.actions.moveTabToProfile(${JSON.stringify(tabId)}, ${JSON.stringify(target.slice(8))}).then(() => true);`);
    const expectedWindow = target.startsWith("window:") ? target.slice(7) : "w1";
    const expectedProfile = target.startsWith("profile:") ? target.slice(8) : "default";
    await until("moved tab owner", () => run(`const t = st().tabs[${JSON.stringify(tabId)}]; return t && t.windowId === ${JSON.stringify(expectedWindow)} && t.profileId === ${JSON.stringify(expectedProfile)};`));
    await until("moved page available", () => pageState(tabId));
    await sleep(800);
    const afterPage = await pageState(tabId);
    const afterMate = beforeMate ? await pageState("mate") : null;
    const storeState = await shape();
    const focusedWindow = await run("return st().ui.focusedWindowId;");
    observations.push({ sibling: beforeMate ? { reloaded: afterMate.token !== beforeMate.token, paused: afterMate.paused, extraPause: afterMate.token === beforeMate.token ? afterMate.pauses - beforeMate.pauses : 0 } : null, focusedWindow, reloaded: afterPage.token !== beforePage.token, paused: afterPage.paused, extraPause: afterPage.token === beforePage.token ? afterPage.pauses - beforePage.pauses : 0, groupIds: Object.keys(storeState.groups), split: Object.values(storeState.splits).filter((split) => split.tabIds.includes(tabId)).map((split) => split.tabIds), mateWindow: storeState.tabs.mate?.windowId, active: storeState.windows[expectedWindow].activeTabIds[expectedProfile] });
    await reverse(before, expected);
    await run(`st().activate(${JSON.stringify(tabId)}); return settle(600);`);
  }
  assert.deepEqual(observations[1], observations[0], JSON.stringify({ js: observations[0], swift: observations[1] }));
  rep.log(`${tabId} ${target}: ${JSON.stringify(observations[1])}`);
});
try {
  app = await launch(appPath, { data: join(scratch, "data"), fresh: true, onboarded: true, session: session(fixture), probe: true,
    env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_TOP_STRIP: "1", SOLARA_ALLOW_AUDIO: "1" },
    switches: "--disable-audio-output --autoplay-policy=no-user-gesture-required",
    ready: "return !!ac.store?.getState().windows.w2 && !!expo.modules.SolaraSidebarDrag.devTabMenu && expo.modules.SolaraStoreAdapter.status().active === true && !expo.modules.SolaraStoreAdapter.status().frozen" });
  await rep.check("native single-tab menu has Move to with profile and window choices", async () => {
    const menu = await open("a", null);
    const move = menu.items.find((item) => item.title === "Move to" && Array.isArray(item.children));
    assert.ok(move, `a Move to submenu: ${JSON.stringify(menu.items.map((item) => item.title ?? "—"))}`);
    const ids = move.children.map((item) => item.separator ? "-" : item.id ?? item.title);
    for (const id of ["pinTile", "pinRow", "profile:work", "Window"]) assert.ok(ids.includes(id), `${id} in Move to: ${JSON.stringify(ids)}`);
    const windows = move.children.find((item) => item.title === "Window").children.map((item) => item.separator ? "-" : item.id);
    assert.deepEqual(windows, ["window:w2", "-", "window:new"]);
  });
  await commandLeg("pin toggles a regular tab", "a", "pin", null, 's.tabs.a.pinned && !s.tabs.a.pinnedAsRow');
  await commandLeg("pin toggles a pinned tile off", "b", "pin", 'st().pinTabs(["b"], true)', '!s.tabs.b.pinned');
  await commandLeg("pinTile moves an ordinary tab to Top Apps", "a", "pinTile", null, 's.tabs.a.pinned && !s.tabs.a.pinnedAsRow');
  await commandLeg("pinRow moves an ordinary tab to Pinned", "a", "pinRow", null, 's.tabs.a.pinned && s.tabs.a.pinnedAsRow');
  await commandLeg("unpinMember leaves a pinned group", "c", "unpinMember", 'globalThis.tabMenuGroup = st().groupTabs(["b","c"], {pinned:true})', '!Object.values(s.groups).some((g) => g.pinned && g.tabIds.includes("c")) && !s.tabs.c.pinned');
  await commandLeg("newGroup creates a group with the tab", "a", "newGroup", null, 'Object.values(s.groups).some((g) => g.tabIds.includes("a"))');
  const groupId = await run('const id = st().groupTabs(["b","c"], {pinned:false}); return settle(300).then(() => id);');
  await commandLeg("group moves a tab into an existing group", "a", `group:${groupId}`, null, `s.groups[${JSON.stringify(groupId)}].tabIds.includes("a")`);
  await commandLeg("ungroupTab removes one member", "c", "ungroupTab", null, '!Object.values(s.groups).some((g) => g.tabIds.includes("c"))');
  await commandLeg("profile moves and shows the destination profile", "a", "profile:work", null, 's.tabs.a.profileId === "work" && s.windows.w1.profileId === "work" && s.windows.w1.activeTabIds.work === "a"');
  await commandLeg("window moves and activates in an existing window", "a", "window:w2", null, 's.tabs.a.windowId === "w2" && s.windows.w2.activeTabIds.default === "a" && s.ui.focusedWindowId === "w2"');
  await commandLeg("window:new creates a window containing the tab", "a", "window:new", null, 's.tabs.a.windowId !== "w1" && s.tabs.a.windowId !== "w2" && s.windows[s.tabs.a.windowId].activeTabIds.default === "a" && s.ui.focusedWindowId === s.tabs.a.windowId');
  for (const id of ["media", "split"]) for (const target of ["window:w2", "profile:work"]) await mediaLeg(id, target);
  await rep.check("the top strip opens the same native menu", async () => {
    await run('st().updateSettings({tabLayout:"top"}); return settle(1000);');
    const items = await run('return expo.modules.SolaraTopStrip.items("w1").then(JSON.parse).then((s) => s.items);');
    const tab = items.find((item) => item.kind === "tab" && item.id === "a");
    assert.ok(tab?.width > 0, JSON.stringify(items));
    const before = await capture();
    const expected = await shape();
    const count = await run('return D.devTabMenus();');
    await run('return M.devContextMenu("arm", "pin");');
    await run(`const f = st().windows.w1.frame; return Promise.resolve(expo.modules.SolaraCEF.chromeWindows()).then((windows) => { const native = windows.filter((w) => w.hasRoot).find((w) => { const r=w.frame.match(/[-\\d.]+/g).map(Number); return Math.abs(r[0]-f[0])<2 && Math.abs(r[2]-f[2])<2; }); return expo.modules.SolaraCEF.devWindow(native.window, "click:${Math.round(tab.windowX + Math.min(40, tab.width / 2))},20,right"); });`);
    await until("top strip native menu", () => run('return D.devTabMenus();'), (got) => got === count + 1);
    await until("strip Pin store result", () => run('return st().tabs.a.pinned;'));
    await reverse(before, expected);
  });
} finally {
  await app?.quit();
  await new Promise((done) => server.close(done));
}
const passed = rep.summary();
if (passed && !keep) rmSync(join(scratch, "data"), { recursive: true, force: true });
console.log(`artifacts: ${scratch}`);
process.exit(passed ? 0 : 1);
