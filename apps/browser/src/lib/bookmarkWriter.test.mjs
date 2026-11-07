import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";
const { useBrowser } = await import("../store/browser.ts");
const { bookmarkWriter, projectNativeBookmarks, submitBookmarks } = await import("./bookmarkWriter.ts");

const S = () => useBrowser.getState();
const folder = (id, title, children = []) => ({ kind: "folder", id, parentId: null, title, children, addedAt: 0 });
const document = (extra = {}) => ({
  nodes: { "bar@native": folder("bar@native", "Bookmarks Bar", Object.keys(extra)), "other@native": folder("other@native", "Other Bookmarks"), ...extra },
  roots: { p: { bar: "bar@native", other: "other@native" } },
});

class FakeOwner {
  constructor() {
    this.engine = "native";
    this.generation = "1";
    this.revision = 10;
    this.document = document();
    this.submitted = [];
    this.refuse = null;
    this.ids = 0;
  }
  state() {
    return { state: "owned", generation: this.generation };
  }
  snapshot() {
    return { engine: this.engine, generation: this.generation, revision: String(this.revision), ready: true, document: JSON.stringify(this.document) };
  }
  async submit(profileId, mutationsJSON, engine, generation, requestId) {
    const mutations = JSON.parse(mutationsJSON);
    this.submitted.push({ profileId, mutations, engine, generation, requestId });
    if (this.refuse) throw this.refuse;
    if (engine !== this.engine || generation !== this.generation) throw new Error("the bookmark owner changed since this binding was taken");
    const results = mutations.map((mutation) => {
      if (mutation.method !== "addBookmark") return null;
      const id = `n${++this.ids}`;
      this.document.nodes[id] = { kind: "url", id, parentId: "bar@native", title: mutation.args[0].title, url: mutation.args[0].url, favicon: null, addedAt: 1 };
      this.document.nodes["bar@native"].children.push(id);
      return id;
    });
    this.revision += 1;
    return { engine: this.engine, revision: String(this.revision), results: JSON.stringify(results), document: JSON.stringify(this.document) };
  }
}

beforeEach(() => {
  useBrowser.setState({ bookmarks: { nodes: {}, roots: {} } });
  S().hydrate({});
  useBrowser.setState({ bookmarksReady: { default: true } });
});

afterEach(() => {
  delete globalThis.acTestBookmarkWriter;
});

test("without a native owner the facade runs the JS reducers and resolves their results", async () => {
  const id = await bookmarkWriter.addBookmark({ profileId: "default", title: "Alpha", url: "https://alpha.example/" });
  assert.equal(S().bookmarks.nodes[id].title, "Alpha");
  await bookmarkWriter.updateBookmark("default", id, { title: "Renamed" });
  assert.equal(S().bookmarks.nodes[id].title, "Renamed");
  const removed = await bookmarkWriter.removeBookmarks("default", [id]);
  assert.equal(S().bookmarks.nodes[id], undefined);
  assert.deepEqual(removed.nodes.map((node) => node.id), [id]);
  await bookmarkWriter.restoreBookmarks("default", removed);
  assert.equal(S().bookmarks.nodes[id].title, "Renamed");
});

test("under a native owner an edit is submitted with the snapshot's binding, its id comes from the receipt, and the store projects the accepted document", async () => {
  const owner = (globalThis.acTestBookmarkWriter = new FakeOwner());
  const id = await bookmarkWriter.addBookmark({ profileId: "p", title: "Native", url: "https://native.example/" });
  assert.equal(id, "n1");
  assert.deepEqual(owner.submitted.map(({ engine, generation }) => ({ engine, generation })), [{ engine: "native", generation: "1" }]);
  assert.equal(owner.submitted[0].mutations[0].method, "addBookmark");
  assert.equal(S().bookmarks.nodes.n1?.title, "Native");
  assert.deepEqual(S().bookmarks.roots.p, { bar: "bar@native", other: "other@native" });
  assert.ok(S().bookmarks.roots.default, "another engine's bookmarks stay in the store");
});

test("a refused native edit rejects, changes nothing in the store and never falls back to the JS reducers", async () => {
  const owner = (globalThis.acTestBookmarkWriter = new FakeOwner());
  owner.refuse = new Error("journal write failed");
  const before = JSON.stringify(S().bookmarks);
  await assert.rejects(bookmarkWriter.addBookmark({ profileId: "default", title: "Lost", url: "https://lost.example/" }), /journal write failed/);
  assert.equal(JSON.stringify(S().bookmarks), before);
});

