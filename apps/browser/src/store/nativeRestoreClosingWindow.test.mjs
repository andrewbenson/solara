import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";

globalThis.__DEV__ = true;

const tab = { id: "t1", windowId: "w1", profileId: "default", url: "https://a.example/", title: "A", favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, pinnedUrl: null, openerId: null, createdAt: 1, lastActiveAt: 1 };
const win = { id: "w1", profileId: "default", incognito: false, tabIds: ["t1"], activeTabIds: { default: "t1" }, sidebarOpen: true, frame: null, createdAt: 1 };
const liveFacts = (patch = {}) => ({ isLoading: false, canGoBack: false, canGoForward: false, playingAudio: false, themeColor: null, discarded: false, ...patch });
const workspace = () => ({ live: { t1: liveFacts() }, profiles: { default: { id: "default", name: "Personal", color: "plum", icon: null, createdAt: 0 } }, profileOrder: ["default"], windows: { w1: win }, windowOrder: ["w1"], tabs: { t1: tab }, groups: {}, splits: {}, peeks: {}, closedTabs: [], closedWindows: [], closedGroups: [], deletedGroups: [], cleanedTabs: [], parkedPins: {}, pinChoices: {}, pinSync: {}, downloads: [], settings: { chosen: [], inferred: [] }, find: {}, selection: {}, selectionAnchors: {}, windowUi: {}, ui: { focusedWindowId: "w1", focusOrder: ["w1"], lastProfileId: "default", appDark: false } });
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
const S = () => useBrowser.getState();
startNativeStore();
attachReplica(useBrowser);

beforeEach(() => {
  reply = undefined;
  withApplier(() => useBrowser.setState(workspaceFromSnapshot(S(), workspace())));
  sent.length = 0;
});

function close() {
  reply = { rev: ++rev, patches: [{ rev, live: { upsert: [{ id: "t1", ...liveFacts({ playingAudio: true }) }], remove: [] } }] };
  nativeWrite({ name: "pageReport", args: ["t1", { type: "media", generation: "g", playing: true }] });
  withApplier(() => useBrowser.setState({ find: { t1: { open: true, query: "needle", count: null, active: 0 } } }));
  withApplier(() => useBrowser.setState({
    selection: { w1: ["t1"] },
    selectionAnchors: { w1: "t1" },
    windowUi: { w1: { panel: { open: true, initialText: "before close" }, downloadsOpen: true } },
  }));
  const before = S();
  const saved = { window: before.windows.w1, tabs: [before.tabs.t1], groups: [], splits: [] };
  reply = { rev: ++rev, patches: [{ rev, live: { upsert: [], remove: ["t1"] }, windows: { upsert: [], remove: ["w1"] }, tabs: { upsert: [], remove: ["t1"] }, find: { upsert: [], remove: ["t1"] }, selection: { upsert: [], remove: ["w1"] }, selectionAnchors: { upsert: [], remove: ["w1"] }, windowUi: { upsert: [], remove: ["w1"] }, windowOrder: [] }] };
  nativeWrite({ name: "closeWindow", args: ["w1"] });
  sent.length = 0;
  return { saved, before };
}

function restoreReply() {
  const data = workspace();
  data.windows = { returned: { ...win, id: "returned" } };
  data.windowOrder = ["returned"];
  data.tabs = { t1: { ...tab, windowId: "returned" } };
  data.live = { t1: liveFacts({ discarded: true, themeColor: "#123456" }) };
  data.find = { t1: { open: true, query: "native restore", count: 2, active: 1 } };
  data.selection = { returned: [] };
  data.selectionAnchors = {};
  data.windowUi = { returned: { panel: { open: true, initialText: "native restore" }, downloadsOpen: false } };
  data.ui = { focusedWindowId: "returned", focusOrder: ["returned"], lastProfileId: "default", appDark: true };
  return { rev: ++rev, result: "returned", snapshot: data };
}

test("native Stay applies authoritative live with every Swift-owned restore result", () => {
  const { saved } = close();
  const forwards = globalThis.__nativeStoreForwards?.length ?? 0;
  reply = restoreReply();
  assert.equal(S().restoreClosingWindow(saved, "chrome-stay", ["t1"]), "returned");
  assert.deepEqual(sent, [{ name: "restoreClosingWindow", args: [saved, "chrome-stay", ["t1"]] }]);
  assert.deepEqual(S().live.t1, liveFacts({ discarded: true, themeColor: "#123456" }));
  assert.deepEqual(S().find.t1, { open: true, query: "native restore", count: 2, active: 1 });
  assert.deepEqual(S().ui, { focusedWindowId: "returned", focusOrder: ["returned"], lastProfileId: "default", appDark: true });
  assert.deepEqual(S().windowUi.returned, { panel: { open: true, initialText: "native restore" }, downloadsOpen: false });
  assert.deepEqual(S().selection.returned, []);
  assert.deepEqual(S().selectionAnchors, {});
  assert.equal(S().windowUi.w1, undefined);
  assert.equal(globalThis.__nativeStoreForwards?.length ?? 0, forwards);
  const first = S().live;
  sent.length = 0;
  reply = { rev, error: "undo consumed" };
  const warn = console.warn;
  console.warn = () => {};
  try { assert.equal(S().restoreClosingWindow(saved, "chrome-stay", ["t1"]), null); }
  finally { console.warn = warn; }
  assert.equal(sent.length, 1);
  assert.equal(S().live, first);
});

test("native Stay requires no JS close observation or local undo", () => {
  const saved = { window: win, tabs: [tab], groups: [], splits: [] };
  withApplier(() => useBrowser.setState({ windows: {}, tabs: {}, live: {} }));
  reply = restoreReply();
  assert.equal(S().restoreClosingWindow(saved, "chrome-stay", ["t1"]), "returned");
  assert.deepEqual(S().live.t1, reply.snapshot.live.t1);
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
    assert.deepEqual(S().live.t1, liveFacts({ discarded: true, themeColor: "#123456" }));
  } finally {
    console.warn = warn;
  }
});

test("native refusal after hydrate is decided by Swift without a JS undo", () => {
  const { saved } = close();
  reply = { rev, patches: [] };
  S().hydrate({});
  const before = S();
  reply = { rev, error: "close undo reset" };
  const warn = console.warn;
  console.warn = () => {};
  try { assert.equal(S().restoreClosingWindow(saved, "chrome-stay", ["t1"]), null); }
  finally { console.warn = warn; }
  assert.equal(S(), before);
  assert.equal(sent.at(-1).name, "restoreClosingWindow");
});
