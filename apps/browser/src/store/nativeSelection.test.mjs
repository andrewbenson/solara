import assert from "node:assert/strict";
import { test } from "node:test";

const tab = { id: "t1", windowId: "w1", profileId: "default", url: "https://example.com", title: "Example", favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, pinnedUrl: null, openerId: null, createdAt: 1, lastActiveAt: 1 };
const win = { id: "w1", profileId: "default", incognito: false, tabIds: ["t1", "t2", "t3"], activeTabIds: { default: "t1" }, sidebarOpen: true, frame: null, createdAt: 1 };
const panelOpen = { panel: { open: true, initialText: "typed" }, downloadsOpen: false };
let rev = 0;
let reply = [];
let effects = [];
const sent = [];
const listeners = new Set();
const snapshot = (extra = {}) => ({ profiles: { default: { id: "default", name: "Personal", color: "plum", icon: null, createdAt: 0 } }, profileOrder: ["default"], windows: { w1: win, w2: { ...win, id: "w2", tabIds: [] } }, windowOrder: ["w1", "w2"], tabs: { t1: tab, t2: { ...tab, id: "t2" }, t3: { ...tab, id: "t3" } }, groups: {}, splits: {}, peeks: {}, closedTabs: [], closedWindows: [], closedGroups: [], deletedGroups: [], cleanedTabs: [], privateCleanedTabs: {}, privateSiteMutes: {}, parkedPins: {}, pinChoices: {}, pinSync: {}, downloads: [], settings: { chosen: [], inferred: [] }, ui: { focusedWindowId: "w1", focusOrder: ["w1"], lastProfileId: null, appDark: true }, find: {}, selection: {}, selectionAnchors: {}, windowUi: {}, ...extra });
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: true, scope: "everything" }),
    snapshot: () => JSON.stringify({ rev, data: snapshot() }),
    dispatch(json) {
      sent.push(...[JSON.parse(json)].flat());
      const patches = reply.map((patch) => ({ rev: ++rev, ...patch }));
      const response = { rev, patches, effects };
      reply = [];
      effects = [];
      return JSON.stringify(response);
    },
    catchUp: () => JSON.stringify({ rev, patches: [] }),
    flush: () => true,
    addListener: (_event, listener) => {
      listeners.add(listener);
      return { remove: () => listeners.delete(listener) };
    },
  },
};
const { useBrowser } = await import("./browser.ts");
const { startPersistence } = await import("../lib/persist.ts");
const { writeState } = await import("./nativeStore.ts");
const { workspaceFromPatch, workspaceFromSnapshot } = await import("./nativeWorkspace.ts");
const { runFocusMove } = await import("../lib/focusClaims.ts");
const S = () => useBrowser.getState();
startPersistence();
const foreign = (patch, commitEffects = []) => {
  const entry = { rev: ++rev, ...patch };
  for (const listener of listeners) listener({ event: JSON.stringify({ rev, patch: entry, effects: commitEffects }) });
};
const quietly = (run) => {
  const warn = console.warn;
  console.warn = () => {};
  try {
    return run();
  } finally {
    console.warn = warn;
  }
};

test("selection, anchor, click and window UI actions are Swift commands that change nothing locally", () => {
  const before = S();
  sent.length = 0;
  S().setSelection("w1", ["t1", "t2"]);
  S().setSelectionAnchor("w1", "t2");
  S().clickTab("w1", "t3", { shiftKey: true });
  S().openPanel("w1", "typed", { kind: "tab" });
  S().closePanel("w1");
  S().setDownloadsOpen("w1", true);
  assert.deepEqual(sent, [
    { name: "setSelection", args: ["w1", ["t1", "t2"]] },
    { name: "setSelectionAnchor", args: ["w1", "t2"] },
    { name: "clickTab", args: ["w1", "t3", { shiftKey: true }] },
    { name: "openPanel", args: ["w1", "typed", { kind: "tab" }] },
    { name: "closePanel", args: ["w1"] },
    { name: "setDownloadsOpen", args: ["w1", true] },
  ]);
  for (const key of ["selection", "selectionAnchors", "windowUi"]) assert.equal(S()[key], before[key]);
});

test("openPanel claims the command bar's focus for the running focus move before dispatching", () => {
  sent.length = 0;
  assert.equal(runFocusMove(1, "w1", "shortcut", () => S().openPanel("w1", "")), true);
  assert.equal(runFocusMove(2, "w1", "shortcut", () => S().closePanel("w1")), false);
  assert.deepEqual(sent.map((c) => c.name), ["openPanel", "closePanel"]);
});

