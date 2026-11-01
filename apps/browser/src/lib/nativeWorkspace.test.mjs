import assert from "node:assert/strict";
import { test, beforeEach } from "node:test";

const tab = { id: "t1", windowId: "w1", profileId: "default", url: "https://a.example/", title: "A", favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, pinnedUrl: null, openerId: null, createdAt: 1, lastActiveAt: 1 };
const win = { id: "w1", profileId: "default", incognito: false, tabIds: ["t1"], activeTabIds: { default: "t1" }, sidebarOpen: true, frame: null, createdAt: 1 };
const data = (rev) => ({ rev, data: { profiles: { default: { id: "default", name: "Personal", color: "plum", icon: null, createdAt: 0 } }, profileOrder: ["default"], windows: { w1: win }, windowOrder: ["w1"], tabs: { t1: { ...tab, title: `A${rev}` } }, groups: {}, splits: {}, peeks: {}, closedTabs: [], closedWindows: [], closedGroups: [], deletedGroups: [], cleanedTabs: [], parkedPins: {}, pinChoices: {}, pinSync: {}, downloads: [], settings: { chosen: [], inferred: [] }, ui: { focusedWindowId: "w1", focusOrder: ["w1"], lastProfileId: null } } });
const listeners = new Set();
let rev = 1;
let dispatchReply;
let catchUpReply;
let dispatchHook;
const sent = [];
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: true, scope: "everything" }),
    snapshot: () => JSON.stringify(data(rev)),
    dispatch: (json, sinceRev) => {
      const commands = [JSON.parse(json)].flat();
      sent.push(...commands.map((c) => c.name));
      dispatchHook?.(commands);
      if (dispatchReply) return JSON.stringify(dispatchReply);
      return JSON.stringify({ rev: Math.max(rev, sinceRev), patches: [] });
    },
    catchUp: () => JSON.stringify(catchUpReply ?? { rev, snapshot: data(rev).data }),
    flush: () => "saved",
    addListener: (_e, listener) => {
      listeners.add(listener);
      return { remove: () => listeners.delete(listener) };
    },
  },
};

const { useBrowser } = await import("../store/browser.ts");
const capturedSetWindowFrame = useBrowser.getState().setWindowFrame;
const { startPersistence } = await import("./persist.ts");
const S = () => useBrowser.getState();
startPersistence();

test("attaching closes any transaction a previous JS runtime left open", () => {
  assert.ok(sent.includes("closeTransactions"));
});

test("attaching sends only the audio cache Swift cannot derive yet", () => {
  assert.deepEqual(sent.filter((name) => name.startsWith("set")), ["setPlayingAudio"]);
});

test("history and appearance changes do not send native-owned caches", () => {
  const before = sent.length;
  useBrowser.setState({ history: { default: [{ url: "https://history.example/", title: "History", favicon: "https://history.example/icon.png", visitedAt: 1 }] } });
  S().setAppDark(!S().ui.appDark);
  assert.deepEqual(sent.slice(before), []);
});

test("the fallback last-tab policy does not write Swift-owned memory", async () => {
  const { setLastTabKeepsWindow } = await import("../store/newTabBar.ts");
  const before = sent.length;
  setLastTabKeepsWindow(true);
  setLastTabKeepsWindow(false);
  assert.deepEqual(sent.slice(before), []);
});

test("a catch-up snapshot after a gap keeps the live state of what still exists and takes window UI from Swift", () => {
  S().updateLive("t1", { playingAudio: true, isLoading: true });
  rev = 5;
  catchUpReply = { rev, snapshot: { ...data(rev).data, windowUi: { w1: { panel: { open: false, initialText: "" }, downloadsOpen: true } }, selection: { w1: ["t1"] } } };
  for (const listener of listeners) listener({ event: JSON.stringify({ rev, patch: { rev } }) });
  catchUpReply = undefined;
  assert.equal(S().tabs.t1.title, "A5");
  assert.equal(S().live.t1.playingAudio, true);
  assert.equal(S().windowUi.w1.downloadsOpen, true);
  assert.deepEqual(S().selection.w1, ["t1"]);
});

