import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("../store/browser.ts");
const { Clock, emptyScope, syncScope } = await import("@solara/sync");
const adapters = await import("./adapters.ts");
const stub = await import("../test-native/index.ts");
const solaracore = await import("@solara/solaracore");

const S = () => useBrowser.getState();
const DAY = 86_400_000;

class Folder {
  files = new Map();
  counter = 0;
  transport() {
    return {
      write: async (scope, payload) => { const id = `f${++this.counter}`; this.files.set(id, { scope, payload }); return id; },
      read: async (scope, known) => {
        const shown = [...this.files].filter(([, f]) => f.scope === scope);
        return { files: shown.filter(([id]) => !known.includes(id)).map(([id, f]) => ({ id, payload: f.payload })), pending: [], damaged: [], present: shown.map(([id]) => id) };
      },
      remove: async (_scope, ids) => ids.forEach((id) => this.files.delete(id)),
    };
  }
}

class Mac {
  constructor(id, folder) {
    this.id = id;
    this.folder = folder;
    stub.historyDbs.delete(id);
    S().hydrate({});
    useBrowser.setState({ history: {}, historyFloor: {}, historyReady: { default: true } });
    this.browser = S();
    this.scope = emptyScope();
    this.clock = new Clock(id);
  }
  with(fn) {
    stub.current.device = this.id;
    useBrowser.setState(this.browser, true);
    try { return fn(); } finally { this.browser = S(); }
  }
  async readChrome() {
    stub.current.device = this.id;
    const entries = await solaracore.queryHistory("");
    this.with(() => useBrowser.setState({ history: { default: entries.map((e) => ({ ...e, favicon: null, lastVisit: e.visitTimes.at(-1) })) }, historyReady: { default: true } }));
  }
  async sync(options = {}, now = undefined, read = true) {
    if (read) await this.readChrome();
    stub.current.device = this.id;
    useBrowser.setState(this.browser, true);
    try {
      return await syncScope({
        scope: "p", state: this.scope, transport: this.folder.transport(),
        adapters: [adapters.historyAdapter("default")],
        clock: this.clock, device: this.id, now,
        options: { expired: adapters.historyExpired, ...options },
      });
    } finally {
      this.browser = S();
    }
  }
  visit(url, at) { this.with(() => ((stub.current.device = this.id), stub.chromeVisit("", url, url, at))); }
  visits(url) { return stub.historyDbs.get(this.id)?.get("")?.get(url)?.visits ?? []; }
}

test("evicting synced URLs from the 5,000-entry view after an apply must not publish tombstones that delete them on other Macs", async () => {
  const folder = new Folder();
  const a = new Mac("A", folder);
  const b = new Mac("B", folder);
  const c = new Mac("C", folder);
  const base = Date.now() - 30 * DAY;
  const aUrls = Array.from({ length: 3000 }, (_, i) => `https://a${i}.example/`);
  aUrls.forEach((u, i) => a.visit(u, base + i * 1000));
  for (let i = 0; i < 3000; i++) b.visit(`https://b${i}.example/`, base + 10 * DAY + i * 1000);
  await a.sync();
  await c.sync();
  await c.sync();
  const cHadBefore = aUrls.filter((u) => c.visits(u).length).length;
  await b.sync();
  await a.sync();
  const viewAfterApply = a.with(() => S().history.default.length);
  const published = (await a.sync({}, undefined, false)).published;
  const tombstones = Object.entries(a.scope.records).filter(([k, r]) => k.startsWith("h:") && r.v === null).length;
  await c.sync();
  const cLost = aUrls.filter((u) => !c.visits(u).length).length;
  const aStill = aUrls.filter((u) => a.visits(u).length).length;
  assert.equal(cHadBefore, 3000, "C has all of A's URLs before B arrives");
  assert.equal(aStill, 3000, "A's own Chrome keeps every URL");
  assert.deepEqual({ tombstones, cLost }, { tombstones: 0, cLost: 0 }, `A's view after apply ${viewAfterApply}, A published ${published}`);
});

