import "../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";

const tab = { id: "t1", windowId: "w1", profileId: "default", url: "https://a.example/", title: "A", favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, pinnedUrl: null, openerId: null, createdAt: 1, lastActiveAt: 1 };
const win = { id: "w1", profileId: "default", incognito: false, tabIds: ["t1"], activeTabIds: { default: "t1" }, sidebarOpen: true, frame: null, createdAt: 1 };
const live = { isLoading: false, canGoBack: false, canGoForward: false, playingAudio: false, themeColor: null, discarded: false };
const sent = [];
const listeners = new Set();
const native = {
  rev: 0,
  settings: { searchEngine: "duckduckgo", chosen: ["searchEngine"], inferred: [] },
  downloads: [],
  log: [],
  commit(patch) {
    this.rev += 1;
    const entry = { rev: this.rev, ...patch };
    this.log.push(entry);
    return entry;
  },
  since(rev) {
    return { rev: this.rev, patches: this.log.filter((p) => p.rev > rev) };
  },
  data() {
    return { live: { t1: live }, profiles: { default: { id: "default", name: "Personal", color: "plum", icon: null, createdAt: 0 } }, profileOrder: ["default"], windows: { w1: win }, windowOrder: ["w1"], tabs: { t1: tab }, groups: {}, splits: {}, peeks: {}, closedTabs: [], closedWindows: [], closedGroups: [], deletedGroups: [], cleanedTabs: [], parkedPins: {}, pinChoices: {}, pinSync: {}, downloads: this.downloads, settings: this.settings, ui: { focusedWindowId: "w1", focusOrder: ["w1"], lastProfileId: null } };
  },
};
const setSettings = (changes) => {
  native.settings = { ...native.settings, ...changes };
  return native.commit({ settings: { set: changes } });
};
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: true }),
    snapshot: () => JSON.stringify({ rev: native.rev, data: native.data() }),
    dispatch(json, sinceRev) {
      const commands = [JSON.parse(json)].flat();
      sent.push(...commands.map((c) => c.name));
      for (const { name, args } of commands) {
        if (name === "updateSettings") setSettings(args[0]);
        else if (name === "applyState") {
          const patch = {};
          if (args[0].downloads) patch.downloads = native.downloads = args[0].downloads;
          if (args[0].settings) {
            native.settings = args[0].settings;
            patch.settings = { set: args[0].settings };
          }
          if (Object.keys(patch).length) native.commit(patch);
        }
      }
      return JSON.stringify(native.since(sinceRev));
    },
    catchUp: (sinceRev) => {
      native.beforeCatchUp?.();
      native.beforeCatchUp = null;
      return JSON.stringify(native.since(sinceRev));
    },
    flush: () => "saved",
    addListener(_event, listener) {
      listeners.add(listener);
      return { remove: () => listeners.delete(listener) };
    },
  },
};

const { useBrowser } = await import("../store/browser.ts");
const { startPersistence } = await import("./persist.ts");
const { nativeOwnsWorkspace, nativeStoreRev } = await import("../store/nativeStore.ts");
const { applyingFromSync } = await import("../store/syncOrigin.ts");
const S = () => useBrowser.getState();
const announce = (entry) => {
  for (const listener of listeners) listener({ event: JSON.stringify({ rev: entry.rev, patch: entry }) });
};
startPersistence();

test("the owned store starts from Swift's snapshot", () => {
  assert.equal(nativeOwnsWorkspace(), true);
  assert.equal(S().settings.searchEngine, "duckduckgo");
  assert.equal(nativeStoreRev(), native.rev);
});

test("foreign commits apply in order, and a gap catches up from the native store", () => {
  announce(setSettings({ searchEngine: "ecosia" }));
  assert.equal(S().settings.searchEngine, "ecosia");
  setSettings({ appearance: "light" });
  announce(setSettings({ searchEngine: "brave" }));
  assert.equal(S().settings.appearance, "light");
  assert.equal(S().settings.searchEngine, "brave");
  assert.equal(nativeStoreRev(), native.rev);
});

test("a subscriber that dispatches while a patch applies never moves the applied rev backwards", () => {
  let nested = false;
  const stop = useBrowser.subscribe((s, prev) => {
    if (nested || s.settings.searchEngine === prev.settings.searchEngine) return;
    nested = true;
    S().updateSettings({ appearance: "dark" });
  });
  announce(setSettings({ searchEngine: "startpage" }));
  stop();
  assert.ok(nested);
  assert.equal(S().settings.appearance, "dark");
  assert.equal(nativeStoreRev(), native.rev);
  const before = sent.length;
  S().updateSettings({ appearance: "light" });
  assert.equal(sent.length, before + 1);
  assert.equal(S().settings.appearance, "light");
  assert.equal(nativeStoreRev(), native.rev);
});

test("a commit that only carries effects still runs them, and effects behind a rev jump aren't lost", async () => {
  const { onStoreEffect } = await import("../store/nativeWorkspace.ts");
  const seen = [];
  const stop = onStoreEffect("probe", (effect) => seen.push(effect.n));
  const send = (rev, patch, effects) => {
    for (const listener of listeners) listener({ event: JSON.stringify({ rev, patch: { rev, ...patch }, effects }) });
  };
  send(native.rev, {}, [{ type: "probe", n: 1 }]);
  const jumped = setSettings({ appearance: "system" });
  S().updateSettings({ searchEngine: "qwant" });
  assert.ok(nativeStoreRev() > jumped.rev);
  send(jumped.rev, jumped, [{ type: "probe", n: 2 }]);
  stop();
  assert.deepEqual(seen, [1, 2]);
  assert.equal(S().settings.appearance, "system");
  assert.equal(S().settings.searchEngine, "qwant");
});

test("Release: a resync after a forwarded write doesn't skip a foreign commit it didn't apply", () => {
  const heldDev = globalThis.__DEV__;
  globalThis.__DEV__ = false;
  let pending;
  native.beforeCatchUp = () => {
    const downloads = [{ id: "from-elsewhere", url: "https://e/x", state: "complete", profile: "" }];
    native.downloads = downloads;
    pending = native.commit({ downloads, sync: true });
  };
  const origins = [];
  const stop = useBrowser.subscribe((s, prev) => {
    if (s.downloads !== prev.downloads) origins.push(applyingFromSync());
  });
  const warn = console.warn;
  console.warn = () => {};
  try {
    useBrowser.setState({ settings: { ...S().settings, searchEngine: "mojeek" } });
  } finally {
    console.warn = warn;
    globalThis.__DEV__ = heldDev;
  }
  stop();
  assert.ok(pending, "a commit landed between dispatch and resync catch-up");
  assert.deepEqual(origins, [true]);
  assert.equal(nativeStoreRev(), pending.rev);
  announce(pending);
  assert.ok(S().downloads.some((d) => d.id === "from-elsewhere"));
  assert.equal(S().settings.searchEngine, "mojeek");
});
