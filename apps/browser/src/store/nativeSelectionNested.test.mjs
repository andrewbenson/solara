import assert from "node:assert/strict";
import { test, beforeEach } from "node:test";

const tab = { id: "t1", windowId: "w1", profileId: "default", url: "https://example.com", title: "Example", favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, pinnedUrl: null, openerId: null, createdAt: 1, lastActiveAt: 1 };
const win = { id: "w1", profileId: "default", incognito: false, tabIds: ["t1", "t2"], activeTabIds: { default: "t1" }, sidebarOpen: true, frame: null, createdAt: 1 };
let rev = 0;
let title = "Example";
let windowUi = {};
let selection = {};
let probeReply = null;
const log = [];
const listeners = new Set();
const snapshot = () => ({ profiles: { default: { id: "default", name: "Personal", color: "plum", icon: null, createdAt: 0 } }, profileOrder: ["default"], windows: { w1: win }, windowOrder: ["w1"], tabs: { t1: { ...tab, title }, t2: { ...tab, id: "t2" } }, groups: {}, splits: {}, peeks: {}, closedTabs: [], closedWindows: [], closedGroups: [], deletedGroups: [], cleanedTabs: [], privateCleanedTabs: {}, privateSiteMutes: {}, parkedPins: {}, pinChoices: {}, pinSync: {}, downloads: [], settings: { chosen: [], inferred: [] }, ui: { focusedWindowId: "w1", focusOrder: ["w1"], lastProfileId: null, appDark: true }, find: {}, selection, selectionAnchors: {}, windowUi });
const commit = (patch) => {
  const entry = { rev: ++rev, ...patch };
  log.push(entry);
  return entry;
};
const retitle = () => {
  title = `Example ${rev + 1}`;
  return commit({ tabs: { upsert: [{ ...tab, title }], remove: [] } });
};
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: true }),
    snapshot: () => JSON.stringify({ rev, data: snapshot() }),
    dispatch(json, sinceRev) {
      for (const command of [JSON.parse(json)].flat()) {
        if (command.name === "openPanel") {
          const [id, initialText] = command.args;
          windowUi = { ...windowUi, [id]: { panel: { open: true, initialText }, downloadsOpen: false } };
          commit({ windowUi: { upsert: [{ windowId: id, state: windowUi[id] }], remove: [] } });
        }
        if (command.name === "setSelection") {
          const [id, ids] = command.args;
          selection = { ...selection, [id]: ids };
          commit({ selection: { upsert: [{ windowId: id, ids }], remove: [] } });
        }
        if (command.name === "probe") {
          const reply = probeReply;
          probeReply = null;
          if (reply === "snapshot") {
            retitle();
            return JSON.stringify({ rev, snapshot: snapshot() });
          }
          retitle();
          retitle();
        }
      }
      return JSON.stringify({ rev, patches: log.filter((p) => p.rev > sinceRev) });
    },
    catchUp: (sinceRev) => JSON.stringify({ rev, patches: log.filter((p) => p.rev > sinceRev) }),
    flush: () => true,
    addListener: (_event, listener) => {
      listeners.add(listener);
      return { remove: () => listeners.delete(listener) };
    },
  },
};
const { useBrowser } = await import("./browser.ts");
const { startPersistence } = await import("../lib/persist.ts");
const { nativeWrite } = await import("./nativeStore.ts");
const { onStoreEffect } = await import("./nativeWorkspace.ts");
const S = () => useBrowser.getState();
startPersistence();

const reactOnce = (write) => {
  let fired = false;
  return useBrowser.subscribe((s, prev) => {
    if (fired || s.tabs.t1 === prev.tabs.t1) return;
    fired = true;
    write();
  });
};
const nestedWrites = [
  ["openPanel", () => S().openPanel("w1", `typed ${rev}`), () => S().windowUi.w1.panel.initialText, () => windowUi.w1.panel.initialText],
  ["setSelection", () => S().setSelection("w1", rev % 2 ? ["t1", "t2"] : ["t2"]), () => S().selection.w1, () => selection.w1],
];

beforeEach(() => {
  windowUi = {};
  selection = {};
});

for (const [name, write, local, native] of nestedWrites) {
  test(`a subscriber's ${name} during an own patch response survives the rest of the response`, () => {
    const stop = reactOnce(write);
    try {
      nativeWrite({ name: "probe", args: [] });
    } finally {
      stop();
    }
    assert.notEqual(native(), undefined);
    assert.deepEqual(local(), native());
    assert.equal(S().tabs.t1.title, title);
  });

  test(`a subscriber's ${name} during an own snapshot response survives`, () => {
    const stop = reactOnce(write);
    probeReply = "snapshot";
    try {
      nativeWrite({ name: "probe", args: [] });
    } finally {
      stop();
    }
    assert.notEqual(native(), undefined);
    assert.deepEqual(local(), native());
    assert.equal(S().tabs.t1.title, title);
  });

  test(`a subscriber's ${name} during a foreign catch-up survives`, () => {
    const stop = reactOnce(write);
    retitle();
    retitle();
    try {
      for (const listener of listeners) listener({ event: JSON.stringify({ rev, patch: log.at(-1) }) });
    } finally {
      stop();
    }
    assert.notEqual(native(), undefined);
    assert.deepEqual(local(), native());
    assert.equal(S().tabs.t1.title, title);
  });
}

test("a foreign commit's non-UI effect runs exactly once, also at or below the applied revision", () => {
  const seen = [];
  const stop = onStoreEffect("probe", (effect) => seen.push(effect.n));
  try {
    const emit = (at, n) => {
      for (const listener of listeners) listener({ event: JSON.stringify({ rev: at, patch: { rev: at }, effects: [{ type: "probe", n }] }) });
    };
    retitle();
    emit(rev, 1);
    emit(rev, 2);
    emit(rev - 1, 3);
    emit(1, 4);
    assert.deepEqual(seen, [1, 2, 3, 4]);
  } finally {
    stop();
  }
});
