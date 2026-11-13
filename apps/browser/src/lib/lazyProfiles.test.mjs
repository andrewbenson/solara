import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { test } from "node:test";
import { runInNewContext } from "node:vm";

function harness(inventory = [""]) {
  let state = {
    profiles: { default: { id: "default" }, work: { id: "work" }, play: { id: "play" }, alias: { id: "alias", dataId: "work" } },
    tabs: {}, windows: { w1: { profileId: "default", incognito: false } }, settings: { loadAllProfilesAtLaunch: false },
  };
  const subscribers = new Set();
  const pending = [];
  const events = new Set();
  const useBrowser = { getState: () => state, subscribe: (listener) => (subscribers.add(listener), () => subscribers.delete(listener)) };
  const context = { console, Set, Promise, useBrowser,
    ensureProfile: (engine) => new Promise((resolve) => pending.push({ engine, resolve })),
    loadedProfiles: async () => typeof inventory === "function" ? inventory() : inventory,
    onProfileLoaded: (listener) => (events.add(listener), { remove: () => events.delete(listener) }),
    internalPageOf: (url) => /^solara:\/\/(history|bookmarks|downloads)(?:[/?#]|$)/i.exec(url)?.[1] ?? null,
    tabEngine: (s, id) => s.tabs[id]?.engine ?? "chromium",
  };
  const source = stripTypeScriptTypes(readFileSync(new URL("./lazyProfiles.ts", import.meta.url), "utf8"))
    .replace(/^import .*;\n/gm, "").replace(/^export /gm, "");
  const policy = stripTypeScriptTypes(readFileSync(new URL("./profileLoading.ts", import.meta.url), "utf8")).replace(/^export /gm, "");
  const api = runInNewContext(`${policy}\n${source}\n({ startProfileLoading, engineProfileLoaded, onLoadedProfilesChanged${source.includes("function refreshLoadedProfiles") || source.includes("const refreshLoadedProfiles") ? ", refreshLoadedProfiles" : ""} });`, context);
  return { api, pending, events, state: () => state, update: (patch) => {
    const previous = state;
    state = { ...state, ...patch };
    for (const listener of [...subscribers]) listener(state, previous);
    return Promise.resolve();
  }, event: (profile) => { for (const listener of [...events]) listener({ profile }); } };
}
const tick = () => new Promise((resolve) => setImmediate(resolve));

test("cold startup and passive profile metadata only request selected window engines", async () => {
  const h = harness();
  const stop = h.api.startProfileLoading();
  try {
    await tick();
    assert.equal(h.api.engineProfileLoaded(""), true);
    assert.deepEqual(h.pending.map((request) => request.engine), []);
    await h.update({ profiles: { ...h.state().profiles, another: { id: "another" } } });
    await tick();
    assert.deepEqual(h.pending.map((request) => request.engine), []);
    await h.update({ windows: { w1: { profileId: "work", incognito: false } } });
    await h.update({ windows: { w1: { profileId: "work", incognito: false } } });
    assert.deepEqual(h.pending.map((request) => request.engine), ["work"]);
    h.pending[0].resolve(true);
    await tick();
    assert.equal(h.api.engineProfileLoaded("work"), true);
    await h.update({ windows: { w1: { profileId: "alias", incognito: false } } });
    assert.equal(h.pending.length, 1);
  } finally { stop(); }
});

test("eager setting admits distinct engines once and stays session-only", async () => {
  const h = harness();
  const stop = h.api.startProfileLoading();
  await tick();
  await h.update({ settings: { loadAllProfilesAtLaunch: true } });
  assert.deepEqual(h.pending.map((request) => request.engine).sort(), ["play", "work"]);
  for (const request of h.pending) request.resolve(true);
  await tick();
  await h.update({ settings: { loadAllProfilesAtLaunch: false } });
  assert.equal(h.api.engineProfileLoaded("work"), true);
  stop();
  assert.equal(h.api.engineProfileLoaded("work"), false);
});

test("stopped session ignores in-flight ensure and late engine events", async () => {
  const h = harness();
  const stop = h.api.startProfileLoading();
  await tick();
  await h.update({ windows: { w1: { profileId: "work", incognito: false } } });
  stop();
  h.pending[0].resolve(true);
  h.event("play");
  await tick();
  assert.equal(h.api.engineProfileLoaded("work"), false);
  assert.equal(h.api.engineProfileLoaded("play"), false);
});

test("deleted final owner cannot be re-admitted by delayed ensure completion", async () => {
  const h = harness();
  const stop = h.api.startProfileLoading();
  try {
    await tick();
    await h.update({ windows: { w1: { profileId: "play", incognito: false } } });
    await h.update({ profiles: Object.fromEntries(Object.entries(h.state().profiles).filter(([id]) => id !== "play")), windows: { w1: { profileId: "default", incognito: false } } });
    h.pending[0].resolve(true);
    await tick();
    assert.equal(h.api.engineProfileLoaded("play"), false);
  } finally { stop(); }
});


test("stale refresh completion after session stop cannot refill loaded profiles", async () => {
  let release;
  const held = new Promise((resolve) => { release = resolve; });
  let reads = 0;
  const h = harness(() => reads++ === 0 ? [""] : held);
  const stop = h.api.startProfileLoading();
  await tick();
  const refreshing = h.api.refreshLoadedProfiles();
  stop();
  release(["work"]);
  await refreshing;
  assert.equal(h.api.engineProfileLoaded("work"), false);
});

test("late native event cannot re-admit a deleted final engine owner", async () => {
  const h = harness();
  const stop = h.api.startProfileLoading();
  try {
    await tick();
    await h.update({ profiles: Object.fromEntries(Object.entries(h.state().profiles).filter(([id]) => id !== "play")) });
    h.event("play");
    assert.equal(h.api.engineProfileLoaded("play"), false);
  } finally { stop(); }
});


test("explicit background page intent admits its engine while saved inactive metadata stays cold", async () => {
  const h = harness();
  await h.update({ tabs: { saved: { profileId: "play", url: "https://saved.test/", navigation: null } } });
  const stop = h.api.startProfileLoading();
  try {
    await tick();
    assert.equal(h.pending.length, 0);
    await h.update({ tabs: { ...h.state().tabs, link: { profileId: "work", url: "https://background.test/", navigation: { url: "https://background.test/", seq: 1 } } } });
    assert.deepEqual(h.pending.map((request) => request.engine), ["work"]);
    await h.update({ tabs: { ...h.state().tabs, saved: { ...h.state().tabs.saved, title: "Metadata changed" } } });
    assert.equal(h.pending.length, 1);
  } finally { stop(); }
});

test("WebKit intents and app-only pages do not load Chromium profiles", async () => {
  const h = harness();
  const stop = h.api.startProfileLoading();
  try {
    await tick();
    await h.update({ tabs: {
      webkit: { profileId: "work", engine: "webkit", url: "https://webkit.test/", navigation: { url: "https://webkit.test/", seq: 1 } },
      internal: { profileId: "play", url: "solara://history", navigation: { url: "solara://history", seq: 1 } },
    } });
    assert.equal(h.pending.length, 0);
  } finally { stop(); }
});

test("existing background intent is not retried by metadata but a new navigation sequence is", async () => {
  const h = harness();
  const tab = { profileId: "work", url: "https://background.test/", navigation: { url: "https://background.test/", seq: 1 } };
  await h.update({ tabs: { live: tab } });
  const stop = h.api.startProfileLoading();
  try {
    await tick();
    assert.deepEqual(h.pending.map((request) => request.engine), ["work"]);
    h.pending[0].resolve(false);
    await tick();
    await h.update({ tabs: { live: { ...tab, title: "new title" } } });
    assert.equal(h.pending.length, 1);
    await h.update({ tabs: { live: { ...tab, navigation: { ...tab.navigation, seq: 2 } } } });
    assert.equal(h.pending.length, 2);
  } finally { stop(); }
});

test("new adopted Chromium page requests canonical engine without a navigation URL", async () => {
  const h = harness();
  const stop = h.api.startProfileLoading();
  try {
    await tick();
    await h.update({ tabs: { popup: { profileId: "alias", url: "", navigation: null, adoptId: "solaracore:7" } } });
    assert.deepEqual(h.pending.map((request) => request.engine), ["work"]);
    await h.update({ tabs: { ...h.state().tabs, unloaded: { profileId: "play", url: "https://sleep.test/", navigation: { url: "https://sleep.test/", seq: 1 }, unloaded: true } } });
    assert.equal(h.pending.length, 1);
  } finally { stop(); }
});


test("explicit background Chromium app URL loads its profile", async () => {
  const h = harness();
  const stop = h.api.startProfileLoading();
  try {
    await tick();
    await h.update({ tabs: { diagnostic: { profileId: "work", url: "solara://gpu", navigation: { url: "solara://gpu", seq: 1 } } } });
    assert.deepEqual(h.pending.map((request) => request.engine), ["work"]);
  } finally { stop(); }
});

test("a failed load is not retried on every tab commit, only after windows or profiles change", async () => {
  const h = harness();
  const stop = h.api.startProfileLoading();
  try {
    await tick();
    await h.update({ windows: { w1: { profileId: "work", incognito: false } } });
    assert.deepEqual(h.pending.map((request) => request.engine), ["work"]);
    h.pending[0].resolve(false);
    await tick();
    await h.update({ tabs: { t1: { profileId: "default", url: "https://a.test/", navigation: null } } });
    await h.update({ tabs: { t1: { profileId: "default", url: "https://b.test/", navigation: null } } });
    assert.equal(h.pending.length, 1);
    await h.update({ windows: { w1: { profileId: "work", incognito: false }, w2: { profileId: "default", incognito: false } } });
    assert.deepEqual(h.pending.map((request) => request.engine), ["work", "work"]);
  } finally { stop(); }
});
