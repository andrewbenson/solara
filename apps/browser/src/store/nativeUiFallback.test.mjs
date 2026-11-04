import assert from "node:assert/strict";
import { test } from "node:test";

const sent = [];
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: true, scope: "settingsAndDownloads" }),
    snapshot: () => JSON.stringify({ rev: 0, data: { settings: { chosen: [], inferred: [] }, downloads: [] } }),
    dispatch: (json) => {
      sent.push(...[JSON.parse(json)].flat());
      return JSON.stringify({ rev: 0, patches: [] });
    },
    catchUp: (rev) => JSON.stringify({ rev, patches: [] }),
    addListener: () => ({ remove() {} }),
  },
};
const { useBrowser } = await import("./browser.ts");
const { startPersistence } = await import("../lib/persist.ts");
const { writeState } = await import("./nativeStore.ts");
const S = () => useBrowser.getState();
startPersistence();

test("settingsAndDownloads keeps JS appearance and find reducers and pruning", () => {
  const windowId = S().createWindow();
  const tabId = S().windows[windowId].tabIds[0];
  sent.length = 0;
  S().setAppDark(false);
  assert.equal(S().ui.appDark, false);
  S().setFind(tabId, { open: true, query: "fallback" });
  S().setFind(tabId, { count: 2, active: 1 });
  assert.deepEqual(S().find[tabId], { open: true, query: "fallback", count: 2, active: 1 });
  S().setFind("missing", { open: true });
  assert.equal(S().find.missing, undefined);
  writeState(useBrowser, { ui: { ...S().ui, appDark: true } });
  assert.equal(S().ui.appDark, true);
  assert.ok(!sent.some((c) => ["setFind", "setAppDark"].includes(c.name)));
  S().closeTab(tabId);
  assert.equal(S().find[tabId], undefined);
});

test("settingsAndDownloads keeps JS selection, anchors, clicks and window UI reducers and pruning", () => {
  const windowId = S().createWindow();
  const first = S().windows[windowId].tabIds[0];
  const second = S().newTab(windowId);
  const third = S().newTab(windowId);
  sent.length = 0;
  S().clickTab(windowId, first);
  S().clickTab(windowId, third, { shiftKey: true });
  assert.deepEqual(S().selection[windowId], [first, second, third]);
  assert.equal(S().selectionAnchors[windowId], first);
  S().setSelectionAnchor(windowId, second);
  assert.equal(S().selectionAnchors[windowId], second);
  S().openPanel(windowId, "typed");
  assert.deepEqual(S().windowUi[windowId].panel, { open: true, initialText: "typed" });
  S().closePanel(windowId);
  S().setDownloadsOpen(windowId, true);
  assert.deepEqual(S().windowUi[windowId], { panel: { open: false, initialText: "" }, downloadsOpen: true });
  assert.ok(!sent.some((c) => ["setSelection", "setSelectionAnchor", "clickTab", "openPanel", "closePanel", "setDownloadsOpen"].includes(c.name)));
  S().closeTab(second);
  assert.deepEqual(S().selection[windowId], [first, third]);
  S().closeWindow(windowId);
  assert.equal(S().windowUi[windowId], undefined);
});

test("settingsAndDownloads scopes sidebar writes locally and Settings clears the local overrides", () => {
  const w1 = S().createWindow();
  const w2 = S().createWindow();
  sent.length = 0;
  const oldWidth = S().settings.sidebarWidth;
  S().setWindowSidebar(w1, { sidebarWidth: 280, sidebarIconsOnly: true, sidePanelWidth: 450 });
  assert.equal(S().windows[w1].sidebarWidth, 280);
  assert.equal(S().windows[w2].sidebarWidth, oldWidth);
  assert.equal(S().windows[w1].sidebarIconsOnly, true);
  assert.equal(S().windows[w2].sidebarIconsOnly, false);
  assert.ok(sent.some((c) => c.name === "applyState" && c.args[0].settings.sidebarWidth === 280));
  S().updateSettings({ sidebarIconsOnly: false }, { fromSync: true });
  assert.equal(S().windows[w1].sidebarIconsOnly, true);
  S().updateSettings({ sidebarIconsOnly: true });
  assert.equal(Object.hasOwn(S().windows[w1], "sidebarIconsOnly"), false);
  assert.equal(Object.hasOwn(S().windows[w2], "sidebarIconsOnly"), false);
});