const { nativeWrite, attachReplica, NativeStoreBusy, nativeStoreRev, withApplier } = await import("../store/nativeStore.ts");
const { workspaceFromSnapshot } = await import("../store/nativeWorkspace.ts");
const { asSyncOrigin, applyingFromSync } = await import("../store/syncOrigin.ts");
const { IDLE_LIVE } = await import("../store/model.ts");
beforeEach(() => {
  dispatchReply = undefined;
  catchUpReply = undefined;
  dispatchHook = undefined;
  withApplier(() => useBrowser.setState(workspaceFromSnapshot(S(), data(rev).data)));
});
const emit = (commit) => {
  for (const listener of listeners) listener({ event: JSON.stringify(commit) });
};

test("a ring-gap snapshot notifies subscribers under the calling sync origin", () => {
  const origins = [];
  const stop = useBrowser.subscribe((s, prev) => {
    if (s.tabs !== prev.tabs) origins.push(applyingFromSync());
  });
  rev += 2000;
  dispatchReply = { rev, snapshot: data(rev).data };
  try {
    asSyncOrigin(() => nativeWrite({ name: "probe", args: [] }));
  } finally {
    dispatchReply = undefined;
    stop();
  }
  assert.deepEqual(origins, [true]);
});

test("a snapshot reuses every unchanged entity and list entry", () => {
  const entity = (id) => ({ id, value: { x: 1 } });
  const s = { ...S(), profiles: { p: entity("p") }, windows: { w: entity("w") }, tabs: { t: entity("t") }, groups: { g: entity("g") }, splits: { s: entity("s") }, peeks: { w: entity("peek") }, parkedPins: { p: entity("parked") }, pinChoices: { p: entity("choices") }, pinSync: { p: entity("sync") }, closedTabs: [entity("closed"), entity("changed")], downloads: [entity("download")], privateCleanedTabs: { w: [entity("cleaned")] } };
  const snapshot = JSON.parse(JSON.stringify(s));
  snapshot.tabs.new = entity("new");
  snapshot.closedTabs[1].value.x = 2;
  const next = workspaceFromSnapshot(s, snapshot, { keepLocal: true });
  for (const key of ["profiles", "windows", "tabs", "groups", "splits", "peeks", "parkedPins", "pinChoices", "pinSync"]) for (const id of Object.keys(s[key])) assert.equal(next[key][id], s[key][id], `${key}.${id}`);
  assert.equal(next.closedTabs[0], s.closedTabs[0]);
  assert.notEqual(next.closedTabs[1], s.closedTabs[1]);
  assert.equal(next.downloads[0], s.downloads[0]);
  assert.equal(next.privateCleanedTabs.w[0], s.privateCleanedTabs.w[0]);
});

test("native hydrate installs supplied views and resets transient state only after acceptance", () => {
  S().updateLive("t1", { isLoading: true });
  withApplier(() => useBrowser.setState({ find: { t1: { query: "stale" } }, selection: { w1: ["t1"] } }));
  const input = { ...data(rev).data, history: { default: [{ url: "https://history.example/", title: "History", visitedAt: 1 }] }, bookmarks: { nodes: {}, roots: { default: { bar: "bar", other: "other" } } } };
  const beforeForwards = globalThis.__nativeStoreForwards?.length ?? 0;
  let beforeDispatch;
  dispatchHook = (commands) => { if (commands.some((c) => c.name === "hydrate")) beforeDispatch = S(); };
  const before = S();
  dispatchReply = { rev: ++rev, snapshot: data(rev).data };
  try {
    S().hydrate(input);
  } finally {
    dispatchReply = undefined;
  }
  assert.equal(beforeDispatch, before);
  assert.deepEqual(S().history.default, input.history.default);
  assert.equal(S().historyReady.default, true);
  assert.equal(S().bookmarksReady.default, true);
  assert.deepEqual(S().bookmarks.roots.default, input.bookmarks.roots.default);
  assert.equal(S().live.t1, IDLE_LIVE);
  assert.deepEqual(S().find, {});
  assert.deepEqual(S().selection, {});
  assert.equal(globalThis.__nativeStoreForwards?.length ?? 0, beforeForwards);
});

test("busy and refused hydrate leave every local slice untouched", () => {
  const warn = console.warn;
  console.warn = () => {};
  try {
    for (const response of [{ rev: rev + 1, busy: true, patches: [{ rev: rev + 1, settings: { set: { searchEngine: "foreign" } } }] }, { rev: rev + 1, error: "refused", snapshot: data(rev + 1).data }]) {
      const before = S();
      dispatchReply = response;
      if (response.busy) assert.throws(() => S().hydrate({ history: {}, tabs: {} }), NativeStoreBusy);
      else S().hydrate({ history: {}, tabs: {} });
      assert.equal(S(), before);
    }
  } finally {
    dispatchReply = undefined;
    console.warn = warn;
  }
});

