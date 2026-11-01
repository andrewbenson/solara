import assert from "node:assert/strict";
import { test } from "node:test";

const sent = [];
const listeners = new Set();
const native = {
  rev: 0,
  settings: { searchEngine: "google", chosen: [], inferred: [] },
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
};
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: true }),
    snapshot: () => {
      native.beforeSnapshot?.();
      native.beforeSnapshot = null;
      return JSON.stringify({ rev: native.rev, data: { settings: native.settings, downloads: native.downloads } });
    },
    dispatch(json, sinceRev) {
      const commands = [JSON.parse(json)].flat();
      const effects = [];
      sent.push(...commands);
      for (const { name, args } of commands) {
        if (name === "updateSettings") {
          native.settings = { ...native.settings, ...args[0], chosen: [...new Set([...native.settings.chosen, ...Object.keys(args[0])])] };
          native.commit({ settings: { set: { ...args[0], chosen: native.settings.chosen } } });
        } else if (name === "deleteProfile") {
          const id = args[0];
          const profile = native.profiles?.[id];
          if (!profile || Object.keys(native.profiles).length <= 1) continue;
          const engine = profile.dataId ?? id;
          const shared = Object.values(native.profiles).some((other) => other.id !== id && (other.dataId ?? other.id) === engine);
          delete native.profiles[id];
          native.settings = {
            ...native.settings,
            defaultProfileId: native.settings.defaultProfileId === id ? Object.keys(native.profiles)[0] : native.settings.defaultProfileId,
            neverTranslateSites: Object.fromEntries(Object.entries(native.settings.neverTranslateSites ?? {}).filter(([key]) => key !== id)),
            developerMode: Object.fromEntries(Object.entries(native.settings.developerMode ?? {}).filter(([key]) => key !== id)),
          };
          native.commit({ settings: { set: native.settings } });
          effects.push({ type: "profileDeleted", profileId: id, shared });
        } else if (name === "applyState" || name === "attachReplicaProfiles") {
          const patch = {};
          if (args[0].downloads) patch.downloads = native.downloads = args[0].downloads;
          if (args[0].profiles) native.profiles = args[0].profiles;
          if (args[0].settings) {
            native.settings = args[0].settings;
            patch.settings = { set: args[0].settings };
          }
          native.commit(patch);
        }
      }
      return JSON.stringify({ ...native.since(sinceRev), effects });
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

const { docs } = await import("../test-native/index.ts");
docs.set("session.json", JSON.stringify({ version: 2, settings: { searchEngine: "bing" }, windows: [], tabs: [] }));
docs.set("downloads.json", JSON.stringify({ version: 2, downloads: [{ id: "stale", state: "complete" }] }));
const { useBrowser } = await import("../store/browser.ts");
const { flushPersistence, startPersistence } = await import("./persist.ts");
const { nativeStoreActive, nativeStoreRev } = await import("../store/nativeStore.ts");
const { applyingFromSync } = await import("../store/syncOrigin.ts");
const S = () => useBrowser.getState();
const foreign = (patch) => {
  const entry = native.commit(patch);
  for (const listener of listeners) listener({ event: JSON.stringify({ rev: entry.rev, patch: entry }) });
};

native.settings = { ...native.settings, searchEngine: "duckduckgo", chosen: ["searchEngine"] };
native.downloads = [{ id: "saved-0", url: "https://e/1", state: "complete", profile: "" }];
startPersistence();

test("the replica hydrates settings and downloads from the native store, not the files", () => {
  assert.equal(nativeStoreActive(), true);
  assert.equal(S().settings.searchEngine, "duckduckgo");
  assert.deepEqual(S().downloads.map((d) => d.id), ["saved-0"]);
});

test("updateSettings becomes a native command and the replica applies its patch", () => {
  sent.length = 0;
  S().updateSettings({ appearance: "dark" });
  assert.deepEqual(sent.map((c) => c.name), ["updateSettings"]);
  assert.equal(S().settings.appearance, "dark");
  assert.equal(nativeStoreRev(), native.rev);
});

test("download actions send the list JS decided on, and the replica takes it from the patch", () => {
  sent.length = 0;
  S().upsertDownload({ id: "fresh", url: "https://e/2", state: "downloading", profile: "" });
  assert.equal(sent[0].name, "applyState");
  assert.deepEqual(S().downloads.map((d) => d.id), ["fresh", "saved-0"]);
  S().removeDownload("saved-0");
  assert.deepEqual(native.downloads.map((d) => d.id), ["fresh"]);
  assert.deepEqual(S().downloads.map((d) => d.id), ["fresh"]);
});

test("foreign commits apply in order, and a gap catches up from the native store", () => {
  foreign({ settings: { set: { searchEngine: "ecosia" } } });
  assert.equal(S().settings.searchEngine, "ecosia");
  native.commit({ settings: { set: { appearance: "light" } } });
  foreign({ settings: { set: { searchEngine: "brave" } } });
  assert.equal(S().settings.appearance, "light");
  assert.equal(S().settings.searchEngine, "brave");
  assert.equal(nativeStoreRev(), native.rev);
});

test("Release: a write outside the applier is forwarded to the native store, not lost", () => {
  const heldDev = globalThis.__DEV__;
  globalThis.__DEV__ = false;
  sent.length = 0;
  const warn = console.warn;
  const warnings = [];
  console.warn = (...args) => warnings.push(args.join(" "));
  try {
    useBrowser.setState({ settings: { ...S().settings, searchEngine: "kagi" } });
  } finally {
    console.warn = warn;
    globalThis.__DEV__ = heldDev;
  }
  assert.equal(sent[0]?.name, "applyState");
  assert.equal(native.settings.searchEngine, "kagi");
  assert.ok(warnings.some((w) => w.includes("outside the native store's applier")));
});

test("JS-owned profiles are mirrored into the native store for native Settings", () => {
  assert.deepEqual(Object.keys(native.profiles ?? {}), Object.keys(S().profiles));
  S().createProfile({ name: "Work" });
  assert.equal(Object.keys(native.profiles).length, Object.keys(S().profiles).length);
  assert.ok(Object.values(native.profiles).some((p) => p.name === "Work"));
});

test("a subscriber that dispatches while a patch applies never moves the applied rev backwards", () => {
  let nested = false;
  const stop = useBrowser.subscribe((s, prev) => {
    if (nested || s.settings.searchEngine === prev.settings.searchEngine) return;
    nested = true;
    S().updateSettings({ appearance: "light" });
  });
  foreign({ settings: { set: { searchEngine: "startpage" } } });
  stop();
  assert.equal(S().settings.appearance, "light");
  assert.equal(nativeStoreRev(), native.rev);
  const before = sent.length;
  S().updateSettings({ appearance: "dark" });
  assert.equal(sent.length, before + 1);
  assert.equal(nativeStoreRev(), native.rev);
});

test("deleting a profile sends its settings repair to the native store, not past the applier", () => {
  const id = S().createProfile({ name: "Leaving" });
  S().setDefaultProfile(id);
  assert.equal(native.settings.defaultProfileId, id);
  sent.length = 0;
  const warn = console.warn;
  const warnings = [];
  console.warn = (...args) => warnings.push(args.join(" "));
  try {
    S().deleteProfile(id);
  } finally {
    console.warn = warn;
  }
  assert.notEqual(native.settings.defaultProfileId, id);
  assert.equal(S().settings.defaultProfileId, native.settings.defaultProfileId);
  assert.ok(sent.some((command) => command.name === "deleteProfile" && command.args[0] === id));
  assert.ok(sent.some((command) => command.name === "applyState" && command.args[0].settings?.defaultProfileId === S().settings.defaultProfileId));
  assert.ok(!warnings.some((w) => w.includes("outside the native store's applier")));
});

test("a commit that only carries effects still runs them, and effects behind a rev jump aren't lost", async () => {
  const { onStoreEffect } = await import("../store/nativeWorkspace.ts");
  const seen = [];
  const stop = onStoreEffect("probe", (effect) => seen.push(effect.n));
  const send = (rev, patch, effects) => {
    for (const listener of listeners) listener({ event: JSON.stringify({ rev, patch: { rev, ...patch }, effects }) });
  };
  send(native.rev, {}, [{ type: "probe", n: 1 }]);
  const jumped = native.commit({ settings: { set: { appearance: "light" } } });
  S().updateSettings({ searchEngine: "qwant" });
  send(jumped.rev, jumped, [{ type: "probe", n: 2 }]);
  stop();
  assert.deepEqual(seen, [1, 2]);
  assert.equal(S().settings.appearance, "light");
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
  for (const listener of listeners) listener({ event: JSON.stringify({ rev: pending.rev, patch: pending }) });
  assert.ok(S().downloads.some((d) => d.id === "from-elsewhere"));
  assert.equal(S().settings.searchEngine, "mojeek");
});

test("persist.ts marks session.json and leaves downloads.json to the native store", () => {
  docs.delete("downloads.json");
  S().updateSettings({ appearance: "dark" });
  flushPersistence();
  const session = JSON.parse(docs.get("session.json"));
  assert.equal(session.nativeExport.rev, native.rev);
  assert.equal(session.settings.appearance, "dark");
  assert.equal(docs.has("downloads.json"), false);
});

test("Debug hydration in settingsAndDownloads scope routes owned slices through commands", () => {
  const held = globalThis.__DEV__;
  globalThis.__DEV__ = true;
  sent.length = 0;
  try {
    S().hydrate({ settings: { ...S().settings, searchEngine: "qwant" }, downloads: [{ id: "rehydrated", url: "https://download.example/", state: "complete", profile: "" }] });
    assert.equal(S().settings.searchEngine, "qwant");
    assert.equal(native.settings.searchEngine, "qwant");
    assert.equal(native.downloads[0].id, "rehydrated");
    assert.ok(sent.some((command) => command.name === "applyState" && command.args[0].settings?.searchEngine === "qwant"));
  } finally {
    globalThis.__DEV__ = held;
  }
});

test("Release: writeState in settingsAndDownloads scope sends settings and downloads as a command, not a forwarded write", async () => {
  const { nativeForwardedWrites, writeState } = await import("../store/nativeStore.ts");
  const held = globalThis.__DEV__;
  const warn = console.warn;
  const warnings = [];
  globalThis.__DEV__ = false;
  console.warn = (...args) => warnings.push(args.join(" "));
  sent.length = 0;
  const forwarded = nativeForwardedWrites();
  try {
    writeState(useBrowser, { settings: { ...S().settings, searchEngine: "ecosia" }, downloads: [{ id: "written", url: "https://download.example/w", state: "complete", profile: "" }] });
    assert.equal(S().settings.searchEngine, "ecosia");
    assert.equal(native.settings.searchEngine, "ecosia");
    assert.equal(native.downloads[0].id, "written");
    assert.deepEqual(sent.map((command) => command.name), ["applyState"]);
    assert.equal(nativeForwardedWrites(), forwarded);
    assert.deepEqual(warnings, []);
  } finally {
    globalThis.__DEV__ = held;
    console.warn = warn;
  }
});
