import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
let engineFolder;
let holdEnginePull = false;
globalThis.acTestNativeModules = {
  SolaraSyncAdapter: {
    deviceName: () => "Test Mac",
    unlock: async () => true,
    forget: async () => {},
    chainStatus: async () => "ok",
    write: async (_folder, scope, payload) => engineFolder.transport().write(scope, payload),
    read: async (_folder, scope, known) => {
      const listing = await engineFolder.transport().read(scope, known);
      if (holdEnginePull && scope.startsWith("p:")) listing.pending = ["waiting"];
      return listing;
    },
    remove: async (_folder, scope, ids) => engineFolder.transport().remove(scope, ids),
    sealLocal: async (text) => `sealed:${text}`,
    openLocal: async (sealed) => sealed.startsWith("sealed:") ? sealed.slice(7) : null,
    readPasswords: async () => null,
  },
};
const { useBrowser } = await import("../store/browser.ts");
const { Clock, canonical, emptyScope, syncScope } = await import("@solara/sync");
const adapters = await import("./adapters.ts");
const stub = await import("../test-native/index.ts");

const { bookmarkUuidFor } = await import("../store/bookmarks.ts");

const S = () => useBrowser.getState();

class Folder {
  files = new Map();
  counter = 0;
  transport() {
    return {
      write: async (scope, payload) => {
        const id = `f${++this.counter}`;
        this.files.set(id, { scope, payload });
        return id;
      },
      read: async (scope, known) => {
        const shown = [...this.files].filter(([, f]) => f.scope === scope);
        return { files: shown.filter(([id]) => !known.includes(id)).map(([id, f]) => ({ id, payload: f.payload })), pending: [], damaged: [], present: shown.map(([id]) => id) };
      },
      remove: async (_scope, ids) => ids.forEach((id) => this.files.delete(id)),
    };
  }
}

const folderNode = (id, title, children = []) => ({ kind: "folder", id, parentId: null, title, children, addedAt: 0 });
const emptyDocument = () => ({
  nodes: { "bar@default": folderNode("bar@default", "Bookmarks Bar"), "other@default": folderNode("other@default", "Other Bookmarks") },
  roots: { default: { bar: "bar@default", other: "other@default" } },
});

class FakeOwner {
  constructor(document = emptyDocument()) {
    this.engine = "";
    this.generation = "1";
    this.revision = 1;
    this.ready = true;
    this.document = document;
    this.replaced = [];
    this.failNext = null;
    this.facts = {};
    this.lastSeen = {};
    this.links = {};
    this.seenByLink = {};
    this.afterReplacement = null;
    this.seq = 0n;
    this.acks = [];
    this.failAck = false;
  }
  state() {
    return { state: "owned", generation: this.generation };
  }
  snapshot() {
    return { engine: this.engine, generation: this.generation, revision: String(this.revision), ready: this.ready, document: JSON.stringify(this.document), facts: JSON.stringify(this.facts) };
  }
  edit(title, at) {
    const id = bookmarkUuidFor("k1");
    if (title === null) {
      delete this.document.nodes[id];
      this.document.nodes["bar@default"].children = [];
    } else {
      this.document.nodes[id] = { kind: "url", id, syncKey: "k1", parentId: "bar@default", title, url: "https://alpha.example/", favicon: null, addedAt: 1 };
      this.document.nodes["bar@default"].children = [id];
    }
    this.facts["bm:k1"] = { at, seq: String(++this.seq), after: this.lastSeen["bm:k1"] ?? null, link: this.links.default ?? "none" };
    this.revision++;
  }
  ackBookmarkFacts(profileId, engine, json, link = this.links[profileId] ?? "none") {
    if (link !== (this.links[profileId] ?? "none")) return false;
    if (engine !== this.engine) throw new Error("stale binding");
    const records = JSON.parse(json);
    this.acks.push({ profileId, records });
    if (this.failAck === "throw") throw new Error("checkpoint failed");
    if (this.failAck) return false;
    for (const { key, seq, mintedHLC } of records) {
      const fact = this.facts[key];
      if (fact && fact.link === link && BigInt(fact.seq) > BigInt(seq) && (!fact.after || fact.after < mintedHLC)) fact.after = mintedHLC;
    }
    this.observeBookmarkRecords(profileId, engine, JSON.stringify(records.map(({ key, mintedHLC }) => ({ key, hlc: mintedHLC }))));
    return this.clearBookmarkFacts(profileId, engine, json);
  }
  observeBookmarkRecords(_profileId, engine, json, link = this.links[_profileId] ?? "none") {
    if (link !== (this.links[_profileId] ?? "none")) return false;
    if (engine !== this.engine) throw new Error("stale binding");
    for (const { key, hlc } of JSON.parse(json)) if (!this.lastSeen[key] || this.lastSeen[key] < hlc) this.lastSeen[key] = hlc;
    return true;
  }
  clearBookmarkFacts(_profileId, engine, json) {
    if (engine !== this.engine) throw new Error("stale binding");
    for (const { key, seq } of JSON.parse(json)) if (this.facts[key] && BigInt(this.facts[key].seq) <= BigInt(seq)) delete this.facts[key];
    return true;
  }
  setBookmarkSyncLinks(json) {
    this.seenByLink[this.links.default ?? "none"] = this.lastSeen;
    this.links = JSON.parse(json);
    this.lastSeen = this.seenByLink[this.links.default ?? "none"] ?? {};
    return true;
  }
  replaceWithRecords(profileId, json, expected, engine, generation, requestId, recordsJSON, link) {
    if (link !== (this.links[profileId] ?? "none")) throw new Error("stale link");
    const hook = this.afterReplacement;
    this.afterReplacement = null;
    try {
      const result = this.replace(profileId, json, expected, engine, generation, requestId);
      this.observeBookmarkRecords(profileId, engine, recordsJSON, link);
      hook?.();
      return result;
    } finally {
      this.afterReplacement = hook;
    }
  }
  replace(profileId, json, expected, engine, generation, requestId) {
    this.replaced.push({ profileId, expected, engine, generation, requestId });
    if (this.failNext) {
      const error = this.failNext;
      this.failNext = null;
      throw error;
    }
    if (engine !== this.engine || generation !== this.generation) throw new Error("stale binding");
    if (expected !== String(this.revision)) throw new Error("stale revision");
    this.document = JSON.parse(json);
    this.revision += 1;
    this.afterReplacement?.();
    return { revision: String(this.revision) };
  }
}