test("the binding is taken when the edit starts, so an owner change before it lands is refused", async () => {
  const owner = (globalThis.acTestBookmarkWriter = new FakeOwner());
  const realSubmit = owner.submit.bind(owner);
  owner.submit = (...args) => {
    owner.generation = "2";
    return realSubmit(...args);
  };
  await assert.rejects(bookmarkWriter.addBookmark({ profileId: "p", title: "Late", url: "https://late.example/" }), /changed/);
  assert.equal(S().bookmarks.nodes.n1, undefined);
});

test("an older receipt never rolls the projection back over a newer one", () => {
  const newer = document({ a: { kind: "url", id: "a", parentId: "bar@native", title: "Newer", url: "https://a.example/", favicon: null, addedAt: 1 } });
  const older = document({ a: { kind: "url", id: "a", parentId: "bar@native", title: "Older", url: "https://a.example/", favicon: null, addedAt: 1 } });
  assert.equal(projectNativeBookmarks("rollback", "21", JSON.stringify({ ...newer, roots: { q: newer.roots.p } })), true);
  assert.equal(projectNativeBookmarks("rollback", "20", JSON.stringify({ ...older, roots: { q: older.roots.p } })), false);
  assert.equal(S().bookmarks.nodes.a.title, "Newer");
});

test("one request id per call, kept across the mutations of a batch", async () => {
  const owner = (globalThis.acTestBookmarkWriter = new FakeOwner());
  await submitBookmarks("p", [{ method: "addBookmark", args: [{ profileId: "p", title: "One", url: "https://one.example/" }] }, { method: "addBookmark", args: [{ profileId: "p", title: "Two", url: "https://two.example/" }] }], "batch-1");
  await bookmarkWriter.addBookmark({ profileId: "p", title: "Three", url: "https://three.example/" });
  assert.deepEqual(owner.submitted.map((call) => [call.requestId, call.mutations.length]), [["batch-1", 2], [owner.submitted[1].requestId, 1]]);
  assert.notEqual(owner.submitted[1].requestId, "batch-1");
  assert.deepEqual(S().bookmarks.nodes["bar@native"].children, ["n1", "n2", "n3"]);
});

test("a receipt for an engine the profile has since left keeps the other engine's nodes and the profile's new roots", () => {
  S().addBookmark({ profileId: "default", title: "Default page", url: "https://default.example/" });
  const defaultRoots = S().bookmarks.roots.default;
  const stale = { nodes: { "bar@gone": folder("bar@gone", "Bookmarks Bar"), "other@gone": folder("other@gone", "Other Bookmarks") }, roots: { default: { bar: "bar@gone", other: "other@gone" } } };
  assert.equal(projectNativeBookmarks("gone", "1", JSON.stringify(stale)), true);
  assert.deepEqual(S().bookmarks.roots.default, defaultRoots, "the profile keeps the roots it maps to now");
  assert.deepEqual(S().bookmarks.nodes[defaultRoots.bar].children.map((id) => S().bookmarks.nodes[id].title), ["Default page"]);
});

test("addBookmarkTree passes an index even without a parent, in both modes", async () => {
  const first = await bookmarkWriter.addBookmark({ profileId: "default", title: "First", url: "https://first.example/" });
  const [tree] = await bookmarkWriter.addBookmarkTree("default", [{ title: "Front", url: "https://front.example/" }], undefined, 0);
  assert.deepEqual(S().bookmarks.nodes[S().bookmarks.roots.default.bar].children, [tree, first]);
  const owner = (globalThis.acTestBookmarkWriter = new FakeOwner());
  await bookmarkWriter.addBookmarkTree("p", [{ title: "Front", url: "https://front.example/" }], undefined, 0);
  assert.deepEqual(owner.submitted[0].mutations[0].args.slice(2), [null, 0]);
});

test("legacy results are exactly what the store methods return", async () => {
  const id = await bookmarkWriter.addBookmark({ profileId: "default", title: "A", url: "https://a.example/" });
  assert.equal(await bookmarkWriter.updateBookmark("default", id, { title: "B" }), undefined);
  assert.equal(await bookmarkWriter.toggleBookmark("default", { url: "https://a.example/", title: "B", favicon: null }), false);
});

