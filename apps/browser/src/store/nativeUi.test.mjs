import assert from "node:assert/strict";
import { test } from "node:test";

const tab = { id: "t1", windowId: "w1", profileId: "default", url: "https://example.com", title: "Example", favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, pinnedUrl: null, openerId: null, createdAt: 1, lastActiveAt: 1 };
const closed = { open: false, query: "", count: null, active: 0 };
let rev = 0;
let find = {};
let ui = { focusedWindowId: "w1", focusOrder: ["w1"], lastProfileId: null, appDark: false };
const sent = [];
const log = [];
const listeners = new Set();
const commit = (patch) => {
  const entry = { rev: ++rev, ...patch };
  log.push(entry);
  return entry;
};
const snapshot = () => ({ profiles: { default: { id: "default", name: "Personal", color: "plum", icon: null, createdAt: 0 } }, profileOrder: ["default"], windows: { w1: { id: "w1", profileId: "default", incognito: false, tabIds: ["t1", "t2"], activeTabIds: { default: "t1" }, sidebarOpen: true, frame: null, createdAt: 1 } }, windowOrder: ["w1"], tabs: { t1: tab, t2: { ...tab, id: "t2" } }, groups: {}, splits: {}, peeks: {}, closedTabs: [], closedWindows: [], closedGroups: [], deletedGroups: [], cleanedTabs: [], privateCleanedTabs: {}, privateSiteMutes: {}, parkedPins: {}, pinChoices: {}, pinSync: {}, downloads: [], settings: { chosen: [], inferred: [] }, ui, find });
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: true, scope: "everything" }),
    snapshot: () => JSON.stringify({ rev, data: snapshot() }),
    dispatch(json, sinceRev) {
      for (const command of [JSON.parse(json)].flat()) {
        sent.push(command);
        if (command.name === "hydrate") {
          const remove = Object.keys(find);
          find = {};
          commit({ find: { upsert: [], remove } });
        }
        if (command.name === "setFind" && snapshot().tabs[command.args[0]]) {
          const [id, patch] = command.args;
          const { $unset = [], ...values } = patch;
          const next = { ...(find[id] ?? closed), ...values };
          for (const key of $unset) delete next[key];
          find = { ...find, [id]: next };
          commit({ find: { upsert: [{ tabId: id, state: next }], remove: [] } });
        }
      }
      return JSON.stringify({ rev, patches: log.filter((p) => p.rev > sinceRev) });
    },
    catchUp: () => JSON.stringify({ rev, snapshot: snapshot() }),
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
const { PATCH_COMMANDS } = await import("@solara/store");
const { workspaceFromPatch, workspaceFromSnapshot } = await import("./nativeWorkspace.ts");
const S = () => useBrowser.getState();
startPersistence();
const foreign = (patch) => {
  const entry = commit(patch);
  for (const listener of listeners) listener({ event: JSON.stringify({ rev, patch: entry }) });
};

test("the resolved store package encodes setFind patches", () => {
  assert.equal(PATCH_COMMANDS.has("setFind"), true);
});

test("owned setFind round-trips synchronously and preserves other find entries", () => {
  sent.length = 0;
  S().setFind("t1", { open: true, query: "needle", replace: true, focusRequest: 10 });
  assert.deepEqual(sent, [{ name: "setFind", args: ["t1", { open: true, query: "needle", replace: true, focusRequest: 10 }] }]);
  assert.deepEqual(S().find.t1, { ...closed, open: true, query: "needle", replace: true, focusRequest: 10 });
  S().setFind("t2", { query: "other" });
  const other = S().find.t2;
  S().setFind("t1", { count: 4, active: 2 });
  assert.equal(S().find.t1.query, "needle");
  assert.equal(S().find.t1.count, 4);
  assert.equal(S().find.t1.active, 2);
  assert.equal(S().find.t2, other);
  S().setFind("t1", { focusRequest: undefined, replace: undefined });
  assert.equal(S().find.t1.focusRequest, undefined);
  assert.equal(S().find.t1.replace, undefined);
  assert.deepEqual(sent.at(-1).args[1], { $unset: ["focusRequest", "replace"] });
  S().setFind("missing", { open: true });
  assert.equal(S().find.missing, undefined);
});

test("appDark patches preserve unrelated ui fields and other slice identities", () => {
  assert.equal(S().ui.appDark, false);
  const before = S();
  ui = { ...ui, appDark: true };
  foreign({ ui });
  assert.equal(S().ui.appDark, true);
  assert.notEqual(S().ui, before.ui);
  assert.equal(S().ui.focusOrder, before.ui.focusOrder);
  for (const key of ["tabs", "windows", "find", "windowUi", "selection"]) assert.equal(S()[key], before[key]);
  const current = S().ui;
  foreign({ ui });
  assert.equal(S().ui, current);
});

test("owned JS appearance and writeState cannot replace native transient state", () => {
  const before = S();
  sent.length = 0;
  S().setAppDark(!before.ui.appDark);
  writeState(useBrowser, { ui: { ...S().ui, appDark: !before.ui.appDark }, find: {} });
  assert.equal(S().ui, before.ui);
  assert.equal(S().find, before.find);
  assert.deepEqual(sent, []);
});

