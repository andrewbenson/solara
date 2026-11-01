import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";

globalThis.__DEV__ = true;

const tab = { id: "t1", windowId: "w1", profileId: "default", url: "https://a.example/", title: "A", favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, pinnedUrl: null, openerId: null, createdAt: 1, lastActiveAt: 1 };
const win = { id: "w1", profileId: "default", incognito: false, tabIds: ["t1"], activeTabIds: { default: "t1" }, sidebarOpen: true, frame: null, createdAt: 1 };
const workspace = () => ({ profiles: { default: { id: "default", name: "Personal", color: "plum", icon: null, createdAt: 0 } }, profileOrder: ["default"], windows: { w1: win }, windowOrder: ["w1"], tabs: { t1: tab }, groups: {}, splits: {}, peeks: {}, closedTabs: [], closedWindows: [], closedGroups: [], deletedGroups: [], cleanedTabs: [], parkedPins: {}, pinChoices: {}, pinSync: {}, downloads: [], settings: { chosen: [], inferred: [] }, find: {}, selection: {}, selectionAnchors: {}, windowUi: {}, ui: { focusedWindowId: "w1", focusOrder: ["w1"], lastProfileId: "default", appDark: false } });
let rev = 0;
let reply;
const sent = [];
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: true, scope: "everything" }),
    dispatch: (json) => {
      sent.push(...[JSON.parse(json)].flat());
      return JSON.stringify(reply ?? { rev, patches: [] });
    },
    addListener: () => ({ remove() {} }),
  },
};

const { useBrowser } = await import("./browser.ts");
const { attachReplica, nativeWrite, startNativeStore, withApplier, NativeStoreBusy } = await import("./nativeStore.ts");
const { workspaceFromSnapshot } = await import("./nativeWorkspace.ts");
const { clearNativeClosingLocals } = await import("./closingWindowRestore.ts");
const S = () => useBrowser.getState();
startNativeStore();
attachReplica(useBrowser);

beforeEach(() => {
  reply = undefined;
  withApplier(() => useBrowser.setState(workspaceFromSnapshot(S(), workspace())));
  clearNativeClosingLocals();
  sent.length = 0;
});

function close() {
  S().updateLive("t1", { playingAudio: true });
  withApplier(() => useBrowser.setState({ find: { t1: { open: true, query: "needle", count: null, active: 0 } } }));
  withApplier(() => useBrowser.setState({
    selection: { w1: ["t1"] },
    selectionAnchors: { w1: "t1" },
    windowUi: { w1: { panel: { open: true, initialText: "before close" }, downloadsOpen: true } },
  }));
  const before = S();
  const saved = { window: before.windows.w1, tabs: [before.tabs.t1], groups: [], splits: [] };
  reply = { rev: ++rev, patches: [{ rev, windows: { upsert: [], remove: ["w1"] }, tabs: { upsert: [], remove: ["t1"] }, find: { upsert: [], remove: ["t1"] }, selection: { upsert: [], remove: ["w1"] }, selectionAnchors: { upsert: [], remove: ["w1"] }, windowUi: { upsert: [], remove: ["w1"] }, windowOrder: [] }] };
  nativeWrite({ name: "closeWindow", args: ["w1"] });
  sent.length = 0;
  return { saved, before };
}

function restoreReply() {
  const data = workspace();
  data.windows = { returned: { ...win, id: "returned" } };
  data.windowOrder = ["returned"];
  data.tabs = { t1: { ...tab, windowId: "returned" } };
  data.find = { t1: { open: true, query: "native restore", count: 2, active: 1 } };
  data.selection = { returned: [] };
  data.selectionAnchors = {};
  data.windowUi = { returned: { panel: { open: true, initialText: "native restore" }, downloadsOpen: false } };
  data.ui = { focusedWindowId: "returned", focusOrder: ["returned"], lastProfileId: "default", appDark: true };
  return { rev: ++rev, result: "returned", snapshot: data };
}

test("native Stay restores only live state and preserves every Swift-owned restore result", () => {
  const { saved } = close();
  const forwards = globalThis.__nativeStoreForwards?.length ?? 0;
  reply = restoreReply();
  assert.equal(S().restoreClosingWindow(saved, "chrome-stay", ["t1"]), "returned");
  assert.deepEqual(sent, [{ name: "restoreClosingWindow", args: [saved, "chrome-stay", ["t1"]] }]);
  assert.equal(S().live.t1.playingAudio, true);
  assert.deepEqual(S().find.t1, { open: true, query: "native restore", count: 2, active: 1 });
  assert.deepEqual(S().ui, { focusedWindowId: "returned", focusOrder: ["returned"], lastProfileId: "default", appDark: true });
  assert.deepEqual(S().windowUi.returned, { panel: { open: true, initialText: "native restore" }, downloadsOpen: false });
  assert.deepEqual(S().selection.returned, []);
  assert.deepEqual(S().selectionAnchors, {});
  assert.equal(S().windowUi.w1, undefined);
  assert.equal(globalThis.__nativeStoreForwards?.length ?? 0, forwards);
  sent.length = 0;
  assert.equal(S().restoreClosingWindow(saved, "chrome-stay", ["t1"]), null);
  assert.deepEqual(sent, []);
});

test("native Stay refuses a conflicting local undo before writing native state", () => {
  const { saved } = close();
  useBrowser.setState({ live: { t1: { playingAudio: false } } });
  reply = restoreReply();
  const before = S();
  assert.equal(S().restoreClosingWindow(saved, "chrome-stay", ["t1"]), null);
  assert.deepEqual(sent, []);
  assert.equal(S(), before);
});

test("busy and refused native Stay do not remap locals or consume the undo", () => {
  const { saved } = close();
  const warn = console.warn;
  console.warn = () => {};
  try {
    reply = { rev, busy: true };
    const before = S();
    assert.throws(() => S().restoreClosingWindow(saved, "chrome-stay", ["t1"]), NativeStoreBusy);
    assert.equal(S(), before);
    reply = { rev, error: "refused" };
    assert.equal(S().restoreClosingWindow(saved, "chrome-stay", ["t1"]), null);
    assert.equal(S(), before);
    reply = restoreReply();
    assert.equal(S().restoreClosingWindow(saved, "chrome-stay", ["t1"]), "returned");
    assert.equal(S().live.t1.playingAudio, true);
  } finally {
    console.warn = warn;
  }
});

test("accepted native hydrate clears closing locals while refused hydrate preserves them", () => {
  for (const accepted of [false, true]) {
    reply = undefined;
    withApplier(() => useBrowser.setState(workspaceFromSnapshot(S(), workspace())));
    clearNativeClosingLocals();
    const { saved } = close();
    const warn = console.warn;
    console.warn = () => {};
    try {
      reply = accepted ? { rev, patches: [] } : { rev, error: "refused" };
      S().hydrate({});
    } finally {
      console.warn = warn;
    }
    reply = restoreReply();
    sent.length = 0;
    assert.equal(S().restoreClosingWindow(saved, "chrome-stay", ["t1"]), accepted ? null : "returned");
    assert.equal(sent.length, accepted ? 0 : 1);
  }
});