test("patches install Swift's selection, anchors and window UI and keep untouched entries", () => {
  reply = [{ selection: { upsert: [{ windowId: "w1", ids: ["t1", "t2"] }, { windowId: "w2", ids: ["t3"] }], remove: [] }, selectionAnchors: { upsert: [{ windowId: "w1", tabId: "t2" }], remove: [] }, windowUi: { upsert: [{ windowId: "w1", state: panelOpen }], remove: [] } }];
  S().clickTab("w1", "t2", { metaKey: true });
  assert.deepEqual(S().selection, { w1: ["t1", "t2"], w2: ["t3"] });
  assert.deepEqual(S().selectionAnchors, { w1: "t2" });
  assert.deepEqual(S().windowUi.w1, panelOpen);
  const w2 = S().selection.w2;
  const anchors = S().selectionAnchors;
  foreign({ selection: { upsert: [], remove: ["w1"] }, windowUi: { upsert: [{ windowId: "w1", state: { ...panelOpen, downloadsOpen: true } }], remove: [] } });
  assert.deepEqual(Object.keys(S().selection), ["w2"]);
  assert.equal(S().selection.w2, w2);
  assert.equal(S().selectionAnchors, anchors);
  assert.equal(S().windowUi.w1.downloadsOpen, true);
});

test("Swift effects no longer drive window UI or selection; a swap only copies the page's live state", () => {
  foreign({ selection: { upsert: [{ windowId: "w1", ids: ["t1", "t3"] }], remove: [] }, windowUi: { upsert: [{ windowId: "w1", state: panelOpen }], remove: [] } });
  S().updateLive("t1", { isLoading: true });
  const before = S();
  foreign({}, [{ type: "closePanel", windowId: "w1" }, { type: "clearSelection", windowId: "w1" }, { type: "openDownloads", windowId: "w1" }, { type: "swapTabs", a: "t1", b: "t2" }]);
  assert.equal(S().windowUi, before.windowUi);
  assert.equal(S().selection, before.selection);
  assert.equal(S().live.t2.isLoading, true);
});

test("closing tabs or windows leaves selection and window UI pruning to Swift's patch", () => {
  const s = { ...S(), selection: { w1: ["t1"], w2: ["t3"] }, windowUi: { w2: panelOpen } };
  const next = workspaceFromPatch(s, { rev, tabs: { upsert: [], remove: ["t1"] }, windows: { upsert: [], remove: ["w2"] } });
  assert.equal(next.selection, undefined);
  assert.equal(next.windowUi, undefined);
});

test("snapshots take selection, anchors and window UI from Swift and reuse equal entries", () => {
  foreign({ selection: { upsert: [{ windowId: "w1", ids: ["t1", "t2"] }], remove: [] }, windowUi: { upsert: [{ windowId: "w1", state: panelOpen }], remove: [] } });
  const before = S();
  const same = workspaceFromSnapshot(before, snapshot(JSON.parse(JSON.stringify({ selection: before.selection, selectionAnchors: before.selectionAnchors, windowUi: before.windowUi }))), { keepLocal: true });
  for (const key of ["selection", "selectionAnchors", "windowUi"]) assert.equal(same[key], before[key]);
  const changed = workspaceFromSnapshot(before, snapshot({ selection: { w1: ["t1", "t2"], w2: ["t2"] }, selectionAnchors: { w2: "t2" } }), { keepLocal: true });
  assert.equal(changed.selection.w1, before.selection.w1);
  assert.deepEqual(changed.selection.w2, ["t2"]);
  assert.deepEqual(changed.selectionAnchors, { w2: "t2" });
  assert.deepEqual(changed.windowUi, {});
});

test("writeState and Release guarded sets never send or install selection, anchors or window UI", () => {
  const before = S();
  sent.length = 0;
  const stale = { selection: { w1: ["t3"] }, selectionAnchors: { w1: "t3" }, windowUi: { w1: { panel: { open: false, initialText: "" }, downloadsOpen: true } } };
  writeState(useBrowser, stale);
  quietly(() => useBrowser.setState(stale));
  for (const key of Object.keys(stale)) assert.equal(S()[key], before[key]);
  assert.deepEqual(sent, []);
});

test("Debug refuses a direct selection, anchor or window UI write before publication", () => {
  const held = globalThis.__DEV__;
  globalThis.__DEV__ = true;
  const before = S();
  sent.length = 0;
  try {
    for (const update of [{ selection: { ...before.selection, w2: ["debug"] } }, { selectionAnchors: { ...before.selectionAnchors, w2: "debug" } }, { windowUi: { ...before.windowUi, w2: { ...panelOpen, downloadsOpen: "debug" } } }]) {
      assert.throws(() => useBrowser.setState(update), /outside the native store's applier/);
      assert.equal(S(), before);
    }
    assert.deepEqual(sent, []);
  } finally {
    globalThis.__DEV__ = held;
  }
});

test("hydrate keeps the selection and window UI that Swift's hydrate patch leaves", () => {
  foreign({ selection: { upsert: [{ windowId: "w1", ids: ["t1", "t2"] }], remove: [] }, windowUi: { upsert: [{ windowId: "w1", state: panelOpen }], remove: [] } });
  reply = [{ selection: { upsert: [], remove: Object.keys(S().selection) }, selectionAnchors: { upsert: [], remove: Object.keys(S().selectionAnchors) }, windowUi: { upsert: [], remove: Object.keys(S().windowUi) } }];
  const data = snapshot();
  S().hydrate({ ...data, windows: Object.values(data.windows), tabs: Object.values(data.tabs) });
  for (const key of ["selection", "selectionAnchors", "windowUi"]) assert.deepEqual(S()[key], {});
});