afterEach(() => {
  delete globalThis.acTestBookmarkWriter;
});

async function publishFromALegacyMac(folder, titles) {
  stub.current.device = "legacy";
  useBrowser.setState({ bookmarks: { nodes: {}, roots: {} } });
  S().hydrate({});
  useBrowser.setState({ bookmarksReady: { default: true } });
  const bar = S().bookmarks.roots.default?.bar;
  for (const title of titles) S().addBookmark({ profileId: "default", title, url: `https://${title.toLowerCase()}.example/`, ...(bar ? { parentId: bar } : {}) });
  await syncScope({ scope: "p", state: emptyScope(), transport: folder.transport(), adapters: [adapters.bookmarksAdapter("default")], clock: new Clock("legacy"), device: "legacy" });
}

async function syncOwned(folder, state, clock) {
  stub.current.device = "native";
  return syncScope({ scope: "p", state, transport: folder.transport(), adapters: [adapters.bookmarksAdapter("default")], clock, device: "native" });
}

const titlesIn = (document) => Object.values(document.nodes).filter((node) => node.kind === "url").map((node) => node.title).sort();
const bmKeys = (record) => Object.keys(record).filter((key) => key.startsWith("bm:"));

test("an owned apply hands the folder's bookmarks to the native writer with the snapshot's revision and binding, and leaves the JS store alone", async () => {
  const folder = new Folder();
  await publishFromALegacyMac(folder, ["Alpha", "Beta"]);
  S().hydrate({});
  useBrowser.setState({ bookmarksReady: { default: true } });
  const before = JSON.stringify(S().bookmarks);
  const owner = (globalThis.acTestBookmarkWriter = new FakeOwner());
  const state = emptyScope();
  await syncOwned(folder, state, new Clock("native"));
  assert.deepEqual(titlesIn(owner.document), ["Alpha", "Beta"]);
  assert.deepEqual(owner.replaced.map(({ expected, engine, generation }) => ({ expected, engine, generation })), [{ expected: "1", engine: "", generation: "1" }]);
  assert.equal(JSON.stringify(S().bookmarks), before, "the JS store is not a writer under native ownership");
  assert.equal(bmKeys(state.base).length, 2);
  assert.deepEqual(state.unapplied.filter((key) => key.startsWith("bm:")), []);
});

test("a refused native replacement leaves every bm: key unapplied and the base unchanged, and the next cycle applies them", async () => {
  const folder = new Folder();
  await publishFromALegacyMac(folder, ["Alpha", "Beta"]);
  const owner = (globalThis.acTestBookmarkWriter = new FakeOwner());
  owner.failNext = new Error("journal write failed");
  const state = emptyScope();
  const clock = new Clock("native");
  await syncOwned(folder, state, clock);
  assert.deepEqual(bmKeys(state.base), [], "no bm: key reaches the base before the journal accepts it");
  assert.equal(state.unapplied.filter((key) => key.startsWith("bm:")).length, 2, "every bm: key waits");
  assert.deepEqual(titlesIn(owner.document), []);
  await syncOwned(folder, state, clock);
  assert.deepEqual(titlesIn(owner.document), ["Alpha", "Beta"]);
  assert.equal(bmKeys(state.base).length, 2);
  assert.deepEqual(state.unapplied.filter((key) => key.startsWith("bm:")), []);
});

