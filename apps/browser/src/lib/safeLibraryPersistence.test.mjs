import assert from "node:assert/strict";
import { test } from "node:test";

let status = { active: false, safeMode: "option" };
globalThis.acTestNativeModules = { SolaraStoreAdapter: { status: () => status } };
const stub = await import("../test-native/index.ts");
const { shellNativeModules } = await import("../test-native/shell.ts");
const { useBrowser } = await import("../store/browser.ts");
const { startNativeStore } = await import("../store/nativeStore.ts");
const { bookmarkUuidFor } = await import("../store/bookmarks.ts");
const { refuseSafeHistoryDeletion } = await import("../store/safeLibraryEdits.ts");
const { migrateBookmarksFile, reloadBookmarks, startBookmarks } = await import("./bookmarks.ts");
const { migrateHistoryFile, reloadHistory, startHistory } = await import("./history.ts");
const notices = [];
shellNativeModules.SolaraShell.confirm = async (options) => { notices.push(options); return { confirmed: false, suppressed: false }; };
const S = () => useBrowser.getState();
const settle = async () => { for (let i = 0; i < 12; i++) await new Promise((resolve) => setImmediate(resolve)); };
const nodeId = bookmarkUuidFor("legacy-link");
const legacyBookmarks = JSON.stringify({ bookmarks: {
  roots: { default: { bar: "legacy-bar", other: "legacy-other" } },
  nodes: {
    "legacy-bar": { id: "legacy-bar", kind: "folder", parentId: null, title: "Bar", children: ["legacy-link"], addedAt: 0 },
    "legacy-other": { id: "legacy-other", kind: "folder", parentId: null, title: "Other", children: [], addedAt: 0 },
    "legacy-link": { id: "legacy-link", kind: "url", parentId: "legacy-bar", title: "Legacy", url: "https://legacy.example/", addedAt: 1 },
  },
} });
const legacyHistory = JSON.stringify({ history: { default: [{ url: "https://legacy.example/", title: "Legacy", visits: 1, lastVisit: Date.now() }] } });
function launch(safe) {
  status = { active: false, safeMode: safe ? "option" : null };
  startNativeStore();
  S().hydrate({});
}
function reset() {
  stub.docs.clear(); stub.bookmarkDbs.clear(); stub.historyDbs.clear();
  stub.bookmarkOpsSent.length = 0; stub.documentWrites.length = 0; notices.length = 0;
  launch(true);
}

test("safe bookmark display refreshes without writes; normal-launch edits persist without stale-cache replay", async () => {
  reset();
  stub.docs.set("bookmarks-cache.json", JSON.stringify({ version: 1, trees: { "": [
    { id: "bar@default", kind: "folder", parentId: null, title: "Bar", children: [nodeId], addedAt: 0 },
    { id: "other@default", kind: "folder", parentId: null, title: "Other", children: [], addedAt: 0 },
    { id: nodeId, kind: "url", parentId: "bar@default", title: "Stale cache", url: "https://stale.example/", addedAt: 1 },
  ] } }));
  const cache = stub.docs.get("bookmarks-cache.json");
  stub.chromeBookmarkEdit("", [{ op: "add", id: nodeId, k: "u", t: "Engine", u: "https://engine.example/", a: 1, parent: "bar" }]);
  let stop = startBookmarks();
  try {
    await settle(); await reloadBookmarks();
    assert.equal(S().bookmarks.nodes[nodeId].title, "Engine");
    assert.equal(stub.bookmarkOpsSent.length, 0);
    assert.equal(stub.docs.get("bookmarks-cache.json"), cache);
    stop(); launch(false); stop = startBookmarks();
    await settle(); await reloadBookmarks();
    S().updateBookmark(nodeId, { title: "Safe edit", url: "https://edited.example/" });
    const folder = S().addBookmarkFolder({ profileId: "default", title: "Safe folder" });
    const [imported] = S().addBookmarkTree("default", [{ title: "Imported", url: "https://imported.example/" }], folder);
    S().moveBookmark(nodeId, folder, 0);
    const removed = S().addBookmark({ profileId: "default", title: "Removed", url: "https://removed.example/" });
    await settle(); S().removeBookmark(removed); await settle();
    assert.equal(stub.chromeBookmarks("").get(nodeId).t, "Safe edit");
    assert.equal(stub.chromeBookmarks("").get(nodeId).u, "https://edited.example/");
    assert.equal(stub.chromeBookmarks("").get(nodeId).parent, folder);
    assert.equal(stub.chromeBookmarks("").has(removed), false);
    assert.equal(stub.chromeBookmarks("").get(imported).u, "https://imported.example/");
    stop(); const callsBeforeNormal = stub.bookmarkOpsSent.length; launch(false); stop = startBookmarks();
    await settle(); await reloadBookmarks();
    assert.equal(S().bookmarks.nodes[nodeId].title, "Safe edit");
    assert.equal(S().bookmarks.nodes[nodeId].parentId, folder);
    assert.equal(S().bookmarks.nodes[imported].url, "https://imported.example/");
    assert.equal(S().bookmarks.nodes[removed], undefined);
    assert.equal(stub.bookmarkOpsSent.length, callsBeforeNormal);
    assert.equal(notices.length, 0);
  } finally { stop(); }
});

