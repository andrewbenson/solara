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
const { seedBookmarkProjection, nextBookmarkProjectionOwner } = await import("../test-native/bookmarkProjection.ts");
const S = () => useBrowser.getState();
const tree = (engine, title = "Native", profile = "default") => {
  const bar = `bar@${engine || "default"}`, other = `other@${engine || "default"}`;
  return { nodes: {
    [bar]: { kind: "folder", id: bar, parentId: null, title: "Bookmarks Bar", children: ["page"], addedAt: 0 },
    [other]: { kind: "folder", id: other, parentId: null, title: "Other Bookmarks", children: [], addedAt: 0 },
    page: { kind: "url", id: "page", parentId: bar, title, url: "https://native.example/", favicon: null, addedAt: 1 },
  }, roots: { [profile]: { bar, other } } };
};
class Owner {
  owner = nextBookmarkProjectionOwner();
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
  seedBookmarkProjection(useBrowser);
  S().hydrate({});
  docs.clear(); documentWrites.length = 0;
});
afterEach(() => {
  stop?.(); stop = undefined;
  delete globalThis.acTestBookmarkWriter;
});
const select = () => globalThis.acTestBookmarkWriter = new Owner();
const drain = async () => { for (let n = 0; n < 20; n++) await Promise.resolve(); };
const mockEngineCall = (t, handler) => t.mock.method(solaraCoreNativeModules.SolaraCEF, "engineCall", async (name) => JSON.stringify(await handler(name)));

test("starting ownership bootstraps native bookmarks before projecting them", async () => {
  const owner = select();
  owner.mode = "starting";
  let finishReload;
  owner.reload = async () => {
    owner.reloads++;
    await new Promise((resolve) => { finishReload = resolve; });
    owner.mode = "owned";
  };
  assert.doesNotThrow(() => { stop = startBookmarks(); });
  assert.equal(owner.reloads, 1);
  assert.equal(S().bookmarks.nodes.page, undefined);
  assert.deepEqual(S().bookmarksReady, {});
  await assert.rejects(bookmarkWriter.addBookmark({ profileId: "default", title: "Early", url: "https://early.example/" }));
  finishReload();
  await drain();
  assert.equal(S().bookmarks.nodes.page.title, "Native");
  assert.equal(S().bookmarksReady.default, true);
});

test("a rejected native bootstrap leaves bookmark startup available", async (t) => {
  const owner = select();
  owner.mode = "starting";
  const failure = new Error("native bootstrap unavailable");
  owner.reload = async () => { owner.reloads++; throw failure; };
  const warnings = [];
  t.mock.method(console, "warn", (...args) => { warnings.push(args); });
  assert.doesNotThrow(() => { stop = startBookmarks(); });
  await drain();
  assert.equal(owner.reloads, 1);
  assert.equal(S().bookmarks.nodes.page, undefined);
  assert.deepEqual(S().bookmarksReady, {});
  assert.equal(warnings.length, 1);
  assert.equal(warnings[0][1], failure);
});

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
  owner.owner = nextBookmarkProjectionOwner(); owner.generation = "1"; owner.revision = "1";
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

test("legacy authority never starts a JS read while waiting for the native feed", async (t) => {
  const calls = [];
  mockEngineCall(t, (name) => { calls.push(name); return {}; });
  globalThis.acTestBookmarkWriter = { state: () => ({ state: "legacy" }) };
  stop = startBookmarks(); await drain();
  const owner = select(); emitBookmarkProjection(); await drain();
  assert.equal(S().bookmarks.nodes.page.title, "Native");
  assert.deepEqual(calls, []);
  assert.deepEqual(documentWrites, []);
  assert.equal(owner.reloads, 0);
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

test("native startup never schedules a legacy source-removal timer", async (t) => {
  const timers = [];
  t.mock.method(globalThis, "setTimeout", (run) => { timers.push(run); return timers.length; });
  docs.set("bookmarks.json", JSON.stringify({ bookmarks: tree("", "Legacy") }));
  select(); stop = startBookmarks(); await drain();
  assert.deepEqual(timers, []);
  assert.ok(docs.has("bookmarks.json"));
  assert.equal(S().bookmarks.nodes.page.title, "Native");
  assert.deepEqual(documentWrites, []);
});

test("equal empty projections and unavailable readiness still refuse in-place writes", () => {
  seedBookmarkProjection(useBrowser);
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

test("read-only native authority projects and reloads display while edits and sync stay held", async () => {
  const owner = select();
  owner.mode = "read-only-unavailable";
  owner.ready = false;
  stop = startBookmarks(); await drain();
  assert.equal(S().bookmarks.nodes.page.title, "Native");
  assert.equal(S().bookmarksReady.default, undefined);
  assert.equal(owner.reloads, 1);
  await assert.rejects(bookmarkWriter.updateBookmark("default", "page", { title: "Refused" }));
  const adapter = bookmarksAdapter("default");
  assert.equal(adapter.extract(() => undefined), null);
  assert.equal(await adapter.apply(new Map()), false);
  assert.equal(S().bookmarks.nodes.page.title, "Native");
});