test("an owner change between the cycle's start and its apply refuses the old binding without writing", async () => {
  const owner = (globalThis.acTestBookmarkWriter = new FakeOwner());
  const adapter = adapters.bookmarksAdapter("default");
  owner.generation = "2";
  const visible = new Map([["bm:k1", { k: "u", p: "bar", t: "Alpha", u: "https://alpha.example/", a: 1, pos: "a" }]]);
  assert.throws(() => adapter.apply(visible, new Set(visible.keys()), () => undefined, { known: () => true, now: 0, horizon: 0, joined: true }), /changed/);
  assert.throws(() => adapter.extract(() => undefined), /changed/);
  assert.deepEqual(owner.replaced, []);
  owner.generation = "1";
  owner.engine = "Profile 2";
  assert.throws(() => adapter.apply(visible, new Set(visible.keys()), () => undefined, { known: () => true, now: 0, horizon: 0, joined: true }), /changed/);
  assert.deepEqual(owner.replaced, []);
});

test("an owner that is not ready yet neither publishes nor applies", () => {
  const owner = (globalThis.acTestBookmarkWriter = new FakeOwner());
  owner.ready = false;
  const adapter = adapters.bookmarksAdapter("default");
  assert.equal(adapter.extract(() => undefined), null);
  const visible = new Map([["bm:k1", { k: "u", p: "bar", t: "Alpha", u: "https://alpha.example/", a: 1, pos: "a" }]]);
  assert.equal(adapter.apply(visible, new Set(visible.keys()), () => undefined, { known: () => true, now: 0, horizon: 0, joined: true }), false);
  assert.deepEqual(owner.replaced, []);
});

test("owned extract reads the native document, and a document without its roots is not ready rather than empty", () => {
  S().hydrate({});
  useBrowser.setState({ bookmarksReady: { default: true } });
  S().addBookmark({ profileId: "default", title: "Only in JS", url: "https://js.example/" });
  const document = emptyDocument();
  document.nodes.n1 = { kind: "url", id: "n1", parentId: "bar@default", title: "Native", url: "https://native.example/", favicon: null, addedAt: 5 };
  document.nodes["bar@default"].children = ["n1"];
  const owner = (globalThis.acTestBookmarkWriter = new FakeOwner(document));
  const values = [...adapters.bookmarksAdapter("default").extract(() => undefined).values.values()];
  assert.deepEqual(values.map((value) => value.t), ["Native"]);
  owner.document = { nodes: {}, roots: {} };
  assert.equal(adapters.bookmarksAdapter("default").extract(() => undefined), null);
});

test("without a native owner the adapter stays the JS writer", async () => {
  S().hydrate({});
  useBrowser.setState({ bookmarksReady: { default: true } });
  const adapter = adapters.bookmarksAdapter("default");
  const visible = new Map([["bm:k1", { k: "u", p: "bar", t: "Alpha", u: "https://alpha.example/", a: 1, pos: "a" }]]);
  adapter.apply(visible, new Set(visible.keys()), () => undefined, { known: () => true, now: 0, horizon: 0, joined: true });
  const bar = S().bookmarks.roots.default.bar;
  assert.deepEqual(S().bookmarks.nodes[bar].children.map((id) => S().bookmarks.nodes[id].title), ["Alpha"]);
});

const h = (at, device = "native", counter = 0) => `${at.toString(36).padStart(9, "0")}.${counter.toString(36).padStart(4, "0")}.${device}`;
const value = (title) => ({ k: "u", p: "bar", t: title, u: "https://alpha.example/", a: 1, pos: "a" });
const linkedOwner = () => {
  const owner = (globalThis.acTestBookmarkWriter = new FakeOwner());
  owner.setBookmarkSyncLinks(JSON.stringify({ default: "chain" }));
  return owner;
};
const ownedAdapter = (link = () => "chain") => adapters.bookmarksAdapter("default", { device: "native", link });
const agreedState = (title = "Base", at = 10) => ({
  ...emptyScope(),
  joined: true,
  records: { "bm:k1": { h: h(at, "remote"), v: value(title), o: ["remote", 1] } },
  base: { "bm:k1": canonical(value(title)) },
});
const runFacts = (owner, state, folder = new Folder(), adapter = ownedAdapter(), options) =>
  syncScope({ scope: "p", state, transport: folder.transport(), adapters: [adapter], clock: new Clock("native", null, () => 1000), device: "native", now: () => 1000, options });

