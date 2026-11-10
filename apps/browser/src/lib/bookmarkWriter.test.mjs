import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";
const { useBrowser } = await import("../store/browser.ts");
const { bookmarkWriter, projectNativeBookmarks, reportBookmarkFailure, submitBookmarks } = await import("./bookmarkWriter.ts");
const { BOOKMARK_REMAP_RETRY_MS, replaceBookmarkDocument } = await import("@solara/settings");
const { useToasts } = await import("../components/layout/toasts.ts");

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
    this.replaced = [];
    this.refuse = null;
    this.ids = 0;
  }
  state() {
    return { state: "owned", generation: this.lifecycleGeneration ?? this.generation };
  }
  snapshot() {
    return { engine: this.engine, generation: this.generation, revision: String(this.revision), ready: true, document: JSON.stringify(this.document) };
  }
  replace(profileId, documentJSON, expectedRevision, engine, generation, requestId) {
    this.replaced.push({ profileId, documentJSON, expectedRevision, engine, generation, requestId });
    if (this.refuse) throw this.refuse;
    if (engine !== this.engine || generation !== this.generation) throw Object.assign(new Error("the bookmark owner changed since this binding was taken"), { code: "staleBinding" });
    if (expectedRevision !== String(this.revision)) throw Object.assign(new Error("revision changed"), { code: "refused" });
    this.document = JSON.parse(documentJSON);
    this.revision += 1;
    return { revision: String(this.revision) };
  }
  async submit(profileId, mutationsJSON, engine, generation, requestId) {
    const mutations = JSON.parse(mutationsJSON);
    this.submitted.push({ profileId, mutations, engine, generation, requestId });
    if (this.refuse) throw this.refuse;
    if (engine !== this.engine || generation !== this.generation) throw Object.assign(new Error("the bookmark owner changed since this binding was taken"), { code: "staleBinding" });
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

test("a harmless runtime remap preserves the same-engine route binding", async () => {
  const owner = (globalThis.acTestBookmarkWriter = new FakeOwner());
  const realSubmit = owner.submit.bind(owner);
  owner.submit = (...args) => {
    owner.lifecycleGeneration = "2";
    return realSubmit(...args);
  };
  assert.equal(await bookmarkWriter.addBookmark({ profileId: "p", title: "Late", url: "https://late.example/" }), "n1");
  assert.equal(owner.submitted.length, 1);
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

const staleBinding = () => Object.assign(new Error("the bookmark owner changed since this binding was taken"), { code: "staleBinding" });

for (const operation of ["submit", "replace"]) {
  const fakeClock = (t) => {
    let now = 1_000_000;
    const delays = [];
    t.mock.method(Date, "now", () => now);
    t.mock.method(globalThis, "setTimeout", (run, delay) => { delays.push(delay); now += delay; queueMicrotask(run); return 0; });
    return { delays, elapsed: () => now - 1_000_000 };
  };
  const perform = (owner, operation, requestId, mutation = { method: "addBookmark", args: [{ profileId: "p", title: "Retried", url: "https://retry.example/" }] }) =>
    operation === "submit"
      ? submitBookmarks("p", [mutation], requestId)
      : replaceBookmarkDocument("p", owner.document, "10", { engine: owner.engine, generation: owner.generation }, requestId);

  test(`${operation} keeps retrying a stale binding while the profile's engine is unchanged, past the old six tries`, async (t) => {
    const clock = fakeClock(t);
    const owner = (globalThis.acTestBookmarkWriter = new FakeOwner());
    const calls = operation === "submit" ? owner.submitted : owner.replaced;
    const real = owner[operation].bind(owner);
    owner[operation] = (...args) => {
      if (calls.length < 8) {
        calls.push({ refused: true, requestId: args.at(-1) });
        throw staleBinding();
      }
      return real(...args);
    };
    const saved = await perform(owner, operation, "retry-1");
    assert.deepEqual(saved, operation === "submit" ? ["n1"] : "11");
    assert.deepEqual(clock.delays, [25, 50, 100, 200, 400, 400, 400, 400]);
    assert.deepEqual([...new Set(calls.map((call) => call.requestId))], ["retry-1"]);
    assert.equal(owner.revision, 11);
  });

  test(`${operation} refuses a revoked incarnation even when the engine string is reused`, async (t) => {
    fakeClock(t);
    const owner = (globalThis.acTestBookmarkWriter = new FakeOwner());
    const calls = operation === "submit" ? owner.submitted : owner.replaced;
    const real = owner[operation].bind(owner);
    let refused;
    owner[operation] = (...args) => {
      if (!refused) {
        calls.push({ refused: true });
        owner.generation = "retired-incarnation";
        throw (refused = staleBinding());
      }
      return real(...args);
    };
    await assert.rejects(perform(owner, operation, "retired-request"), (caught) => caught === refused);
    assert.equal(calls.length, 1);
    assert.equal(owner.revision, 10);
  });

  test(`${operation} never rebinds onto a different engine: it rejects so the caller re-plans`, async (t) => {
    fakeClock(t);
    const owner = (globalThis.acTestBookmarkWriter = new FakeOwner());
    owner.engine = "first-engine";
    const calls = operation === "submit" ? owner.submitted : owner.replaced;
    const real = owner[operation].bind(owner);
    let refused;
    owner[operation] = (...args) => {
      if (!refused) {
        calls.push({ refused: true });
        owner.engine = "second-engine";
        throw (refused = staleBinding());
      }
      return real(...args);
    };
    const before = JSON.stringify(S().bookmarks);
    await assert.rejects(perform(owner, operation, "moved-1"), (caught) => caught === refused);
    assert.equal(calls.length, 1, "nothing was sent with the new engine");
    assert.equal(owner.revision, 10);
    assert.equal(JSON.stringify(S().bookmarks), before);
  });

  test(`${operation} gives up at the remap deadline and never falls back to the JS store`, async (t) => {
    const clock = fakeClock(t);
    const owner = (globalThis.acTestBookmarkWriter = new FakeOwner());
    const error = (owner.refuse = staleBinding());
    const before = JSON.stringify(S().bookmarks);
    await assert.rejects(perform(owner, operation, "exhausted-1", { method: "removeBookmark", args: ["n1"] }), (caught) => caught === error && caught.code === "staleBinding");
    const calls = operation === "submit" ? owner.submitted : owner.replaced;
    assert.ok(clock.elapsed() >= BOOKMARK_REMAP_RETRY_MS, `waited ${clock.elapsed()} ms`);
    assert.ok(clock.elapsed() < BOOKMARK_REMAP_RETRY_MS + 500);
    assert.deepEqual([...new Set(calls.map((call) => call.requestId))], ["exhausted-1"]);
    assert.equal(JSON.stringify(S().bookmarks), before);
    assert.equal(owner.revision, 10);
  });

  for (const code of ["notOwned", "unknownProfile", "invalidDocument", "refused"]) {
    test(`${operation} does not retry ${code}`, async (t) => {
      const delays = [];
      t.mock.method(globalThis, "setTimeout", (run, delay) => { delays.push(delay); queueMicrotask(run); return 0; });
      const owner = (globalThis.acTestBookmarkWriter = new FakeOwner());
      const error = (owner.refuse = Object.assign(new Error(code), { code }));
      await assert.rejects(async () => operation === "submit"
        ? submitBookmarks("p", [{ method: "removeBookmark", args: ["n1"] }], "refused-1")
        : replaceBookmarkDocument("p", owner.document, "10", { engine: owner.engine, generation: owner.generation }, "refused-1"), (caught) => caught === error);
      assert.equal((operation === "submit" ? owner.submitted : owner.replaced).length, 1);
      assert.deepEqual(delays, []);
    });
  }
}

test("a bookmark edit that wasn't saved tells the user in the focused window", (t) => {
  t.mock.method(console, "warn", () => {});
  const windowId = S().createWindow();
  S().setFocusedWindow(windowId);
  reportBookmarkFailure(Object.assign(new Error("gave up"), { code: "staleBinding" }));
  assert.equal(useToasts.getState().toasts[windowId]?.title, "Bookmark not saved");
});
