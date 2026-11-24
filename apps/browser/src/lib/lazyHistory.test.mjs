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
  let beforeReply = async () => {};
  let clock = 0;
  const timers = new Set();
  const database = (engine) => {
    if (!databases.has(engine)) databases.set(engine, new Map());
    return databases.get(engine);
  };
  const useBrowser = { getState: () => state, setState: (patch) => {
    const previous = state;
    const next = typeof patch === "function" ? patch(state) : patch;
    if (Object.is(next, state)) return;
    state = { ...state, ...next };
    for (const listener of [...subscribers]) listener(state, previous);
  }, subscribe: (listener) => (subscribers.add(listener), () => subscribers.delete(listener)) };
  const context = { console, Date, Set, Map, Promise, queueMicrotask,
    clearTimeout: (timer) => { timers.delete(timer); },
    setTimeout: (fn, ms) => { const timer = { fn, at: clock + (ms ?? 0) }; timers.add(timer); return timer; },
    persistenceRefused: () => false, nativeSafeMode: () => false, useBrowser, MAX_HISTORY: 5000, MAX_VISIT_TIMES: 50,
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
    queryHistory: async (engine) => { reads.push(engine); const rows = [...database(engine).values()]; await beforeReply(engine); return rows; },
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
    beforeReply: (fn) => { beforeReply = fn; },
    emit: (change) => { for (const listener of [...historyListeners]) listener(change); },
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

test("rows adopted while a history read is in flight survive its older reply, and rows the engine dropped stay gone", async () => {
  const h = harness();
  h.databases.set("", new Map([
    ["https://kept.test/", { url: "https://kept.test/", title: "Kept", visits: 1, visitTimes: [100] }],
    ["https://dropped.test/", { url: "https://dropped.test/", title: "Dropped", visits: 1, visitTimes: [90] }],
  ]));
  const stop = h.api.startHistory();
  try {
    await settle();
    assert.deepEqual(Array.from(h.state().history.default, (e) => e.url), ["https://kept.test/", "https://dropped.test/"]);
    h.databases.get("").delete("https://dropped.test/");
    let release = () => {};
    h.beforeReply(() => new Promise((resolve) => { release = resolve; }));
    const reading = h.api.reloadHistory();
    await settle();
    h.useBrowser.setState((state) => ({ history: { ...state.history, default: [row("https://imported.test/"), ...state.history.default] } }));
    h.beforeReply(async () => {});
    release();
    await reading;
    await settle();
    assert.deepEqual(Array.from(h.state().history.default, (e) => e.url), ["https://imported.test/", "https://kept.test/"]);
  } finally { stop(); }
});

test("a row the user removes while a history read is in flight stays removed, even one adopted during the read", async () => {
  const h = harness();
  h.databases.set("", new Map([
    ["https://kept.test/", { url: "https://kept.test/", title: "Kept", visits: 1, visitTimes: [100] }],
    ["https://removed.test/", { url: "https://removed.test/", title: "Removed", visits: 1, visitTimes: [90] }],
  ]));
  const stop = h.api.startHistory();
  try {
    await settle();
    let release = () => {};
    h.beforeReply(() => new Promise((resolve) => { release = resolve; }));
    const reading = h.api.reloadHistory();
    await settle();
    h.useBrowser.setState((state) => ({ history: { ...state.history, default: [row("https://adopted-then-removed.test/"), ...state.history.default] } }));
    const gone = ["https://removed.test/", "https://adopted-then-removed.test/"];
    h.useBrowser.setState((state) => ({ history: { ...state.history, default: state.history.default.filter((e) => !gone.includes(e.url)) } }));
    h.databases.get("").delete("https://removed.test/");
    h.emit({ kind: "deleted", profile: "", urls: gone });
    await settle();
    h.beforeReply(async () => {});
    release();
    await reading;
    await settle();
    assert.deepEqual(Array.from(h.state().history.default, (e) => e.url), ["https://kept.test/"]);
  } finally { stop(); }
});

test("a row adopted during a history read that the engine deletes during that read stays deleted", async () => {
  const h = harness();
  h.databases.set("", new Map([["https://kept.test/", { url: "https://kept.test/", title: "Kept", visits: 1, visitTimes: [100] }]]));
  const stop = h.api.startHistory();
  try {
    await settle();
    let release = () => {};
    h.beforeReply(() => new Promise((resolve) => { release = resolve; }));
    const reading = h.api.reloadHistory();
    await settle();
    h.useBrowser.setState((state) => ({ history: { ...state.history, default: [row("https://cleared.test/"), ...state.history.default] } }));
    h.emit({ kind: "deleted", profile: "", urls: ["https://cleared.test/"] });
    await settle();
    h.beforeReply(async () => {});
    release();
    await reading;
    await settle();
    assert.deepEqual(Array.from(h.state().history.default, (e) => e.url), ["https://kept.test/"]);
  } finally { stop(); }
});

test("a row adopted during a history read keeps a rename the engine reports during that read", async () => {
  const h = harness();
  h.databases.set("", new Map([["https://kept.test/", { url: "https://kept.test/", title: "Kept", visits: 1, visitTimes: [100] }]]));
  const stop = h.api.startHistory();
  try {
    await settle();
    let release = () => {};
    h.beforeReply(() => new Promise((resolve) => { release = resolve; }));
    const reading = h.api.reloadHistory();
    await settle();
    h.useBrowser.setState((state) => ({ history: { ...state.history, default: [row("https://renamed.test/"), ...state.history.default] } }));
    h.emit({ kind: "modified", profile: "", rows: [{ url: "https://renamed.test/", title: "Renamed", visits: 4 }] });
    await settle();
    h.beforeReply(async () => {});
    release();
    await reading;
    await settle();
    const renamed = h.state().history.default.find((e) => e.url === "https://renamed.test/");
    assert.equal(renamed?.title, "Renamed");
    assert.equal(renamed?.visits, 4);
  } finally { stop(); }
});

test("rows a private profile gains while a history read is in flight never join the regular profile", async () => {
  const h = harness();
  h.databases.set("", new Map([["https://kept.test/", { url: "https://kept.test/", title: "Kept", visits: 1, visitTimes: [100] }]]));
  h.useBrowser.setState((state) => ({ profiles: { ...state.profiles, "incognito:w@default": { id: "incognito:w@default", dataId: "default" } } }));
  const stop = h.api.startHistory();
  try {
    await settle();
    let release = () => {};
    h.beforeReply(() => new Promise((resolve) => { release = resolve; }));
    const reading = h.api.reloadHistory();
    await settle();
    h.useBrowser.setState((state) => ({ history: { ...state.history, "incognito:w@default": [row("https://private.test/")] } }));
    h.beforeReply(async () => {});
    release();
    await reading;
    await settle();
    assert.deepEqual(Array.from(h.state().history.default, (e) => e.url), ["https://kept.test/"]);
    assert.deepEqual(Array.from(h.state().history["incognito:w@default"], (e) => e.url), ["https://private.test/"]);
  } finally { stop(); }
});

test("reading unchanged history preserves the view and does not notify store listeners", async () => {
  const h = harness();
  h.databases.set("", new Map([["https://warm.test/", { url: "https://warm.test/", title: "Warm", visits: 2, visitTimes: [100, 200] }]]));
  const stop = h.api.startHistory();
  try {
    await settle();
    const before = h.state().history;
    let notifications = 0;
    const off = h.useBrowser.subscribe(() => { notifications++; });
    try {
      await h.api.reloadHistory();
      await settle();
      assert.equal(h.state().history, before);
      assert.equal(notifications, 0);
      h.databases.get("").set("https://warm.test/", { url: "https://warm.test/", title: "Renamed", visits: 3, visitTimes: [100, 200, 300] });
      await h.api.reloadHistory();
      await settle();
      assert.equal(notifications, 1);
      assert.equal(h.state().history.default[0].title, "Renamed");
      assert.deepEqual([...h.state().history.default[0].visitTimes], [100, 200, 300]);
      h.databases.get("").clear();
      await h.api.reloadHistory();
      await settle();
      assert.equal(notifications, 2);
      assert.equal(h.state().history.default.length, 0);
    } finally { off(); }
  } finally { stop(); }
});

test("an unchanged history read still initializes shared aliases and updates readiness and retention floor", async () => {
  const h = harness();
  h.databases.set("", new Map([["https://warm.test/", { url: "https://warm.test/", title: "Warm", visits: 1, visitTimes: [100] }]]));
  const stop = h.api.startHistory();
  try {
    await settle();
    h.useBrowser.setState((state) => ({ profiles: { ...state.profiles, alias: { id: "alias", dataId: "default" } } }));
    await settle();
    assert.equal(h.state().history.alias, h.state().history.default);
    assert.equal(h.state().history.alias[0].title, "Warm");
    assert.equal(h.state().historyReady.alias, true);
    h.useBrowser.setState({ historyReady: { default: false, alias: false } });
    const history = h.state().history;
    const floor = h.state().historyFloor;
    let notifications = 0;
    const off = h.useBrowser.subscribe(() => { notifications++; });
    try {
      await h.api.reloadHistory();
      await settle();
      assert.equal(h.state().history, history);
      assert.equal(h.state().historyReady.default, true);
      assert.equal(h.state().historyReady.alias, true);
      assert.equal(h.state().historyFloor, floor);
      assert.equal(notifications, 1);
      const ready = h.state().historyReady;
      h.useBrowser.setState({ historyFloor: { default: 123, alias: 123 } });
      notifications = 0;
      await h.api.reloadHistory();
      await settle();
      assert.equal(h.state().history, history);
      assert.equal(h.state().historyReady, ready);
      assert.equal(h.state().historyFloor.default, -Infinity);
      assert.equal(h.state().historyFloor.alias, -Infinity);
      assert.equal(notifications, 1);
      await h.api.reloadHistory();
      await settle();
      assert.equal(notifications, 1);
    } finally { off(); }
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

test("rows adopted during a read that a queued visit pushes out of the view stay at or below the floor", async () => {
  const h = harness();
  const stop = h.api.startHistory();
  try {
    await settle();
    let release = () => {};
    h.beforeReply(() => new Promise((resolve) => { release = resolve; }));
    const reading = h.api.reloadHistory();
    await settle();
    const adopted = Array.from({ length: 5000 }, (_, i) => ({ url: `https://adopted${i}.test/`, title: "", visits: 1, lastVisit: 1000 + i, visitTimes: [1000 + i] })).reverse();
    h.useBrowser.setState((state) => ({ history: { ...state.history, default: adopted }, historyFloor: { ...state.historyFloor, default: 1000 } }));
    h.emit({ kind: "visit", profile: "", url: "https://x.test/", title: "", visits: 1, at: 1_000_000 });
    h.emit({ kind: "deleted", profile: "", all: false, urls: ["https://x.test/"] });
    await settle();
    h.beforeReply(async () => {});
    release();
    await reading;
    await settle();
    const shown = new Set(h.state().history.default.map((e) => e.url));
    const floor = h.state().historyFloor.default ?? -Infinity;
    assert.equal(shown.size, 4999);
    assert.deepEqual(adopted.filter((e) => !shown.has(e.url) && e.lastVisit > floor).map((e) => e.url), []);
  } finally { stop(); }
});