test("recoveredBookmarkEditKeepsOriginalSyncOrder", async () => {
  const owner = linkedOwner();
  owner.edit("Recovered", 100);
  const checkpoint = JSON.stringify({ document: owner.document, facts: owner.facts, seq: String(owner.seq) });
  const recovered = new FakeOwner();
  Object.assign(recovered, JSON.parse(checkpoint));
  recovered.seq = BigInt(recovered.seq);
  recovered.links = { default: "chain" };
  globalThis.acTestBookmarkWriter = recovered;
  const state = agreedState();
  await syncScope({ scope: "p", state, transport: new Folder().transport(), adapters: [ownedAdapter()], clock: new Clock("native", null, () => 50), device: "native", now: () => 50 });
  assert.equal(state.records["bm:k1"].h, h(100));
  assert.equal(state.records["bm:k1"].v.t, "Recovered");
  assert.deepEqual(recovered.facts, {});
  assert.deepEqual(recovered.acks[0].records, [{ key: "bm:k1", seq: "1", mintedHLC: h(100) }]);
});

test("recoveredDeleteKeepsStampWithoutNode", async () => {
  const owner = linkedOwner();
  owner.edit(null, 100);
  const state = agreedState();
  await runFacts(owner, state);
  assert.equal(state.records["bm:k1"].v, null);
  assert.equal(state.records["bm:k1"].h, h(100));
  assert.deepEqual(owner.facts, {});
});

test("sameMillisecondEditStillPublishes", async () => {
  const owner = linkedOwner();
  const state = agreedState();
  await ownedAdapter().apply(new Map([["bm:k1", value("Base")]]), new Set(["bm:k1"]), () => undefined, { known: () => true, stamp: () => h(100, "remote", 7), now: 100, horizon: 0, joined: true });
  owner.edit("Same ms", 100);
  state.records["bm:k1"].h = h(100, "remote", 7);
  await runFacts(owner, state);
  assert.equal(state.records["bm:k1"].v.t, "Same ms");
  assert.equal(state.records["bm:k1"].h, h(100, "native", 8));
  owner.edit("Clock stepped back", 90);
  await runFacts(owner, state);
  assert.equal(state.records["bm:k1"].v.t, "Clock stepped back");
  assert.equal(state.records["bm:k1"].h, h(100, "native", 9));
});

test("newerLocalEditOutlivesOlderRemote", async () => {
  const owner = linkedOwner();
  owner.edit("Local", 200);
  const state = agreedState("Remote", 100);
  state.base["bm:k1"] = canonical(value("Base"));
  state.unapplied = ["bm:k1"];
  await runFacts(owner, state);
  assert.equal(state.records["bm:k1"].v.t, "Local");
  assert.equal(state.records["bm:k1"].h, h(200));
  assert.deepEqual(titlesIn(owner.document), ["Local"]);
});

test("olderLocalEditIsAckedAsLost", async () => {
  for (const title of ["Local", null]) {
    const owner = linkedOwner();
    owner.edit(title, 100);
    const state = agreedState("Remote", 200);
    state.base["bm:k1"] = canonical(value("Base"));
    owner.failNext = new Error("replacement refused");
    const folder = new Folder();
    await runFacts(owner, state, folder);
    assert.equal(state.records["bm:k1"].v.t, "Remote");
    assert.deepEqual(titlesIn(owner.document), title === null ? [] : ["Local"]);
    assert.ok(state.unapplied.includes("bm:k1"));
    await runFacts(owner, state, folder);
    assert.equal(state.records["bm:k1"].v.t, "Remote");
    assert.deepEqual(titlesIn(owner.document), ["Remote"]);
    assert.deepEqual(owner.facts, {});
    assert.equal(owner.lastSeen["bm:k1"], h(200, "remote"));
    assert.deepEqual(owner.acks, []);
    }
});

test("undoneEditLeavesNoFacts", async () => {
  const owner = linkedOwner();
  owner.edit("Changed", 100);
  owner.edit("Base", 110);
  const state = agreedState();
  const adapter = ownedAdapter();
  adapter.extract((key) => value("Base"), () => false, 1000, () => true, () => value("Base"), () => h(10, "remote"), () => false);
  assert.ok(owner.facts["bm:k1"], "a dry extraction keeps facts");
  let fail = true;
  await assert.rejects(runFacts(owner, state, new Folder(), adapter, { persist: async () => { if (fail) throw new Error("disk full"); } }), /disk full/);
  assert.ok(owner.facts["bm:k1"], "a failed commit keeps facts");
  fail = false;
  await runFacts(owner, state, new Folder(), adapter, { persist: async () => {} });
  assert.deepEqual(owner.facts, {});
  assert.equal(state.records["bm:k1"].h, h(10, "remote"));
});

