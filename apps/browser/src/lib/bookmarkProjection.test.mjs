import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";
const { useBrowser } = await import("../store/browser.ts");
const { startBookmarks } = await import("./bookmarks.ts");
const { bookmarkWriter } = await import("./bookmarkWriter.ts");
const { bookmarksAdapter } = await import("../sync/adapters.ts");
const { workspaceHydration, workspaceFromSnapshot, runEffects } = await import("../store/nativeWorkspace.ts");
const { writeState } = await import("../store/nativeStore.ts");
const { emitBookmarkProjection } = await import("../test-native/expo.ts");
const { docs, documentWrites } = await import("../test-native/shell.ts");
const { engineEvent, solaraCoreNativeModules } = await import("../test-native/solaracore.ts");
const S = () => useBrowser.getState();
const tree = (engine, title = "Native", profile = "default") => {
  const bar = `bar@${engine || "default"}`, other = `other@${engine || "default"}`;
  return { nodes: {
    [bar]: { kind: "folder", id: bar, parentId: null, title: "Bookmarks Bar", children: ["page"], addedAt: 0 },
    [other]: { kind: "folder", id: other, parentId: null, title: "Other Bookmarks", children: [], addedAt: 0 },
    page: { kind: "url", id: "page", parentId: bar, title, url: "https://native.example/", favicon: null, addedAt: 1 },
  }, roots: { [profile]: { bar, other } } };
};
let ownerSequence = 100;
class Owner {
  owner = String(++ownerSequence);
  generation = "1";
  engine = "";
  revision = "1";
  hasView = true;
  ready = true;
  document = tree("");
  profiles = { default: { engine: "", generation: "11" } };
  mode = "owned";
  reloads = 0;
  state() { return { state: this.mode, generation: this.generation }; }
  snapshot() { return { ...this.profiles.default, revision: this.revision, hasView: this.hasView, readyForSync: this.ready, ready: this.ready, document: JSON.stringify(this.document) }; }
  projection() {
    const roots = Object.fromEntries(Object.entries(this.profiles).filter(([, binding]) => binding.engine === this.engine).map(([profile]) => [profile, this.document.roots.default]));
    return { owner: this.owner, generation: this.generation, profiles: this.profiles, views: { [this.engine]: { revision: this.revision, hasView: this.hasView, readyForSync: this.ready, document: { ...this.document, roots } } } };
  }
  async reload() { this.reloads++; }
}
let stop;
beforeEach(() => {
  delete globalThis.acTestBookmarkWriter;
  S().hydrate({ bookmarks: { nodes: {}, roots: {} } });
  useBrowser.setState({ bookmarksReady: {} });
  docs.clear(); documentWrites.length = 0;
});
afterEach(() => {
  stop?.(); stop = undefined;
  delete globalThis.acTestBookmarkWriter;
});
const select = () => globalThis.acTestBookmarkWriter = new Owner();
const drain = async () => { for (let n = 0; n < 20; n++) await Promise.resolve(); };
const mockEngineCall = (t, handler) => t.mock.method(solaraCoreNativeModules.SolaraCEF, "engineCall", async (name) => JSON.stringify(await handler(name)));

test("ownedHydrationNeverAuthorsBookmarks", () => {
  const owner = select();
  S().hydrate({ bookmarks: tree("stale", "Stale") });
  assert.equal(S().bookmarks.nodes.page, undefined);
  assert.deepEqual(S().bookmarksReady, {});
  const hydrated = workspaceHydration(S(), { bookmarks: tree("stale") });
  assert.ok(!("bookmarks" in hydrated));
  assert.ok(!("bookmarksReady" in hydrated));
  assert.ok(!("bookmarks" in workspaceFromSnapshot(S(), { profileOrder: ["default"] })));
  stop = startBookmarks();
  assert.equal(S().bookmarks.nodes.page.title, "Native");
  assert.deepEqual(S().bookmarks.roots, owner.document.roots);
});

test("directBookmarkSetStateIsRefused before subscribers observe it", () => {
  select(); stop = startBookmarks();
  const before = S().bookmarks;
  const seen = [];
  const unsub = useBrowser.subscribe((s) => seen.push(s.bookmarks));
  try {
    assert.throws(() => useBrowser.setState({ bookmarks: tree("rogue") }), /native.*bookmark|bookmark.*native/i);
    assert.throws(() => useBrowser.setState(() => ({ bookmarksReady: {} })), /native.*bookmark|bookmark.*native/i);
    assert.throws(() => S().addBookmark({ profileId: "default", title: "Rogue", url: "https://rogue.example/" }), /native.*bookmark|bookmark.*native/i);
    assert.throws(() => writeState(useBrowser, { bookmarks: tree("rogue") }), /native.*bookmark|bookmark.*native/i);
    assert.equal(S().bookmarks, before);
    assert.deepEqual(seen, []);
  } finally { unsub(); }
});