test("importing newer history that pushes synced URLs out of the 5,000-entry view must not publish tombstones", async () => {
  const folder = new Folder();
  const a = new Mac("A2", folder);
  const c = new Mac("C2", folder);
  const base = Date.now() - 30 * DAY;
  const aUrls = Array.from({ length: 3000 }, (_, i) => `https://s${i}.example/`);
  aUrls.forEach((u, i) => a.visit(u, base + i * 1000));
  await a.sync();
  await c.sync();
  await c.sync();
  const rows = Array.from({ length: 3000 }, (_, i) => ({ url: `https://imported${i}.example/`, title: "", visits: 1, lastVisit: base + 10 * DAY + i * 1000 }));
  a.with(() => S().adoptImportedHistory("default", rows));
  const published = (await a.sync({}, undefined, false)).published;
  const tombstones = Object.entries(a.scope.records).filter(([k, r]) => k.startsWith("h:") && r.v === null).length;
  await c.sync();
  const cLost = aUrls.filter((u) => !c.visits(u).length).length;
  assert.deepEqual({ tombstones, cLost }, { tombstones: 0, cLost: 0 }, `A published ${published}`);
});

test("importing through a profile that shares another's history raises the floor the owner's sync reads", async () => {
  const folder = new Folder();
  const a = new Mac("A3", folder);
  const c = new Mac("C3", folder);
  const base = Date.now() - 30 * DAY;
  const aUrls = Array.from({ length: 3000 }, (_, i) => `https://o${i}.example/`);
  aUrls.forEach((u, i) => a.visit(u, base + i * 1000));
  a.with(() => useBrowser.setState((s) => ({ profiles: { ...s.profiles, "p-alias-1": { ...s.profiles.default, id: "p-alias-1", name: "Alias", dataId: "default" } }, profileOrder: [...s.profileOrder, "p-alias-1"] })));
  await a.sync();
  await c.sync();
  await c.sync();
  const rows = Array.from({ length: 3000 }, (_, i) => ({ url: `https://via-alias${i}.example/`, title: "", visits: 1, lastVisit: base + 10 * DAY + i * 1000 }));
  a.with(() => S().adoptImportedHistory("p-alias-1", rows));
  const ownerView = a.with(() => S().history.default.length);
  const published = (await a.sync({}, undefined, false)).published;
  const tombstones = Object.entries(a.scope.records).filter(([k, r]) => k.startsWith("h:") && r.v === null).length;
  await c.sync();
  const cLost = aUrls.filter((u) => !c.visits(u).length).length;
  assert.deepEqual({ tombstones, cLost }, { tombstones: 0, cLost: 0 }, `owner view ${ownerView}, A published ${published}`);
});

test("pointing a profile at another's data keeps the owner's history and floor", () => {
  S().hydrate({});
  const at = Date.now() - DAY;
  const moved = "p-moved-1";
  const entry = (url, lastVisit) => ({ url, title: "", favicon: null, visits: 1, lastVisit, visitTimes: [lastVisit] });
  useBrowser.setState((s) => ({
    profiles: { ...s.profiles, [moved]: { ...s.profiles.default, id: moved, name: "Moved" } },
    profileOrder: [moved, ...s.profileOrder.filter((id) => id !== moved)],
    history: { default: [entry("https://u.example/", at)], [moved]: [entry("https://other.example/", at - 100)] },
    historyFloor: { default: at - 1000, [moved]: at - 500 },
  }));
  S().updateProfile(moved, { dataId: "default" });
  assert.equal(S().profiles[moved].dataId, "default");
  assert.deepEqual(S().history.default.map((h) => h.url), ["https://u.example/"]);
  assert.deepEqual(S().history[moved].map((h) => h.url), ["https://u.example/"]);
  assert.equal(S().historyFloor.default, at - 1000);
});

for (const destination of [undefined, -Infinity]) test(`a profile joining data whose floor is ${destination} brings no floor of its own`, () => {
  S().hydrate({});
  const at = Date.now() - DAY;
  const joining = "p-joining-1";
  const entry = (url, lastVisit) => ({ url, title: "", favicon: null, visits: 1, lastVisit, visitTimes: [lastVisit] });
  useBrowser.setState((s) => ({
    profiles: { ...s.profiles, [joining]: { ...s.profiles.default, id: joining, name: "Joining" } },
    profileOrder: [...s.profileOrder, joining],
    history: { default: [entry("https://u.example/", at)], [joining]: [entry("https://other.example/", at - 100)] },
    historyFloor: { ...(destination === undefined ? {} : { default: destination }), [joining]: at - 500 },
  }));
  S().updateProfile(joining, { dataId: "default" });
  assert.deepEqual(S().history.default.map((h) => h.url), ["https://u.example/"]);
  assert.equal(S().historyFloor.default ?? -Infinity, -Infinity);
  assert.equal(S().historyFloor[joining] ?? -Infinity, -Infinity);
});