test("a refused workspace command cannot install its trailing live patch", () => {
  const before = S().live;
  const warn = console.warn;
  console.warn = () => {};
  dispatchReply = { rev, error: "refused" };
  try {
    S().updateTab("t1", { title: "refused" }, { isLoading: true });
  } finally {
    dispatchReply = undefined;
    console.warn = warn;
  }
  assert.equal(S().live, before);
});

test("Release: owned API and captured reducer writes expose only the native accepted value", () => {
  const heldDev = globalThis.__DEV__;
  globalThis.__DEV__ = false;
  const warn = console.warn;
  console.warn = () => {};
  const seen = [];
  const stop = useBrowser.subscribe((s) => {
    seen.push(s.settings.searchEngine);
    assert.notDeepEqual(s.windows.w1.frame, [9, 9, 9, 9]);
  });
  dispatchHook = (commands) => {
    if (!commands.some((c) => c.name === "applyState")) return;
    dispatchReply = { rev: ++rev, patches: [{ rev, bridge: true, settings: { set: { searchEngine: "native" } }, windows: { upsert: [{ ...win, frame: [1, 2, 3, 4] }], remove: [] } }] };
  };
  catchUpReply = { rev, patches: [] };
  try {
    const beforeFind = S().find;
    useBrowser.setState((s) => ({ settings: { ...s.settings, searchEngine: "unforwarded-api" }, find: { t1: { query: "local" } }, bookmarksReady: { ...s.bookmarksReady, local: true } }));
    assert.equal(S().settings.searchEngine, "native");
    assert.equal(S().find, beforeFind);
    assert.equal(S().bookmarksReady.local, true);
    capturedSetWindowFrame("w1", [9, 9, 9, 9]);
    assert.deepEqual(S().windows.w1.frame, [1, 2, 3, 4]);
    assert.equal(S().settings.searchEngine, "native");
    assert.ok(seen.length > 0);
    assert.ok(seen.every((value) => value === "native"));
  } finally {
    dispatchHook = undefined;
    dispatchReply = undefined;
    catchUpReply = undefined;
    stop();
    console.warn = warn;
    globalThis.__DEV__ = heldDev;
  }
});

test("Release: a subscriber's captured reducer cannot reuse the patch applier's permission", () => {
  const heldDev = globalThis.__DEV__;
  globalThis.__DEV__ = false;
  const warn = console.warn;
  console.warn = () => {};
  const seen = [];
  const stop = useBrowser.subscribe((s) => {
    seen.push(s.settings.searchEngine);
    if (s.settings.searchEngine === "trigger" && !s.windows.w1.frame) capturedSetWindowFrame("w1", [9, 9, 9, 9]);
  });
  dispatchHook = (commands) => {
    if (commands.some((c) => c.name === "applyState")) dispatchReply = { rev: ++rev, patches: [{ rev, bridge: true, settings: { set: { searchEngine: "accepted-reentrant" } }, windows: { upsert: [{ ...win, frame: [1, 2, 3, 4] }], remove: [] } }] };
  };
  dispatchReply = { rev: ++rev, patches: [{ rev, settings: { set: { searchEngine: "trigger" } } }] };
  catchUpReply = { rev, patches: [] };
  try {
    nativeWrite({ name: "probe", args: [] });
    assert.equal(S().settings.searchEngine, "accepted-reentrant");
    assert.deepEqual(seen, ["trigger", "accepted-reentrant"]);
  } finally {
    dispatchHook = undefined;
    dispatchReply = undefined;
    catchUpReply = undefined;
    stop();
    console.warn = warn;
    globalThis.__DEV__ = heldDev;
  }
});

test("repeated effect-only commits at the current revision still run", async () => {
  const { onStoreEffect } = await import("../store/nativeWorkspace.ts");
  const seen = [];
  const stop = onStoreEffect("probe", (effect) => seen.push(effect.n));
  emit({ rev, patch: { rev }, effects: [{ type: "probe", n: 1 }] });
  emit({ rev, patch: { rev }, effects: [{ type: "probe", n: 2 }] });
  stop();
  assert.deepEqual(seen, [1, 2]);
});