test("sharingAliasesProjectOneEngineRevision and remove deleted routes", () => {
  const owner = select();
  owner.profiles.alias = { engine: "", generation: "12" };
  stop = startBookmarks();
  assert.deepEqual(S().bookmarks.roots.alias, S().bookmarks.roots.default);
  const before = S().bookmarks;
  runEffects([{ type: "profileCreated", profileId: "new", sharedWith: "default" }], S, (p) => useBrowser.setState(p));
  runEffects([{ type: "profileDeleted", profileId: "alias", shared: true }], S, (p) => useBrowser.setState(p));
  assert.equal(S().bookmarks, before);
  delete owner.profiles.alias;
  owner.generation = "2";
  emitBookmarkProjection();
  assert.equal(S().bookmarks.roots.alias, undefined);
  assert.equal(S().bookmarks.nodes.page.title, "Native");
});

test("nativeSyncAndExtensionEditsUpdateReplica without a JS request", () => {
  const owner = select(); stop = startBookmarks();
  owner.document = tree("", "Remote sync"); owner.revision = "2";
  emitBookmarkProjection();
  assert.equal(S().bookmarks.nodes.page.title, "Remote sync");
  owner.document = tree("", "Extension\ud800"); owner.revision = "3";
  emitBookmarkProjection();
  assert.equal(S().bookmarks.nodes.page.title, "Extension\ud800");
  owner.document = tree("", "Old queued payload"); owner.revision = "2";
  emitBookmarkProjection();
  assert.equal(S().bookmarks.nodes.page.title, "Extension\ud800");
  const previousOwner = owner.owner;
  owner.owner = String(++ownerSequence); owner.generation = "1"; owner.revision = "1";
  owner.document = tree("", "Replacement"); emitBookmarkProjection();
  assert.equal(S().bookmarks.nodes.page.title, "Replacement");
  owner.owner = previousOwner; owner.revision = "999";
  owner.document = tree("", "Revoked owner"); emitBookmarkProjection();
  assert.equal(S().bookmarks.nodes.page.title, "Replacement");
});

test("delayedReceiptCannotCrossRemap", async () => {
  const owner = select(); stop = startBookmarks();
  let release;
  owner.submit = () => new Promise((resolve) => { release = resolve; });
  const pending = bookmarkWriter.addBookmark({ profileId: "default", title: "Held", url: "https://held.example/" });
  await drain();
  owner.engine = "new"; owner.generation = "2"; owner.revision = "1";
  owner.profiles.default = { engine: "new", generation: "22" };
  owner.document = tree("new", "Current"); emitBookmarkProjection();
  release({ engine: "", revision: "99", results: '["held"]', document: JSON.stringify(tree("", "Held receipt")) });
  assert.equal(await pending, "held");
  assert.equal(S().bookmarks.nodes.page.title, "Current");
  assert.deepEqual(S().bookmarks.roots.default, { bar: "bar@new", other: "other@new" });
  assert.equal(S().bookmarks.nodes["bar@default"], undefined);
});

test("hasView displays while only readyForSync releases sync", () => {
  const owner = select(); owner.ready = false; stop = startBookmarks();
  assert.equal(S().bookmarks.nodes.page.title, "Native");
  assert.equal(S().bookmarksReady.default, undefined);
  const adapter = bookmarksAdapter("default");
  assert.equal(adapter.extract(() => undefined), null);
  owner.ready = true; emitBookmarkProjection();
  assert.equal(S().bookmarksReady.default, true);
  owner.mode = "read-only-unavailable"; emitBookmarkProjection();
  assert.equal(S().bookmarks.nodes.page.title, "Native");
  assert.deepEqual(S().bookmarksReady, {});
});

for (const mode of ["starting", "read-only-unavailable", "stopped"]) {
  test(`${mode} never falls back to a legacy facade or adapter`, async () => {
    const owner = select(); owner.mode = mode;
    const before = S().bookmarks;
    await assert.rejects(bookmarkWriter.addBookmark({ profileId: "default", title: "Rogue", url: "https://rogue.example/" }), /unavailable|owned|paused/i);
    const adapter = bookmarksAdapter("default");
    assert.equal(adapter.extract(() => undefined), null);
    assert.equal(await adapter.apply(new Map(), new Set(), () => undefined, {}), false);
    assert.equal(S().bookmarks, before);
  });
}

