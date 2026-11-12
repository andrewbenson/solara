import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { test } from "node:test";
import { runInNewContext } from "node:vm";

function harness() {
  let state = { profiles: { default: { id: "default" }, cold: { id: "cold" } }, history: {}, historyReady: {}, historyFloor: {}, windows: {}, orphanedProfileData: [] };
  const subscribers = new Set();
  const loaded = new Set([""]);
  const loadListeners = new Set();
  const historyListeners = new Set();
  const reads = [], watches = [], adds = [], catalogs = [], firstWindow = [];
  const docs = new Map();
  const databases = new Map();
  let beforeAdd = async () => {};
  let clock = 0;
  const timers = new Set();
  const database = (engine) => {
    if (!databases.has(engine)) databases.set(engine, new Map());
    return databases.get(engine);
  };
  const useBrowser = { getState: () => state, setState: (patch) => {
    const previous = state;
    const next = typeof patch === "function" ? patch(state) : patch;
    state = { ...state, ...next };
    for (const listener of [...subscribers]) listener(state, previous);
  }, subscribe: (listener) => (subscribers.add(listener), () => subscribers.delete(listener)) };
  const context = { console, Date, Set, Map, Promise, queueMicrotask,
    clearTimeout: (timer) => { timers.delete(timer); },
    setTimeout: (fn, ms) => { const timer = { fn, at: clock + (ms ?? 0) }; timers.add(timer); return timer; },
    nativeSafeMode: () => false, useBrowser, MAX_HISTORY: 5000, MAX_VISIT_TIMES: 50,
    engineProfile: (id) => (state.profiles[id]?.dataId ?? id) === "default" ? "" : (state.profiles[id]?.dataId ?? id),
    engineIdOf: (profile) => (profile.dataId ?? profile.id) === "default" ? "" : (profile.dataId ?? profile.id),
    isIncognitoProfile: (id) => id.startsWith("incognito:"),
    engineProfileLoaded: (engine) => loaded.has(engine), refreshLoadedProfiles: async () => {},
    onLoadedProfilesChanged: (listener) => (loadListeners.add(listener), () => loadListeners.delete(listener)),
    onHistoryChanged: (listener) => (historyListeners.add(listener), { remove: () => historyListeners.delete(listener) }),
    readDocument: (name) => docs.get(name) ?? null,
    readDocumentResult: (name) => docs.has(name) ? { contents: docs.get(name) } : { missing: true },
    saveDocument: async (name, text) => { docs.set(name, text); }, removeDocument: (name) => docs.delete(name),
    afterFirstWindow: (fn) => { firstWindow.push(fn); },
    watchHistory: async (engine) => { watches.push(engine); },
    queryHistory: async (engine) => { reads.push(engine); return [...database(engine).values()]; },
    startNativeHistoryCatalog: async (engines) => { catalogs.push([...engines]); },
    nativeAddHistoryVisits: async (engine, pages) => {
      adds.push({ engine, pages });
      await beforeAdd(engine, pages);
      for (const page of pages) {
        const times = [...new Set([...(database(engine).get(page.url)?.visitTimes ?? []), ...page.visitTimes])].sort((a, b) => a - b);
        database(engine).set(page.url, { url: page.url, title: page.title, visits: times.length, visitTimes: times });
        for (const at of page.visitTimes) for (const listener of [...historyListeners]) queueMicrotask(() => listener({ kind: "visit", profile: engine, url: page.url, title: page.title, visits: times.length, at }));
      }
      return pages.length;
    },
  };
  const source = stripTypeScriptTypes(readFileSync(new URL("./history.ts", import.meta.url), "utf8"))
    .replace(/^import .*;\n/gm, "").replace(/^export /gm, "");
  const api = runInNewContext(`${source}\n({ startHistory, migrateHistoryFile, reloadHistory });`, context);
  return { api, docs, loaded, reads, watches, adds, catalogs, databases, useBrowser, state: () => state,
    firstWindow: () => { for (const fn of firstWindow.splice(0)) fn(); },
    beforeAdd: (fn) => { beforeAdd = fn; },
    advance: async (ms) => {
      clock += ms;
      for (const timer of [...timers].sort((a, b) => a.at - b.at)) if (timer.at <= clock) { timers.delete(timer); timer.fn(); }
      await settle();
    },
    admit: (engine) => { loaded.add(engine); for (const listener of [...loadListeners]) listener(); } };
}
const settle = async () => { for (let n = 0; n < 20; n++) await new Promise((resolve) => setImmediate(resolve)); };
const row = (url) => ({ url, title: url, visits: 1, lastVisit: Date.now(), visitTimes: [Date.now()] });

test("passive history startup never reads or watches unloaded profile", async () => {
  const h = harness();
  const stop = h.api.startHistory();
  try {
    await settle();
    assert.ok(h.reads.length > 0);
    assert.ok(h.reads.every((engine) => engine === ""));
    assert.ok(h.watches.every((engine) => engine === ""));
    assert.ok(h.catalogs.some((engines) => engines.includes("cold")), "the native catalog publishes every profile's bookmarks and gates history itself");
    assert.equal(h.state().historyReady.default, true);
    assert.equal(h.state().historyReady.cold, undefined);
    h.admit("cold");
    await settle();
    assert.ok(h.reads.includes("cold"));
    assert.equal(h.state().historyReady.cold, true);
  } finally { stop(); }
});