test("ackSeqNeverClearsANewerEditAcrossRemap", async () => {
  const owner = linkedOwner();
  owner.seq = 9007199254740992n;
  owner.edit("First", 100);
  const adapter = ownedAdapter();
  const state = agreedState();
  const extraction = adapter.extract((key) => value("Base"), () => false, 1000, () => true, () => value("Base"), () => h(10, "remote"), () => false);
  owner.edit("Second", 200);
  const applied = await adapter.apply(new Map([["bm:k1", value("First")], ["bm:k2", value("Unrelated remote")]]), new Set(["bm:k2"]), () => undefined, { known: () => true, stamp: () => h(150, "remote"), now: 1000, horizon: 0, joined: true });
  assert.equal(applied, false, "a whole-document apply must not overwrite an edit accepted after extraction");
  assert.deepEqual(titlesIn(owner.document), ["Second"]);
  owner.engine = "Profile 2";
  owner.generation = "2";
  extraction.published(new Set(["bm:k1"]), new Map([["bm:k1", h(100)]]));
  assert.equal(owner.lastSeen["bm:k1"], undefined, "a stale engine binding cannot acknowledge a remapped view");
  owner.engine = "";
  owner.generation = "3";
  extraction.published(new Set(["bm:k1"]), new Map([["bm:k1", h(100)]]));
  assert.equal(owner.facts["bm:k1"].seq, "9007199254740994");
  assert.equal(owner.facts["bm:k1"].after, h(100));
  await runFacts(owner, state);
  assert.equal(state.records["bm:k1"].v.t, "Second");
  assert.equal(state.records["bm:k1"].h, h(200));
  assert.deepEqual(owner.facts, {});
});

test("syncOffEditPublishesWithOriginalTimeOnLink", async () => {
  const owner = linkedOwner();
  owner.setBookmarkSyncLinks(JSON.stringify({}));
  owner.edit("While off", 100);
  const state = agreedState();
  let link = null;
  const adapter = ownedAdapter(() => link);
  await runFacts(owner, state, new Folder(), adapter);
  assert.ok(owner.facts["bm:k1"]);
  assert.equal(state.records["bm:k1"].v.t, "Base");
  link = "chain";
  owner.setBookmarkSyncLinks(JSON.stringify({ default: link }));
  await runFacts(owner, state, new Folder(), ownedAdapter(() => link));
  assert.equal(state.records["bm:k1"].v.t, "While off");
  assert.equal(state.records["bm:k1"].h, h(100));
  assert.deepEqual(owner.facts, {});
});

test("offLinkEqualOwnStampConvergesAndSettles", async () => {
  for (const title of ["Second", null]) for (const failure of [false, true, "throw"]) for (const offLink of [null, "other-chain"]) {
    let owner = linkedOwner();
    const folder = new Folder();
    const state = emptyScope();
    const firstValue = { ...value("First"), pos: "V" };
    owner.failAck = failure;
    owner.edit("First", 100);
    const first = await runFacts(owner, state, folder);
    assert.equal(first.published, 1);
    assert.equal(state.records["bm:k1"].h, h(100));
    assert.equal(state.base["bm:k1"], canonical(firstValue));
    assert.equal(owner.acks.length, 1);
    assert.deepEqual(owner.acks[0].records, [{ key: "bm:k1", seq: "1", mintedHLC: h(100) }]);
    assert.equal(owner.facts["bm:k1"]?.seq, failure ? "1" : undefined);

    const peer = emptyScope();
    let peerValues = new Map();
    const peerAdapter = {
      prefix: "bm:",
      adoptRemoteOnJoin: true,
      extract: () => ({ values: peerValues }),
      apply: (visible) => { peerValues = new Map(visible); },
    };
    const peerClock = new Clock("peer", null, () => 1000);
    const syncPeer = () => syncScope({ scope: "p", state: peer, transport: folder.transport(), adapters: [peerAdapter], clock: peerClock, device: "peer", now: () => 1000 });
    await syncPeer();
    assert.deepEqual(peerValues.get("bm:k1"), firstValue);
    const publishedFiles = [...folder.files];

    owner.setBookmarkSyncLinks(JSON.stringify(offLink ? { default: offLink } : {}));
    if (offLink) owner.observeBookmarkRecords("default", owner.engine, JSON.stringify([{ key: "bm:k1", hlc: h(5000, "other-device") }]), offLink);
    owner.edit(title, 100);
    const pending = structuredClone(owner.facts["bm:k1"]);
    assert.deepEqual(pending, { at: 100, seq: "2", after: offLink ? h(5000, "other-device") : null, link: offLink ?? "none" });
    const checkpoint = JSON.stringify({ engine: owner.engine, generation: owner.generation, revision: owner.revision, document: owner.document, facts: owner.facts, seq: String(owner.seq), links: owner.links, lastSeen: owner.lastSeen, seenByLink: owner.seenByLink });
    owner = new FakeOwner();
    Object.assign(owner, JSON.parse(checkpoint));
    owner.seq = BigInt(owner.seq);
    globalThis.acTestBookmarkWriter = owner;
    assert.deepEqual(owner.facts["bm:k1"], pending);
    assert.deepEqual(titlesIn(owner.document), title === null ? [] : [title]);
    owner.setBookmarkSyncLinks(JSON.stringify({ default: "chain" }));

    owner.failNext = new Error("checkpoint refused");
    const refused = await runFacts(owner, state, folder, ownedAdapter(), { persist: async (batches) => assert.deepEqual(batches, []) });
    assert.equal(refused.published, 0);
    assert.ok(state.unapplied.includes("bm:k1"));
    assert.deepEqual(owner.facts["bm:k1"], pending);
    assert.deepEqual(titlesIn(owner.document), title === null ? [] : [title]);
    assert.equal(state.records["bm:k1"].h, h(100));
    assert.deepEqual(state.records["bm:k1"].v, firstValue);
    assert.equal(state.base["bm:k1"], canonical(firstValue));
    assert.deepEqual(owner.acks, []);
    assert.deepEqual([...folder.files], publishedFiles);

    const replaced = [];
    owner.afterReplacement = () => replaced.push({ titles: titlesIn(owner.document), fact: structuredClone(owner.facts["bm:k1"]) });
    for (let cycle = 0; cycle < 2; cycle++) {
      const result = await runFacts(owner, state, folder);
      assert.equal(result.published, 0);
      assert.equal((await syncPeer()).published, 0);
      assert.equal(state.records["bm:k1"].h, h(100));
      assert.deepEqual(state.records["bm:k1"].v, firstValue);
      assert.equal(state.base["bm:k1"], canonical(firstValue));
      assert.deepEqual(titlesIn(owner.document), ["First"]);
      assert.deepEqual(owner.facts, {});
      assert.equal(owner.lastSeen["bm:k1"], h(100));
      assert.deepEqual(peer.records["bm:k1"], state.records["bm:k1"]);
      assert.equal(peer.base["bm:k1"], state.base["bm:k1"]);
      assert.deepEqual(peerValues.get("bm:k1"), firstValue);
      assert.deepEqual(state.unapplied, []);
      assert.deepEqual(owner.acks, []);
      assert.deepEqual([...folder.files], publishedFiles);
    }
    assert.deepEqual(replaced, [{ titles: ["First"], fact: pending }]);
  }
});