test("cache deduplication retries a busy write with the same inputs", () => {
  let cache = false;
  const cacheCommands = () => [{ name: "setPlayingAudio", args: [[cache ? "t1" : "other"]] }];
  attachReplica(useBrowser, cacheCommands);
  sent.length = 0;
  cache = true;
  dispatchReply = { rev, busy: true };
  assert.throws(() => useBrowser.setState({ historyReady: { ...S().historyReady, busy: true } }), NativeStoreBusy);
  dispatchReply = { rev, patches: [] };
  useBrowser.setState({ historyReady: { ...S().historyReady, busy: false } });
  assert.equal(sent.filter((name) => name === "setPlayingAudio").length, 2);
  dispatchReply = undefined;
});
test("Release: a React batch flush after a guarded set never inherits the applier permission", async () => {
  const { setStoreBatching } = await import("../store/browser.ts");
  const heldDev = globalThis.__DEV__;
  globalThis.__DEV__ = false;
  const warn = console.warn;
  console.warn = () => {};
  let flushOnce = true;
  setStoreBatching((update) => {
    update();
    if (!flushOnce) return;
    flushOnce = false;
    capturedSetWindowFrame("w1", [9, 9, 9, 9]);
  });
  dispatchHook = (commands) => {
    if (commands.some((c) => c.name === "applyState")) dispatchReply = { rev: ++rev, patches: [{ rev, bridge: true, windows: { upsert: [{ ...win, frame: [1, 2, 3, 4] }], remove: [] } }] };
  };
  dispatchReply = { rev: ++rev, patches: [{ rev, settings: { set: { searchEngine: "batch-trigger" } } }] };
  catchUpReply = { rev, patches: [] };
  try {
    nativeWrite({ name: "probe", args: [] });
    assert.deepEqual(S().windows.w1.frame, [1, 2, 3, 4]);
  } finally {
    setStoreBatching((update) => update());
    console.warn = warn;
    globalThis.__DEV__ = heldDev;
  }
});

test("Debug refuses an owned API write synchronously before dispatch or publication", () => {
  const held = globalThis.__DEV__;
  globalThis.__DEV__ = true;
  const before = S();
  const beforeSent = sent.length;
  let notifications = 0;
  const stop = useBrowser.subscribe(() => notifications++);
  try {
    assert.throws(() => useBrowser.setState((s) => ({ settings: { ...s.settings, searchEngine: "refused" }, selection: { w1: ["local"] } })), /outside the native store's applier/);
    assert.equal(S(), before);
    assert.equal(sent.length, beforeSent);
    assert.equal(notifications, 0);
  } finally {
    stop();
    globalThis.__DEV__ = held;
  }
});

test("Debug refuses a captured slice setter before zustand sees the owned change", () => {
  const held = globalThis.__DEV__;
  globalThis.__DEV__ = true;
  const before = S();
  const beforeSent = sent.length;
  try {
    assert.throws(() => capturedSetWindowFrame("w1", [9, 9, 9, 9]), /outside the native store's applier/);
    assert.equal(S(), before);
    assert.equal(sent.length, beforeSent);
  } finally {
    globalThis.__DEV__ = held;
  }
});

test("Debug keeps sync-origin whole-slice forwards until the sync port", () => {
  const held = globalThis.__DEV__;
  const warn = console.warn;
  globalThis.__DEV__ = true;
  console.warn = () => {};
  const beforeSent = sent.length;
  try {
    asSyncOrigin(() => useBrowser.setState({ settings: { ...S().settings, searchEngine: "sync" } }));
    assert.deepEqual(sent.slice(beforeSent), ["applyState"]);
  } finally {
    globalThis.__DEV__ = held;
    console.warn = warn;
  }
});

test("Release forwards with a monotonically counted warning", async () => {
  const { nativeForwardedWrites } = await import("../store/nativeStore.ts");
  const held = globalThis.__DEV__;
  const warn = console.warn;
  globalThis.__DEV__ = false;
  const warnings = [];
  console.warn = (...args) => warnings.push(args.join(" "));
  try {
    const before = nativeForwardedWrites();
    useBrowser.setState({ settings: { ...S().settings, searchEngine: "release" } });
    assert.equal(nativeForwardedWrites(), before + 1);
    assert.ok(warnings.some((message) => message.includes(`forwarded write ${before + 1}`)));
  } finally {
    globalThis.__DEV__ = held;
    console.warn = warn;
  }
});