test("ownedModeRunsNoJSPushReadCacheOrMigration", async (t) => {
  const owner = select();
  const calls = [], timers = [];
  mockEngineCall(t, (name) => { calls.push(name); throw new Error("unexpected JS engine call"); });
  docs.set("bookmarks.json", JSON.stringify({ bookmarks: tree("", "Legacy") }));
  docs.set("bookmarks-cache.json", JSON.stringify({ version: 1, trees: {} }));
  t.mock.method(globalThis, "setTimeout", (run) => { timers.push(run); return 0; });
  stop = startBookmarks(); await drain();
  owner.document = tree("", "Feed"); owner.revision = "2"; emitBookmarkProjection();
  engineEvent("bookmarks.changed", { profile: "" });
  await drain(); stop(); stop = undefined;
  assert.equal(S().bookmarks.nodes.page.title, "Feed");
  assert.deepEqual(calls, []);
  assert.deepEqual(timers, []);
  assert.deepEqual(documentWrites, []);
  assert.ok(docs.has("bookmarks.json"));
  assert.equal(owner.reloads, 1);
});

test("heldLegacyCompletionCannotWriteAfterSelection", async (t) => {
  let release;
  const calls = [];
  mockEngineCall(t, (name) => {
    calls.push(name);
    if (name === "ac_bookmarks_tree") return new Promise((resolve) => { release = resolve; });
    return {};
  });
  stop = startBookmarks(); await drain();
  assert.ok(release);
  const owner = select(); emitBookmarkProjection();
  release({ bar: { k: "f", id: "bar", t: "Bar", a: 0, c: [] }, other: { k: "f", id: "other", t: "Other", a: 0, c: [] } });
  await drain();
  assert.equal(S().bookmarks.nodes.page.title, "Native");
  assert.deepEqual(calls, ["ac_bookmarks_watch", "ac_bookmarks_tree"]);
  assert.deepEqual(documentWrites, []);
  assert.equal(owner.reloads, 1);
});

test("projection authority cannot be borrowed by a subscriber or an in-place write", () => {
  const owner = select(); stop = startBookmarks();
  assert.throws(() => useBrowser.setState((s) => {
    s.bookmarks.nodes.page.title = "Mutated";
    return { bookmarks: s.bookmarks };
  }), TypeError);
  const seen = [];
  const unsubscribe = useBrowser.subscribe((s) => {
    seen.push(s.bookmarks.nodes.page.title);
    assert.throws(() => useBrowser.setState({ bookmarks: tree("rogue") }), /native.*bookmark|bookmark.*native/i);
  });
  try {
    owner.document = tree("", "Accepted"); owner.revision = "2";
    emitBookmarkProjection();
    assert.deepEqual(seen, ["Accepted"]);
    assert.equal(S().bookmarks.nodes.page.title, "Accepted");
  } finally { unsubscribe(); }
});

test("selection cancels a legacy source-removal timer and keeps its evidence", async (t) => {
  const timers = [];
  t.mock.method(globalThis, "setTimeout", (run) => { timers.push(run); return timers.length; });
  t.mock.method(globalThis, "clearTimeout", () => {});
  docs.set("bookmarks.json", JSON.stringify({ bookmarks: tree("", "Legacy") }));
  mockEngineCall(t, (name) => name === "ac_bookmarks_tree"
    ? { bar: { k: "f", id: "bar", t: "Bar", a: 0, c: [] }, other: { k: "f", id: "other", t: "Other", a: 0, c: [] } }
    : { applied: 1, skipped: 0, invalid: [] });
  stop = startBookmarks(); await drain();
  assert.ok(timers.length > 0);
  select(); emitBookmarkProjection();
  for (const run of timers) run();
  await drain();
  assert.ok(docs.has("bookmarks.json"));
  assert.equal(S().bookmarks.nodes.page.title, "Native");
  assert.deepEqual(documentWrites, []);
});

test("equal empty projections and unavailable readiness still refuse in-place writes", () => {
  useBrowser.setState({ bookmarks: { nodes: {}, roots: {} }, bookmarksReady: {} });
  const owner = select(); owner.hasView = false;
  stop = startBookmarks();
  assert.throws(() => useBrowser.setState((s) => {
    s.bookmarks.roots.rogue = { bar: "rogue", other: "rogue" };
    return { bookmarks: s.bookmarks };
  }), TypeError);
  owner.hasView = true; emitBookmarkProjection();
  owner.projection = () => { throw new Error("stopped"); };
  emitBookmarkProjection();
  assert.deepEqual(S().bookmarksReady, {});
  assert.throws(() => useBrowser.setState((s) => {
    s.bookmarksReady.default = true;
    return { bookmarksReady: s.bookmarksReady };
  }), TypeError);
});