test("failedAckKeepsDurableSlot", async () => {
  for (const failure of [true, "throw"]) {
    const owner = linkedOwner();
    owner.edit("Local", 100);
    owner.failAck = failure;
    const state = agreedState();
    const folder = new Folder();
    await runFacts(owner, state, folder);
    assert.equal(state.records["bm:k1"].h, h(100));
    assert.equal(owner.facts["bm:k1"].seq, "1");
    owner.failAck = false;
    await runFacts(owner, state, folder);
    assert.deepEqual(owner.facts, {});
    assert.equal(owner.lastSeen["bm:k1"], h(100));
    owner.edit("Next", 100);
    await runFacts(owner, state, folder);
    assert.equal(state.records["bm:k1"].v.t, "Next");
    assert.equal(state.records["bm:k1"].h, h(100, "native", 1));
  }
  const owner = linkedOwner();
  owner.edit("First", 100);
  owner.failAck = true;
  const state = agreedState();
  const folder = new Folder();
  await runFacts(owner, state, folder);
  owner.edit("Second before ack", 100);
  await runFacts(owner, state, folder);
  assert.equal(state.records["bm:k1"].v.t, "Second before ack");
  assert.equal(state.records["bm:k1"].h, h(100, "native", 1));
  assert.equal(state.base["bm:k1"], canonical(value("Second before ack")));
  assert.equal(owner.facts["bm:k1"].seq, "2", "a failed second ack retains the newer durable fact");
});

test("oldChainIntentLosesToNewerRemoteInNewLink", async () => {
  for (const at of [100, 300]) {
    S().hydrate({});
    stub.docs.clear();
    engineFolder = new Folder();
    holdEnginePull = true;
    const owner = linkedOwner();
    owner.links.default = "old-chain";
    owner.lastSeen["bm:k1"] = h(5000, "old-device");
    owner.edit("Old intent", at);
    await engineFolder.transport().write("p:linked", JSON.stringify({ v: 1, kind: "log", device: "remote", seq: 1, at: 200, ops: [{ k: "bm:k1", h: h(200, "remote"), v: value("New remote") }] }));
    stub.docs.set("sync.json", JSON.stringify({
      v: 1, enabled: true, folder: "/new-chain", deviceId: "native", clock: null,
      setupAt: 1, joining: false, lastSyncedAt: null,
      types: { bookmarks: true, history: false, tabs: false, pinned: false, passwords: false, extensions: false, settings: false },
      profiles: { default: { syncId: "linked", enabled: true } },
    }));
    const realTimeout = globalThis.setTimeout;
    const realClearTimeout = globalThis.clearTimeout;
    globalThis.setTimeout = () => 0;
    globalThis.clearTimeout = () => {};
    let engine;
    try {
      engine = await import(`./engine.ts?bookmark-facts-${at}`);
      engine.startSync();
      for (let i = 0; i < 20; i++) await new Promise((resolve) => setImmediate(resolve));
      await engine.syncNow();
      assert.deepEqual(titlesIn(owner.document), ["Old intent"], "a fresh scope waits for its pull");
      assert.ok(owner.facts["bm:k1"]);
      holdEnginePull = false;
      await engine.syncNow();
      assert.deepEqual(titlesIn(owner.document), at < 200 ? ["New remote"] : ["Old intent"]);
      assert.deepEqual(owner.facts, {});
      assert.equal(owner.links.default, engine.ledgerScopeOf("default"));
      const local = [...engineFolder.files.values()].flatMap(({ payload }) => {
        const file = JSON.parse(payload);
        return file.device === "native" ? file.ops ?? [] : [];
      }).filter((op) => op.k === "bm:k1");
      if (at < 200) assert.deepEqual(local, [], "old-chain intent must not overwrite the newer remote");
      else {
        assert.equal(local.length, 1, "a newer fact survives the fresh guard after pull");
        assert.equal(local[0].h, h(300));
        assert.equal(local[0].v.t, "Old intent");
      }
      engine.setProfileSynced("default", false);
      assert.equal(owner.links.default, undefined);
    } finally {
      if (engine) await engine.stopSync();
      holdEnginePull = false;
      globalThis.setTimeout = realTimeout;
      globalThis.clearTimeout = realClearTimeout;
    }
  }
});