test("safe history deletion and explicit import survive a normal launch without a replica restoring deleted rows", async () => {
  reset();
  stub.chromeVisit("", "https://deleted.example/", "Delete", 42);
  stub.chromeVisit("", "https://kept.example/", "Keep", 43);
  let stop = startHistory();
  try {
    await settle(); await reloadHistory();
    S().removeHistory("default", ["https://deleted.example/"]);
    S().importHistory("default", [{ url: "https://imported.example/", title: "Safe import", visits: 1, lastVisit: 44 }]);
    await settle();
    assert.equal(stub.chromeHistory("").has("https://deleted.example/"), false);
    assert.equal(stub.chromeHistory("").get("https://imported.example/").title, "Safe import");
    stop(); launch(false); stop = startHistory(); await settle(); await reloadHistory();
    assert.deepEqual(S().history.default.map((row) => row.url), ["https://imported.example/", "https://kept.example/"]);
    assert.equal(stub.docs.has("history.json"), false);
    assert.equal(notices.length, 0);
  } finally { stop(); }
});

test("pending legacy bookmark deletion is visibly refused before either store changes, then normal migration/deletion run", async () => {
  for (const method of ["removeBookmark", "removeBookmarks", "toggleBookmark"]) {
    reset(); stub.docs.set("bookmarks.json", legacyBookmarks);
    stub.chromeBookmarkEdit("", [{ op: "add", id: nodeId, k: "u", t: "Legacy", u: "https://legacy.example/", a: 1, parent: "bar" }]);
    let stop = startBookmarks();
    try {
      await settle(); await reloadBookmarks(); const before = S().bookmarks;
      if (method === "removeBookmarks") assert.deepEqual(S().removeBookmarks([nodeId]), { nodes: [], places: [] });
      else if (method === "toggleBookmark") assert.equal(S().toggleBookmark("default", { url: "https://legacy.example/", title: "Legacy", favicon: null }), true);
      else S().removeBookmark(nodeId);
      await settle();
      assert.equal(S().bookmarks, before); assert.equal(stub.chromeBookmarks("").has(nodeId), true);
      assert.equal(stub.docs.get("bookmarks.json"), legacyBookmarks);
      assert.equal(notices.length, 1); assert.match(notices[0].message, /can't be deleted in safe mode.*legacy file/);
      stop(); launch(false); await migrateBookmarksFile({ keepMs: 0 }); stop = startBookmarks();
      await settle(); await reloadBookmarks();
      assert.equal(stub.chromeBookmarks("").has(nodeId), true);
      S().removeBookmark(nodeId); await settle();
      assert.equal(stub.chromeBookmarks("").has(nodeId), false); assert.equal(stub.docs.has("bookmarks.json"), false);
    } finally { stop(); }
  }
});

test("pending legacy history deletion/clear are visibly refused; unrelated URLs/profiles/time ranges remain editable", async () => {
  reset(); stub.docs.set("history.json", legacyHistory);
  stub.chromeVisit("", "https://legacy.example/", "Legacy", Date.now());
  stub.chromeVisit("", "https://unrelated.example/", "Unrelated", 42);
  await reloadHistory(); const before = S().history;
  S().removeHistory("default", ["https://legacy.example/"]); S().clearHistory("default"); await settle();
  assert.equal(S().history, before); assert.equal(stub.chromeHistory("").has("https://legacy.example/"), true);
  assert.equal(stub.docs.get("history.json"), legacyHistory); assert.equal(notices.length, 2);
  assert.match(notices[0].message, /can't be deleted in safe mode.*legacy file/);
  assert.equal(refuseSafeHistoryDeletion("other-profile"), false);
  assert.equal(refuseSafeHistoryDeletion("", undefined, Date.now() + 10000), false);
  S().removeHistory("default", ["https://unrelated.example/"]); await settle();
  assert.equal(stub.chromeHistory("").has("https://unrelated.example/"), false);
  launch(false); await migrateHistoryFile(Date.now(), { keepMs: 0 }); await reloadHistory();
  assert.equal(S().history.default.some((row) => row.url === "https://legacy.example/"), true);
  S().removeHistory("default", ["https://legacy.example/"]); await settle();
  assert.equal(stub.chromeHistory("").has("https://legacy.example/"), false); assert.equal(stub.docs.has("history.json"), false);
});

test("safe automatic legacy imports keep source files and make no engine writes; normal controls import/remove them", async () => {
  reset(); stub.docs.set("bookmarks.json", legacyBookmarks); stub.docs.set("history.json", legacyHistory);
  assert.equal(await migrateBookmarksFile({ keepMs: 0 }), "kept");
  assert.equal(await migrateHistoryFile(Date.now(), { keepMs: 0 }), "kept");
  assert.equal(stub.bookmarkOpsSent.length, 0); assert.equal(stub.chromeHistory("").size, 0);
  assert.equal(stub.chromeBookmarks("").has(nodeId), false);
  assert.equal(stub.docs.get("bookmarks.json"), legacyBookmarks); assert.equal(stub.docs.get("history.json"), legacyHistory);
  launch(false);
  assert.equal(await migrateBookmarksFile({ keepMs: 0 }), "moved");
  assert.equal(await migrateHistoryFile(Date.now(), { keepMs: 0 }), "moved");
  assert.equal(stub.chromeBookmarks("").has(nodeId), true); assert.equal(stub.chromeHistory("").has("https://legacy.example/"), true);
  assert.equal(stub.docs.has("bookmarks.json"), false); assert.equal(stub.docs.has("history.json"), false);
});
