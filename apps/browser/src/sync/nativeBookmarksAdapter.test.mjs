import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
const { useBrowser } = await import("../store/browser.ts");
const { Clock, emptyScope, syncScope } = await import("@solara/sync");
const adapters = await import("./adapters.ts");
const stub = await import("../test-native/index.ts");

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
  }
  state() {
    return { state: "owned", generation: this.generation };
  }
  snapshot() {
    return { engine: this.engine, generation: this.generation, revision: String(this.revision), ready: this.ready, document: JSON.stringify(this.document) };
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
