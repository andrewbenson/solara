import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { launch, session, sleep } from "../../../scripts/lib/instance.mjs";

const [appArg, outputArg] = process.argv.slice(2);
assert.ok(appArg && outputArg, "usage: node apps/browser/scripts/native-tab-commands-test.mjs <Debug app> <fresh output directory>");
const appPath = resolve(appArg);
const output = resolve(outputArg);
assert.equal(execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print CFBundleIdentifier", join(appPath, "Contents/Info.plist")], { encoding: "utf8", timeout: 5000 }).trim(), "network.benson.solara.dev");
mkdirSync(output, { recursive: true });
const evidence = [];
const server = createServer((request, response) => {
  response.writeHead(200, { "Content-Type": "text/html", "Connection": "close" });
  response.end("<!doctype html><title>Native command Peek</title><p>peek</p>");
});
let app;
let handlerBaseline;
const run = (body) => app.eval(body, { timeout: 2000 });
const nativeState = () => run(`
  const module = expo.modules.SolaraStoreAdapter;
  const status = module.status();
  if (!status.active || status.frozen !== false) throw new Error("native workspace ownership required");
  const snapshot = JSON.parse(module.snapshot());
  if (!Number.isSafeInteger(snapshot.rev)) throw new Error("native revision unavailable");
  return snapshot;
`);
const active = (state, id = "w1") => {
  const window = state.windows[id];
  return window?.activeTabIds[window.profileId];
};
const selected = (snapshot, id = "w1") => snapshot.windows.find((window) => window.id === id)?.selectedTabId;
const urlCount = (state, url) => state.windows.w1.tabIds.filter((id) => state.tabs[id]?.url === url).length;
async function until(label, accept, ms = 12000) {
  const deadline = Date.now() + ms;
  let last;
  while (Date.now() + 1000 < deadline) {
    assert.ok(app.alive, `${label}: owned instance exited`);
    const snapshot = await nativeState();
    last = snapshot.data;
    if (await accept(last)) return last;
    await sleep(50);
  }
  evidence.push({ label, failed: true, state: last });
  writeFileSync(join(output, "evidence.json"), JSON.stringify(evidence, null, 2));
  throw new Error(`${label}: deadline exceeded; native state ${JSON.stringify(last)}`);
}
async function capture(label, details = {}) {
  const state = await nativeState();
  const native = await app.snapshot({}, { timeout: 2000 });
  assert.equal(native.consistent, true, `${label}: inconsistent native snapshot`);
  const windowIds = await run("return ac.shell.windowIds();");
  const stats = await run("return ac.commandHandlers.stats();");
  assert.equal(stats.enabled, false, `${label}: JS handlers unexpectedly enabled`);
  assert.equal(stats.calls, handlerBaseline.calls, `${label}: JS handler made a decision`);
  assert.equal(stats.blocked, handlerBaseline.blocked, `${label}: command fell through to disabled JS`);
  const entry = { label, ...state, native, windowIds, handlerBaseline, stats, ...details };
  evidence.push(entry);
  writeFileSync(join(output, "evidence.json"), JSON.stringify(evidence, null, 2));
  console.log(`PASS ${label}`);
  return entry;
}
async function renderedSelection(label, tabId, windowId = "w1") {
  const deadline = Date.now() + 12000;
  let last;
  while (Date.now() + 2000 < deadline) {
    assert.ok(app.alive, `${label}: owned instance exited`);
    last = await app.snapshot({ windowId }, { timeout: 2000 });
    if (last.consistent && selected(last, windowId) === tabId) return last;
    await sleep(50);
  }
  throw new Error(`${label}: rendered native selection did not become ${tabId}; ${JSON.stringify(last)}`);
}
const heroState = (tabId) => run(`
  const fiber = acPerf.findFibers("NativeNewTabHero", 50).find(fiber => fiber.memoizedProps?.windowId === "w1" && fiber.memoizedProps?.tabId === ${JSON.stringify(tabId)});
  for (let hook = fiber?.memoizedState; hook; hook = hook.next) {
    const ref = hook.memoizedState?.current;
    if (ref && typeof ref.driverState === "function") return ref.driverState().then(JSON.parse);
  }
  return null;
`);
async function focusedHero(tabId, text) {
  const deadline = Date.now() + 12000;
  let last;
  while (Date.now() + 3000 < deadline) {
    assert.ok(app.alive, "New Tab focus: owned instance exited");
    const hero = await heroState(tabId);
    const native = await app.snapshot({ windowId: "w1" }, { timeout: 1000 });
    const window = native.windows.find((window) => window.id === "w1");
    last = { hero, native };
    if (native.consistent && window?.selectedTabId === tabId && /NSTextView|NSTextField|FieldEditor|TextField/.test(window.firstResponder ?? "")
      && hero?.windowId === "w1" && hero.tabId === tabId && hero.variant === "hero" && hero.mounted && hero.fieldAttached && hero.focused
      && hero.typed === text && hero.fieldValue === text) return last;
    await sleep(50);
  }
  evidence.push({ label: "New Tab hero focus", failed: true, tabId, expectedText: text, ...last });
  writeFileSync(join(output, "evidence.json"), JSON.stringify(evidence, null, 2));
  throw new Error(`New Tab hero did not receive native command focus and text ${JSON.stringify(text)}: ${JSON.stringify(last)}`);
}
async function focusedPanel(label, text = "") {
  let native;
  try {
    await until(label, async () => {
      native = await app.snapshot({ windowId: "w1" }, { timeout: 1000 });
      const bar = native.windows.find((window) => window.id === "w1")?.omnibox;
      return native.consistent && bar?.source === "panel" && bar.open && bar.focused
        && bar.typed === text && Array.isArray(bar.rows) && bar.rows.length > 0;
    });
  } catch (error) {
    evidence.push({ label, failed: true, expectedText: text, native, error: String(error) });
    writeFileSync(join(output, "evidence.json"), JSON.stringify(evidence, null, 2));
    const diagnostics = await run(`
      const state = ac.store.getState();
      const window = state.windows.w1;
      const tabId = window?.activeTabIds[window.profileId];
      return {
        panel: state.windowUi.w1?.panel,
        keyTrace: await expo.modules.SolaraApp.devKeyEquivalentTrace(),
        focusTrace: await expo.modules.SolaraApp.devFocusHandoffTrace(),
        hero: ac.omnibox.get("w1:hero")?.state() ?? null,
        panelDriver: ac.omnibox.get("w1:panel")?.state() ?? null,
        cardAnchor: globalThis.acLayout?.cardAnchors.getState().w1 ?? null,
        tabId,
      };
    `).catch((failure) => ({ error: String(failure) }));
    evidence[evidence.length - 1].diagnostics = diagnostics;
    writeFileSync(join(output, "evidence.json"), JSON.stringify(evidence, null, 2));
    throw new Error(`${label}: ${error.message}; last native snapshot ${JSON.stringify(native)}`, { cause: error });
  }
  return native;
}
async function press(windowId, key, keyCode, modifiers = ["command"], options = {}) {
  const result = await run(`return ac.shell.devKeyEquivalent(${JSON.stringify(windowId)}, ${JSON.stringify({ key, keyCode, modifiers, focus: "window", asKey: true, wait: 30, ...options })});`);
  assert.equal(result.error, undefined, JSON.stringify(result));
  assert.notEqual(result.handledBy, "none", `${key}: shortcut was not handled`);
  return result;
}
async function menu(windowId, command, arg = null) {
  await run(`return expo.modules.SolaraApp.devWorkspaceMenuCommand(${JSON.stringify(windowId)}, ${JSON.stringify(command)}, ${JSON.stringify(arg)});`);
}
async function setup(body) {
  await run(`${body}; return true;`);
}
async function windowAppeared(label, before, trigger) {
  await trigger();
  const state = await until(label, (state) => state.windowOrder.some((id) => !before.includes(id)));
  const id = state.windowOrder.find((id) => !before.includes(id));
  await until(`${label}: NSWindow`, async () => (await run("return ac.shell.windowIds();")).includes(id));
  return id;
}
async function closeWindow(windowId, keyboard = false) {
  if (keyboard) await press(windowId, "w", 13, ["command", "shift"]);
  else await menu(windowId, "closeWindow");
  await until(`${windowId}: store and NSWindow closed`, async (state) => !state.windows[windowId] && !(await run("return ac.shell.windowIds();")).includes(windowId));
}

try {
  await new Promise((done, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", done);
  });
  const peekURL = `http://127.0.0.1:${server.address().port}/peek`;
  app = await launch(appPath, {
    data: join(output, "data"), fresh: true, onboarded: true, probe: true, keepData: true,
    env: { SOLARA_NATIVE_WINDOW_LAYOUT: "1" },
    session: session({
      profiles: ["Personal", "Work"],
      windows: [
        { id: "w1", frame: [80, 80, 1100, 800], activeTabIds: { default: "a" } },
        { id: "w2", frame: [140, 100, 900, 700], activeTabIds: { default: "z" } },
      ],
      tabs: ["a", "b", "c", "d"].map((id) => ({ id, url: `about:blank#${id}`, title: id.toUpperCase() })).concat([{ id: "z", windowId: "w2", url: "about:blank#z", title: "Z" }]),
      settings: { warnBeforeClosingWindow: false, warnBeforeClosingLastTab: false, warnBeforeMovingTabsToProfile: false, sleepInactiveTabs: false, newTabOpens: "page", newTabPosition: "bottom", shareTabsAcrossWindows: false },
    }),
    ready: "return !!ac.commandHandlers && !!ac.shell.devKeyEquivalent && !!ac.shell.devTypeKeys && !!globalThis.acPerf && !!expo.modules.SolaraApp.devWorkspaceMenuCommand && !!ac.store.getState().windows.w2;",
  });
  handlerBaseline = await run("const baseline = ac.commandHandlers.stats(); ac.commandHandlers.setEnabled(false); return baseline;");
  await until("fixture NSWindows materialized", async () => {
    const ids = await run("return ac.shell.windowIds();");
    return ids.includes("w1") && ids.includes("w2");
  });
  await capture("JS command handlers disabled; native workspace required");

  const pageValue = async (expression) => {
    const page = await app.page((target) => target.url === "about:blank#a");
    try { return await page.eval(expression); } finally { page.close(); }
  };
  const keyPress = (key, keyCode, after = 0) => ({ key, keyCode, modifiers: ["command"], after });
  const postKeys = (presses) => run(`return expo.modules.SolaraApp.devPostKeys("w1", ${JSON.stringify(presses)});`);
  await run('return ac.shell.focusWindow("w1");');
  await pageValue(`
    document.body.innerHTML = '<textarea id="native-command-paste" style="position:fixed;inset:20px;width:400px;height:200px"></textarea>';
    window.nativeCommandPastes = 0;
    addEventListener('paste', () => window.nativeCommandPastes++, true);
    document.querySelector('textarea').focus();
    true;
  `);
  const initial = (await nativeState()).data.windows.w1.tabIds;
  const newTabPress = await press("w1", "t", 17, ["command"], { focus: "page" });
  assert.match(newTabPress.firstResponder, /RenderWidgetHostViewCocoa|SolaraCoreWebView/, "Command T starts with the existing page focused");
  let state = await until("Command T creates through store newTab", (state) => state.windows.w1.tabIds.some((id) => !initial.includes(id)));
  const freshTab = state.windows.w1.tabIds.find((id) => !initial.includes(id));
  assert.equal(active(state), freshTab);
  assert.deepEqual(state.windows.w2.tabIds, ["z"]);
  await renderedSelection("Command T", freshTab);
  await capture("Command T creates and selects native tab");
  const focused = await focusedHero(freshTab, "");
  await run('return ac.shell.devTypeKeys("w1", "native command focus", 5);');
  const typed = await focusedHero(freshTab, "native command focus");
  await capture("Command T transfers page focus to native hero and accepts typing", { focusedHero: focused, typedHero: typed });

  const checkPastes = async (label, expected) => {
    let field;
    await until(label, async () => {
      field = await pageValue(`({ count: window.nativeCommandPastes, value: document.querySelector('textarea').value })`);
      return field.count >= expected;
    });
    assert.deepEqual(field, { count: expected, value: "native-paste".repeat(expected) }, label);
    const native = await renderedSelection(label, "a");
    assert.match(native.windows.find((window) => window.id === "w1")?.firstResponder ?? "", /RenderWidgetHostViewCocoa/, label);
    await capture(label, { field });
  };
  await run('globalThis.nativeModuleProxy.Clipboard.setString("native-paste"); return true;');
  await postKeys([keyPress("w", 13), keyPress("v", 9, 30)]);
  await until("Command W closes native hero", (state) => !state.tabs[freshTab] && active(state) === "a");
  await checkPastes("Native hero close restores the page before the first paste", 1);
  await postKeys([keyPress("v", 9)]);
  await checkPastes("Native hero close allows the next paste exactly once", 2);
  await pageValue(`window.nativeCommandPastes = 0; document.querySelector('textarea').value = ''; document.querySelector('textarea').focus(); true;`);
  await postKeys([keyPress("t", 17), keyPress("w", 13), keyPress("v", 9, 30)]);
  await until("Rapid native New Tab close restores original tabs", (state) => active(state) === "a" && JSON.stringify(state.windows.w1.tabIds) === JSON.stringify(initial));
  await checkPastes("Rapid native Command T Command W preserves the first paste", 1);
  await postKeys([keyPress("v", 9)]);
  await checkPastes("Rapid native Command T Command W preserves the next paste", 2);

  await setup('ac.store.getState().updateSettings({ newTabOpens: "commandBar", searchSuggestions: false })');
  await postKeys([keyPress("t", 17)]);
  state = await until("Command T opens the New Tab panel", (state) => state.windowUi.w1?.panel.newTab?.kind === "list");
  assert.deepEqual(state.windows.w1.tabIds, initial);
  assert.equal(active(state), "a");
  const pagePanel = await focusedPanel("Command T panel owns focus and initial rows");
  await run('return ac.shell.devTypeKeys("w1", "native panel focus", 5);');
  const typedPanel = await focusedPanel("Command T panel accepts typing", "native panel focus");
  await capture("Command T opens a focused native panel over a page without creating a tab", { pagePanel, typedPanel });
  await postKeys([keyPress("t", 17), keyPress("v", 9, 30)]);
  state = await until("Command T toggles the New Tab panel closed", (state) => !state.windowUi.w1?.panel.open);
  assert.deepEqual(state.windows.w1.tabIds, initial);
  await checkPastes("Command T panel dismissal restores the page before the first paste", 3);
  await postKeys([keyPress("t", 17), { key: "x", keyCode: 7, modifiers: [], after: 0 }]);
  const immediatePanel = await focusedPanel("Command T panel receives the first immediate keystroke", "x");
  await capture("Native Command T panel preserves immediate typing", { immediatePanel });
  await press("w1", "t", 17);
  await until("Immediate typing panel closed", (state) => !state.windowUi.w1?.panel.open);

  await setup('ac.store.getState().updateSettings({ newTabOpens: "page" })');
  await press("w1", "t", 17);
  state = await until("Blank New Tab fixture", (state) => state.windows.w1.tabIds.some((id) => !initial.includes(id)));
  const emptyTab = active(state);
  await focusedHero(emptyTab, "");
  await setup('ac.store.getState().updateSettings({ newTabOpens: "commandBar" })');
  const emptyTabs = state.windows.w1.tabIds;
  state = await until("Command Bar setting presents the blank New Tab panel", (state) => state.windowUi.w1?.panel.open
    && state.windowUi.w1.panel.newTab?.kind === "into" && state.windowUi.w1.panel.newTab.tabId === emptyTab);
  assert.deepEqual(state.windows.w1.tabIds, emptyTabs);
  await focusedPanel("Command Bar setting panel owns focus and initial rows");
  await postKeys([keyPress("t", 17)]);
  state = await until("Automatic blank New Tab panel toggles closed", (state) => !state.windowUi.w1?.panel.open);
  assert.deepEqual(state.windows.w1.tabIds, emptyTabs);
  await capture("Command Bar setting opens once and Cmd-T dismisses the blank New Tab panel");
  await postKeys([keyPress("t", 17)]);
  state = await until("Command T targets the existing blank New Tab", (state) => state.windowUi.w1?.panel.newTab?.tabId === emptyTab);
  assert.equal(state.windowUi.w1.panel.newTab.kind, "into");
  assert.deepEqual(state.windows.w1.tabIds, emptyTabs);
  const emptyPanel = await focusedPanel("Blank New Tab Cmd-T panel owns focus and initial rows");
  await capture("Command T opens native panel rows over the existing blank New Tab", { emptyPanel });
  await press("w1", "t", 17);
  state = await until("Blank New Tab Cmd-T panel toggles closed", (state) => !state.windowUi.w1?.panel.open);
  assert.deepEqual(state.windows.w1.tabIds, emptyTabs);
  await setup('ac.store.getState().updateSettings({ newTabOpens: "page" })');
  await press("w1", "w", 13);
  await until("Blank New Tab fixture closed", (state) => !state.tabs[emptyTab] && active(state) === "a");

  await setup('ac.store.getState().activate("a")');
  const beforeDuplicate = Object.keys((await nativeState()).data.tabs);
  await menu("w1", "duplicateTab");
  state = await until("duplicate active tab", (state) => Object.keys(state.tabs).some((id) => !beforeDuplicate.includes(id)));
  const duplicate = Object.keys(state.tabs).find((id) => !beforeDuplicate.includes(id));
  assert.equal(state.tabs[duplicate].url, "about:blank#a");
  assert.equal(active(state), duplicate);
  await renderedSelection("Duplicate", duplicate);
  await capture("Duplicate uses native active tab");

  await press("w1", "1", 18);
  state = await until("Command 1", (state) => active(state) === state.windows.w1.tabIds[0]);
  await renderedSelection("Command 1", active(state));
  await capture("Command 1 selects first native row");
  await press("w1", "9", 25);
  state = await until("Command 9", (state) => active(state) === state.windows.w1.tabIds.at(-1));
  await renderedSelection("Command 9", active(state));
  assert.equal(selected((await capture("Command 9 selects last native row")).native), active(state));
  await setup('ac.store.getState().activate("b")');
  for (const [label, next, previous, modifiers] of [
    ["Shift Command bracket", ["}", 30], ["{", 33], ["command", "shift"]],
    ["Option Command arrow", ["\uF701", 125], ["\uF700", 126], ["command", "option", "function"]],
    ["Control Page", ["\uF72D", 121], ["\uF72C", 116], ["control", "function"]],
  ]) {
    const nextPress = await press("w1", ...next, modifiers, { focus: "page" });
    await until(`${label}: next tab`, (state) => active(state) === "c");
    await renderedSelection(`${label}: next tab`, "c");
    await capture(`${label}: next tab shortcut runs natively`, { press: nextPress });
    const previousPress = await press("w1", ...previous, modifiers, { focus: "page" });
    await until(`${label}: previous tab`, (state) => active(state) === "b");
    await renderedSelection(`${label}: previous tab`, "b");
    await capture(`${label}: previous tab shortcut runs natively`, { press: previousPress });
  }

  let beforeMove = (await nativeState()).data.windows.w1.tabIds;
  await menu("w1", "moveTabDown");
  await until("move tab down", (state) => state.windows.w1.tabIds.indexOf("b") === beforeMove.indexOf("b") + 1);
  await capture("Move tab down preserves native order");
  await menu("w1", "moveTabUp");
  await until("move tab up", (state) => JSON.stringify(state.windows.w1.tabIds) === JSON.stringify(beforeMove));
  await capture("Move tab up restores native order");

  await menu("w1", "moveTabToWindow", "w2");
  await until("move to existing window", (state) => state.tabs.b.windowId === "w2" && !state.windows.w1.tabIds.includes("b") && active(state, "w2") === "b");
  await capture("Move tab to existing window");
  await menu("w2", "moveTabToWindow", "w1");
  await until("move tab back", (state) => state.tabs.b.windowId === "w1");
  const beforeMoveWindow = (await nativeState()).data.windowOrder;
  const movedWindow = await windowAppeared("move tab to new window", beforeMoveWindow, () => menu("w1", "moveTabToWindow", "new"));
  await until("new move destination owns tab", (state) => state.tabs.b.windowId === movedWindow);
  await capture("Move tab creates a real native window");
  await menu(movedWindow, "moveTabToWindow", "w1");
  await until("move back from new window", (state) => state.tabs.b.windowId === "w1");
  await setup('ac.store.getState().activate("b")');
  await menu("w1", "moveTabToProfile", "work");
  await until("move profile", (state) => state.tabs.b.profileId === "work" && state.windows.w1.profileId === "work");
  await capture("Move tab to existing profile");
  await menu("w1", "moveTabToProfile", "default");
  await until("move profile back", (state) => state.tabs.b.profileId === "default" && state.windows.w1.profileId === "default");

  await setup('ac.store.getState().activate("a"); ac.store.getState().openPanel("w1", "typed")');
  const panelTabs = (await nativeState()).data.windows.w1.tabIds;
  await press("w1", "w", 13);
  state = await until("close panel first", (state) => !state.windowUi.w1?.panel.open);
  assert.deepEqual(state.windows.w1.tabIds, panelTabs);
  await capture("Command W dismisses panel before tab");
  await setup('ac.store.getState().openPanel("w1", "", { kind: "list" })');
  await until("New Tab panel fixture", (state) => !!state.windowUi.w1?.panel.newTab);
  await press("w1", "w", 13);
  state = await until("close New Tab panel first", (state) => !state.windowUi.w1?.panel.open);
  assert.deepEqual(state.windows.w1.tabIds, panelTabs);
  await capture("Command W dismisses New Tab panel without closing tab");
  const openedPeek = await run(`return ac.store.getState().openPeek("a", ${JSON.stringify(peekURL)});`);
  assert.ok(openedPeek, "HTTP Peek fixture must be accepted");
  state = await until("Peek fixture", (state) => state.peeks.w1?.tabId === openedPeek);
  assert.equal(state.tabs[openedPeek]?.url, peekURL);
  const peekTab = state.peeks.w1.tabId;
  await setup(`ac.store.getState().setFind(${JSON.stringify(peekTab)}, { open: true, query: "peek" })`);
  await press("w1", "w", 13);
  state = await until("close Peek find first", (state) => !state.find[peekTab]?.open);
  assert.equal(state.peeks.w1?.tabId, peekTab);
  assert.ok(state.tabs.a);
  await capture("Command W dismisses Peek find before Peek");
  await press("w1", "w", 13);
  state = await until("close Peek first", (state) => !state.peeks.w1);
  assert.ok(state.tabs.a);
  await capture("Command W dismisses Peek before source tab");

  await setup('ac.store.getState().activate("a"); ac.store.getState().setSelection("w1", ["c", "d"])');
  await press("w1", "w", 13);
  state = await until("close selected tabs", (state) => !state.tabs.c && !state.tabs.d);
  assert.ok(state.tabs.a);
  assert.equal(state.selection.w1?.length ?? 0, 0);
  await capture("Command W closes native multiselection");
  await press("w1", "t", 17, ["command", "shift"]);
  state = await until("restore selected tabs together", (state) => state.windows.w1.tabIds.filter((id) => ["about:blank#c", "about:blank#d"].includes(state.tabs[id]?.url)).length === 2);
  await capture("Shift Command T restores selected tabs together");
  await setup('ac.store.getState().activate("a")');
  state = (await nativeState()).data;
  const originalActive = active(state);
  const sourceURL = state.tabs[originalActive].url;
  const beforeCloseCount = urlCount(state, sourceURL);
  await press("w1", "w", 13);
  state = await until("close one tab", (state) => !state.tabs[originalActive] && urlCount(state, sourceURL) === beforeCloseCount - 1);
  const closed = state.closedTabs.at(-1);
  assert.equal(closed.tab.url, "about:blank#a");
  await press("w1", "t", 17, ["command", "shift"]);
  state = await until("reopen one tab", (state) => !state.closedTabs.some((entry) => entry.id === closed.id) && urlCount(state, sourceURL) === beforeCloseCount && active(state) !== duplicate && state.tabs[active(state)]?.url === sourceURL);
  const reopenedTab = active(state);
  await renderedSelection("Reopen one tab", reopenedTab);
  await capture("Shift Command T reopens one native tab");
  await press("w1", "w", 13);
  state = await until("close restored tab", (state) => !state.tabs[reopenedTab] && urlCount(state, sourceURL) === beforeCloseCount - 1);
  const specific = state.closedTabs.at(-1);
  await menu("w1", "restoreClosed", specific.id);
  state = await until("restore specific tab", (state) => !state.closedTabs.some((entry) => entry.id === specific.id) && urlCount(state, sourceURL) === beforeCloseCount && active(state) !== duplicate && state.tabs[active(state)]?.url === sourceURL);
  await renderedSelection("Restore specific tab", active(state));
  await capture("Close tab and restore specific native closed entry");

  const beforeWindow = (await nativeState()).data.windowOrder;
  const madeWindow = await windowAppeared("Command N", beforeWindow, () => press("w1", "n", 45));
  await capture("Command N materializes a distinct native window");
  await setup(`const s = ac.store.getState(); s.navigate(s.windows[${JSON.stringify(madeWindow)}].activeTabIds[s.windows[${JSON.stringify(madeWindow)}].profileId], "about:blank#new-window")`);
  await closeWindow(madeWindow, true);
  await capture("Shift Command W closes native window");
  const beforeReopen = (await nativeState()).data.windowOrder;
  const reopened = await windowAppeared("reopen closed window", beforeReopen, () => menu("w1", "reopenClosedWindow"));
  await capture("Reopen closed native window");
  await closeWindow(reopened);
  const beforeProfileWindow = (await nativeState()).data.windowOrder;
  const profileWindow = await windowAppeared("new window for profile", beforeProfileWindow, () => menu("w1", "newWindow", "work"));
  state = (await nativeState()).data;
  assert.equal(state.windows[profileWindow].profileId, "work");
  await capture("New window honors native profile argument");
  await closeWindow(profileWindow);
  const beforePrivate = (await nativeState()).data.windowOrder;
  const privateWindow = await windowAppeared("new private window", beforePrivate, () => menu("w1", "newIncognitoWindow"));
  state = (await nativeState()).data;
  assert.equal(state.windows[privateWindow].incognito, true);
  await capture("New private native window");
  await closeWindow(privateWindow);
  await capture("Close private native window");

  await menu("w1", "mergeAllWindows");
  await until("merge native windows", (state) => state.windowOrder.length === 1 && state.windows.w1.tabIds.some((id) => state.tabs[id].url === "about:blank#z"));
  await capture("Merge all windows through native command");
  writeFileSync(join(output, "result.json"), JSON.stringify({ passed: true, checks: evidence.map((entry) => entry.label) }, null, 2));
} finally {
  try {
    if (app) await app.quit();
  } finally {
    server.closeAllConnections();
    server.close();
  }
}