test("the guard restores native transient values without forwarding them", () => {
  const warn = console.warn;
  console.warn = () => {};
  sent.length = 0;
  try {
    useBrowser.setState({ find: {}, ui: { ...S().ui, appDark: false } });
  } finally {
    console.warn = warn;
  }
  assert.equal(S().ui.appDark, ui.appDark);
  assert.deepEqual(S().find, find);
  assert.ok(!sent.some((c) => c.name === "applyState" && (c.args[0].find || "appDark" in (c.args[0].ui ?? {}))));
});

test("Debug refuses transient owned writes before dispatch or publication", () => {
  const held = globalThis.__DEV__;
  globalThis.__DEV__ = true;
  const before = S();
  sent.length = 0;
  let notifications = 0;
  const stop = useBrowser.subscribe(() => notifications++);
  try {
    for (const update of [{ find: {} }, { ui: { ...before.ui, appDark: !before.ui.appDark } }]) {
      assert.throws(() => useBrowser.setState(update), /outside the native store's applier/);
      assert.equal(S(), before);
    }
    assert.deepEqual(sent, []);
    assert.equal(notifications, 0);
  } finally {
    stop();
    globalThis.__DEV__ = held;
  }
});

test("snapshots use native find with keepLocal and reuse equal records", () => {
  const next = workspaceFromSnapshot(S(), snapshot(), { keepLocal: true });
  assert.equal(next.find, S().find);
  assert.equal(next.ui, S().ui);
  const changed = workspaceFromSnapshot(S(), { ...snapshot(), find: { ...find, t1: { ...find.t1, query: "from snapshot" } }, ui: { ...ui, appDark: !ui.appDark } }, { keepLocal: true });
  assert.equal(changed.find.t1.query, "from snapshot");
  assert.equal(changed.find.t2, S().find.t2);
  assert.equal(changed.ui.appDark, !ui.appDark);
  assert.equal(changed.ui.focusOrder, S().ui.focusOrder);
  assert.deepEqual(workspaceFromSnapshot(S(), { ...snapshot(), find: {} }, { keepLocal: true }).find, {});
});

test("find pruning comes from the native patch instead of tab-derived JS writes", () => {
  assert.equal(workspaceFromPatch(S(), { rev, tabs: { upsert: [], remove: ["t1"] } }).find, undefined);
  const next = workspaceFromPatch(S(), { rev, tabs: { upsert: [], remove: ["t1"] }, find: { upsert: [], remove: ["t1"] } });
  assert.deepEqual(Object.keys(next.find), ["t2"]);
  assert.equal(next.find.t2, S().find.t2);
});

test("hydrate clears native find while keeping observed appDark", () => {
  const data = snapshot();
  sent.length = 0;
  S().hydrate({ ...data, windows: Object.values(data.windows), tabs: Object.values(data.tabs) });
  assert.ok(sent.some((command) => command.name === "hydrate"));
  assert.deepEqual(S().find, {});
  assert.equal(S().ui.appDark, ui.appDark);
});


test("hydrate cannot erase find accepted from a response subscriber", () => {
  S().setFind("t1", { query: "before hydrate" });
  let accepted;
  let triggered = false;
  const stop = useBrowser.subscribe((s, prev) => {
    if (triggered || !prev.find.t1 || s.find.t1) return;
    triggered = true;
    s.setFind("t1", { open: true, query: "newer than hydrate" });
    accepted = S().find;
  });
  try {
    const data = snapshot();
    S().hydrate({ ...data, windows: Object.values(data.windows), tabs: Object.values(data.tabs) });
    assert.ok(accepted);
    assert.equal(S().find, accepted);
    assert.equal(S().find.t1.query, "newer than hydrate");
  } finally {
    stop();
  }
});


test("replacement writes retain the native ui and find identities", () => {
  const before = S();
  const seen = [];
  const stop = useBrowser.subscribe((s) => seen.push([s.ui, s.find]));
  const warn = console.warn;
  console.warn = () => {};
  sent.length = 0;
  try {
    useBrowser.setState({ ...before, ui: { ...before.ui, appDark: !before.ui.appDark }, find: {} }, true);
    assert.equal(S().ui, before.ui);
    assert.equal(S().find, before.find);
    assert.ok(seen.every(([ui, find]) => ui === before.ui && find === before.find));
    assert.deepEqual(sent, []);
  } finally {
    stop();
    console.warn = warn;
  }
});

test("mixed UI writes forward only writable focus fields", () => {
  const warn = console.warn;
  console.warn = () => {};
  try {
    for (const write of [(update) => useBrowser.setState(update), (update) => writeState(useBrowser, update)]) {
      const before = S();
      sent.length = 0;
      write({ ui: { ...before.ui, focusedWindowId: null, appDark: !before.ui.appDark }, find: {} });
      assert.deepEqual(sent, [{ name: "applyState", args: [{ ui: { focusedWindowId: null, focusOrder: before.ui.focusOrder, lastProfileId: before.ui.lastProfileId } }] }]);
      assert.equal(S().ui, before.ui);
      assert.equal(S().find, before.find);
    }
  } finally {
    console.warn = warn;
  }
});