test("repeatedFailedAcksOrderSameMillisecondAndBackwardEditsAfterScopeLoss", async () => {
  const owner = linkedOwner();
  const folder = new Folder();
  let state = agreedState();
  owner.failAck = true;
  owner.edit("First", 100);
  await runFacts(owner, state, folder);
  owner.edit("Second", 100);
  await runFacts(owner, state, folder);
  assert.equal(state.records["bm:k1"].h, h(100, "native", 1));
  assert.equal(state.records["bm:k1"].v.t, "Second");
  owner.edit("Third after clock rollback", 90);
  state = emptyScope();
  await runFacts(owner, state, folder);
  assert.equal(state.records["bm:k1"].h, h(100, "native", 2));
  assert.equal(state.records["bm:k1"].v.t, "Third after clock rollback");
  owner.failAck = false;
  owner.edit(null, 90);
  await runFacts(owner, state, folder);
  assert.equal(state.records["bm:k1"].h, h(100, "native", 3));
  assert.equal(state.records["bm:k1"].v, null);
  assert.deepEqual(owner.facts, {});
});

test("atomicReplacementObservesBeforeTheNextNativeEdit", async () => {
  const owner = linkedOwner();
  const adapter = ownedAdapter();
  const state = agreedState("Remote", 100);
  state.records["bm:k1"].h = h(100, "remote", 7);
  owner.afterReplacement = () => owner.edit("Edited immediately", 100);
  await adapter.apply(new Map([["bm:k1", value("Remote")]]), new Set(["bm:k1"]), () => undefined, { known: () => true, stamp: () => h(100, "remote", 7), now: 100, horizon: 0, joined: true });
  owner.afterReplacement = null;
  await runFacts(owner, state);
  assert.equal(state.records["bm:k1"].v.t, "Edited immediately");
  assert.equal(state.records["bm:k1"].h, h(100, "native", 8));
});

test("newLinkEditDoesNotInheritTheOldLinksFutureClock", async () => {
  const owner = linkedOwner();
  owner.lastSeen["bm:k1"] = h(5000, "old-device");
  owner.setBookmarkSyncLinks(JSON.stringify({ default: "new-chain" }));
  const adapter = ownedAdapter(() => "new-chain");
  await adapter.apply(new Map([["bm:k1", value("Remote")]]), new Set(["bm:k1"]), () => undefined, { known: () => true, stamp: () => h(200, "remote"), now: 200, horizon: 0, joined: true });
  owner.edit("New link edit", 200);
  const state = agreedState("Remote", 200);
  await runFacts(owner, state, new Folder(), adapter);
  assert.equal(state.records["bm:k1"].h, h(200, "native", 1));
  assert.equal(state.records["bm:k1"].v.t, "New link edit");
});

test("zeroPublicationLossSurvivesFailedReplacementAndRestart", async () => {
  for (const title of ["Local", null]) {
    let owner = linkedOwner();
    owner.edit(title, 100);
    const folder = new Folder();
    await folder.transport().write("p", JSON.stringify({ v: 1, kind: "log", device: "remote", seq: 1, at: 200, ops: [{ k: "bm:k1", h: h(200, "remote"), v: value("Remote") }] }));
    const state = agreedState("Remote", 200);
    state.base["bm:k1"] = canonical(value("Base"));
    owner.failNext = new Error("checkpoint refused");
    const result = await runFacts(owner, state, folder, ownedAdapter(), { persist: async (batches) => assert.deepEqual(batches, []) });
    assert.equal(result.published, 0);
    assert.ok(owner.facts["bm:k1"], "an empty successful journal flush cannot settle a refused replacement");
    const checkpoint = JSON.stringify({ document: owner.document, facts: owner.facts, seq: String(owner.seq), links: owner.links, lastSeen: owner.lastSeen });
    owner = new FakeOwner();
    Object.assign(owner, JSON.parse(checkpoint));
    owner.seq = BigInt(owner.seq);
    globalThis.acTestBookmarkWriter = owner;
    const recovered = emptyScope();
    const retry = await runFacts(owner, recovered, folder);
    assert.equal(retry.published, 0);
    assert.equal(recovered.records["bm:k1"].v.t, "Remote");
    assert.deepEqual(titlesIn(owner.document), ["Remote"]);
    assert.deepEqual(owner.facts, {});
  }
});