test("deferred legacy rows stay durable and cold history reads wait until migration writes complete", async () => {
  const h = harness();
  const source = JSON.stringify({ history: { default: [row("https://warm.test/")], cold: [row("https://cold.test/")] } });
  h.docs.set("history.json", source);
  const stop = h.api.startHistory();
  let release;
  try {
    h.firstWindow();
    await settle();
    assert.deepEqual(Object.keys(JSON.parse(h.docs.get("history.json")).history).sort(), ["cold", "default"], "imported rows stay through Chrome's commit window");
    await h.advance(15_000);
    assert.deepEqual(Object.keys(JSON.parse(h.docs.get("history.json")).history), ["cold"], "only the cold profile's rows stay queued");
    assert.deepEqual(h.adds.map((add) => add.engine), [""]);
    assert.equal(h.state().historyReady.default, true);
    assert.equal(h.state().historyReady.cold, undefined);
    assert.equal(h.state().history.default[0].url, "https://warm.test/");
    const gate = new Promise((resolve) => { release = resolve; });
    h.beforeAdd(async (engine) => { if (engine === "cold") await gate; });
    h.admit("cold");
    await settle();
    assert.ok(h.adds.some((add) => add.engine === "cold"));
    assert.equal(h.reads.includes("cold"), false, "first cold read cannot race the legacy import");
    assert.equal(h.state().historyReady.cold, undefined);
    release();
    await settle();
    assert.equal(h.state().historyReady.cold, true);
    assert.equal(h.state().history.cold[0].url, "https://cold.test/");
    assert.ok(h.docs.has("history.json"), "retention delay keeps durable source after final migration");
  } finally { release?.(); stop(); }
});


test("warm profile without a legacy source becomes ready while another profile is deferred", async () => {
  const h = harness();
  h.docs.set("history.json", JSON.stringify({ history: { cold: [row("https://cold-only.test/")] } }));
  const stop = h.api.startHistory();
  try {
    h.firstWindow();
    await settle();
    assert.equal(h.state().historyReady.default, true);
    assert.equal(h.state().historyReady.cold, undefined);
    assert.ok(h.docs.has("history.json"));
    assert.equal(h.adds.length, 0);
  } finally { stop(); }
});

test("a migrated engine's legacy rows leave the file, so later loads and relaunches never add them back", async () => {
  const h = harness();
  h.docs.set("history.json", JSON.stringify({ history: { default: [row("https://cleared.test/")], cold: [row("https://cold.test/")] } }));
  let stop = h.api.startHistory();
  try {
    h.firstWindow();
    await settle();
    assert.deepEqual(h.adds.map((add) => add.engine), [""]);
    h.useBrowser.setState((state) => ({ profiles: { ...state.profiles, later: { id: "later" } } }));
    h.admit("later");
    await settle();
    assert.deepEqual(h.adds.map((add) => add.engine), [""], "a load during the commit window doesn't import the same rows twice");
    assert.ok(JSON.parse(h.docs.get("history.json")).history.default, "the rows stay until the commit window passes");
    await h.advance(15_000);
    h.databases.get("").clear();
    stop();
    stop = h.api.startHistory();
    h.firstWindow();
    await settle();
    assert.deepEqual(h.adds.map((add) => add.engine), [""], "the cleared profile's legacy visits are never imported again");
    assert.equal(h.databases.get("").has("https://cleared.test/"), false);
    assert.deepEqual(Object.keys(JSON.parse(h.docs.get("history.json")).history), ["cold"]);
  } finally { stop(); }
});

test("an engine already shown before its legacy rows import is read again, not marked ready without them", async () => {
  const h = harness();
  h.useBrowser.setState((state) => ({ profiles: { ...state.profiles, frozen: { id: "frozen" } } }));
  h.docs.set("history.json", JSON.stringify({ history: { default: [row("https://late.test/")], cold: [row("https://cold.test/")], frozen: [row("https://frozen.test/")] } }));
  let failFirst = true;
  h.beforeAdd(async (engine) => { if (engine === "" && failFirst) { failFirst = false; throw new Error("busy"); } });
  const stop = h.api.startHistory();
  try {
    h.firstWindow();
    await settle();
    assert.ok(h.reads.includes(""), "the warm profile is shown after the failed pass");
    assert.notEqual(h.state().historyReady.default, true);
    h.admit("cold");
    await settle();
    assert.ok(h.databases.get("").has("https://late.test/"), "the second pass imports the warm profile's rows");
    assert.equal(h.state().historyReady.default, true);
    assert.deepEqual(h.state().history.default.map((entry) => entry.url), ["https://late.test/"], "its view includes the imported rows");
  } finally { stop(); }
});