test("unchangedAgainstBaseStillWaitsForTheCurrentRecordToApply", async () => {
  const owner = linkedOwner();
  owner.edit("Changed", 90);
  owner.edit("Base", 100);
  const state = agreedState("Remote", 200);
  state.base["bm:k1"] = canonical(value("Base"));
  owner.failNext = new Error("replacement refused");
  await runFacts(owner, state);
  assert.ok(owner.facts["bm:k1"]);
  assert.deepEqual(titlesIn(owner.document), ["Base"]);
  await runFacts(owner, state);
  assert.deepEqual(titlesIn(owner.document), ["Remote"]);
  assert.deepEqual(owner.facts, {});
});


test("linkChangeRefusesAnOldScopesExtractionApplyAndAck", async () => {
  const owner = linkedOwner();
  owner.edit("Local", 100);
  let link = "chain";
  const adapter = ownedAdapter(() => link);
  const extraction = adapter.extract(() => value("Base"), () => false, 1000, () => true, () => value("Base"), () => h(10, "remote"), () => false);
  link = "new-chain";
  extraction.published(new Set(["bm:k1"]), new Map([["bm:k1", h(100)]]));
  assert.deepEqual(owner.acks, [], "even before native receives the map, the old scope cannot ack");
  assert.ok(owner.facts["bm:k1"]);
  owner.setBookmarkSyncLinks(JSON.stringify({ default: link }));
  const applied = await adapter.apply(new Map([["bm:k1", value("Old chain remote")]]), new Set(["bm:k1"]), () => undefined, { known: () => true, stamp: () => h(5000, "old-device"), now: 1000, horizon: 0, joined: true });
  assert.equal(applied, false);
  assert.deepEqual(owner.replaced, []);
  assert.deepEqual(titlesIn(owner.document), ["Local"]);
  assert.equal(owner.lastSeen["bm:k1"], undefined);
  assert.equal(adapter.extract(() => value("Base")), null);
});


test("pendingDeleteStillCompetesAfterTheScopeBaseIsLost", async () => {
  for (const at of [100, 300]) {
    const owner = linkedOwner();
    owner.edit(null, at);
    const folder = new Folder();
    await folder.transport().write("p", JSON.stringify({ v: 1, kind: "log", device: "remote", seq: 1, at: 200, ops: [{ k: "bm:k1", h: h(200, "remote"), v: value("Remote") }] }));
    const state = emptyScope();
    await runFacts(owner, state, folder);
    assert.equal(state.records["bm:k1"].h, at < 200 ? h(200, "remote") : h(300));
    assert.equal(state.records["bm:k1"].v?.t ?? null, at < 200 ? "Remote" : null);
    assert.deepEqual(titlesIn(owner.document), at < 200 ? ["Remote"] : []);
    assert.deepEqual(owner.facts, {});
  }
});


test("reorderSiblingFactsPublishOnlyTheRecordWhosePositionChanges", async () => {
  const owner = linkedOwner();
  const state = emptyScope();
  state.joined = true;
  for (const [index, id] of ["A", "B", "C"].entries()) {
    const bookmark = { ...value(id), pos: id };
    state.records[`bm:${id}`] = { h: h(10, "remote"), v: bookmark, o: ["remote", 1] };
    state.base[`bm:${id}`] = canonical(bookmark);
    owner.document.nodes[id] = { kind: "url", id, parentId: "bar@default", title: id, url: bookmark.u, favicon: null, addedAt: 1 };
    owner.facts[`bm:${id}`] = { at: 123, seq: String(index + 1), after: h(10, "remote"), link: "chain" };
  }
  owner.document.nodes["bar@default"].children = ["B", "C", "A"];
  owner.seq = 3n;
  owner.revision++;
  const result = await runFacts(owner, state);
  assert.equal(result.published, 1);
  assert.equal(state.records["bm:A"].v.pos, "b");
  assert.equal(state.records["bm:A"].h, h(123));
  for (const id of ["B", "C"]) {
    assert.equal(state.records[`bm:${id}`].v.pos, id);
    assert.equal(state.records[`bm:${id}`].h, h(10, "remote"));
  }
  assert.deepEqual(owner.acks.flatMap(({ records }) => records), [{ key: "bm:A", seq: "1", mintedHLC: h(123) }]);
  assert.deepEqual(owner.facts, {});
  assert.deepEqual(owner.document.nodes["bar@default"].children, ["B", "C", "A"]);
});
