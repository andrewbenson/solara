import "../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import "./switchOn.mjs";
const { S, settle, launch, reset, onAndSynced, otherMac, realSetTimeout, files } = await import('./harness.mjs');

const stub = await import("../../test-native/index.ts");
const { solaraCoreNativeModules } = await import("../../test-native/solaracore.ts");
const { reloadBookmarks, startBookmarks } = await import("../../lib/bookmarks.ts");

const cef = solaraCoreNativeModules.SolaraCEF;
const realEngineCall = cef.engineCall;
const gate = { apply: null, tree: null };
cef.engineCall = async (name, profile, json) => {
  if (name === "ac_bookmarks_tree" && gate.tree) await gate.tree;
  if (name === "ac_bookmarks_apply" && gate.apply) await gate.apply;
  return realEngineCall(name, profile, json);
};
const stubbedTimeout = globalThis.setTimeout;
const fiveSecond = [];
let timerIds = 1000;
globalThis.setTimeout = (fn, ms, ...rest) => {
  if (ms === 5) return realSetTimeout(fn, ms, ...rest);
  if (ms === 2000) return 1;
  if (ms === 5000) {
    fiveSecond.push(fn);
    return ++timerIds;
  }
  return stubbedTimeout(fn, ms, ...rest);
};
const realNow = Date.now;
let nowOffset = 0;
Date.now = () => realNow() + nowOffset;

const bridgeDocs = () => new Map([...stub.docs].filter(([name]) => name.startsWith("bookmarks-")));
const crashed = (atCrash) => {
  for (const name of [...stub.docs.keys()]) if (name.startsWith("bookmarks-")) stub.docs.delete(name);
  for (const [name, value] of atCrash) stub.docs.set(name, value);
};
const flush = async () => {
  for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
};
const chromeNode = (title) => [...stub.chromeBookmarks("").values()].find((n) => n.k === "u" && n.t === title);
const barTitles = () => stub.chromeBookmarks("").get("bar").children.map((id) => stub.chromeBookmarks("").get(id).t);
const snapshotChrome = () => new Map([...stub.chromeBookmarks("")].map(([id, n]) => [id, { ...n, children: n.children ? [...n.children] : n.children }]));
const restoreChrome = (snap) => {
  const db = stub.chromeBookmarks("");
  db.clear();
  for (const [id, n] of snap) db.set(id, { ...n, children: n.children ? [...n.children] : n.children });
};

async function bridgeAndEngine() {
  reset();
  stub.bookmarkDbs.clear();
  fiveSecond.length = 0;
  nowOffset = 0;
  let stop = startBookmarks();
  await flush();
  await reloadBookmarks();
  const engine = await onAndSynced();
  await flush();
  await reloadBookmarks();
  return { engine, stopBridge: () => stop(), restartBridge: () => (stop = startBookmarks()) };
}

async function relaunchAndSync(restartBridge) {
  restartBridge();
  const again = await launch();
  again.startSync();
  await settle();
  await flush();
  await reloadBookmarks();
  for (let i = 0; i < 3; i++) await again.syncNow();
  await settle();
  await flush();
  await reloadBookmarks();
  return again;
}

async function crashBeforeCacheAndChromeSave({ publishedFirst, bLater, syncFirst = false }) {
  const { engine, stopBridge, restartBridge } = await bridgeAndEngine();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  const [key] = [...other.store].find(([, v]) => v.t === "One");
  stopBridge();
  restartBridge();
  await flush();
  await reloadBookmarks();
  const cacheBefore = stub.docs.get("bookmarks-cache.json");
  const chromeBefore = snapshotChrome();
  S().updateBookmark(chromeNode("One").id, { title: "Local" });
  await flush();
  await reloadBookmarks();
  if (publishedFirst) {
    await engine.syncNow();
    await settle();
  }
  const atCrash = bridgeDocs();
  if (cacheBefore === undefined) atCrash.delete("bookmarks-cache.json");
  else atCrash.set("bookmarks-cache.json", cacheBefore);
  stopBridge();
  crashed(atCrash);
  restoreChrome(chromeBefore);
  if (bLater) {
    await other.sync();
    nowOffset += 60_000;
    other.store.set(key, { ...other.store.get(key), t: "Newer on B" });
    await other.sync();
  }
  const mark = files().length;
  try {
    if (syncFirst) {
      let open;
      gate.tree = new Promise((r) => (open = r));
      restartBridge();
      const again = await launch();
      again.startSync();
      for (let i = 0; i < 2; i++) await again.syncNow();
      await settle();
      assert.equal(S().bookmarks.nodes[[...stub.chromeBookmarks("").values()].find((n) => n.t === "One").id]?.title, "Newer on B", "control: sync applied B's rename before the first read");
      gate.tree = null;
      open();
      await flush();
      await reloadBookmarks();
      for (let i = 0; i < 3; i++) await again.syncNow();
      await settle();
      await flush();
      await reloadBookmarks();
    } else await relaunchAndSync(restartBridge);
    await other.sync();
    const resent = files().slice(mark).flatMap(({ file }) => file.ops ?? []).filter((op) => op.k === key).map((op) => op.v?.t);
    return { key, other, resent };
  } finally {
    stopBridge();
  }
}

test("SYNC-1: crash 0-2 s after a rename that sync already published; B renames it later; Mac A's replay must not beat B's newer rename", { todo: "step 9" }, async () => {
  const { key, other, resent } = await crashBeforeCacheAndChromeSave({ publishedFirst: true, bLater: true });
  assert.equal(other.store.get(key)?.t, "Newer on B", "B's later rename wins on B");
  assert.ok(chromeNode("Newer on B"), `and lands in A's Chrome (A has ${[...stub.chromeBookmarks("").values()].map((n) => n.t)})`);
  assert.ok(!resent.includes("Local"), `A doesn't republish its older rename (sent: ${JSON.stringify(resent)})`);
});

test("SYNC-2: crash 0-2 s after a rename sync had not published yet; B renames later; B's newer rename must win", async () => {
  const { key, other, resent } = await crashBeforeCacheAndChromeSave({ publishedFirst: false, bLater: true });
  assert.equal(other.store.get(key)?.t, "Newer on B", `B's later rename wins on B (A sent ${JSON.stringify(resent)})`);
  assert.ok(chromeNode("Newer on B"), `and lands in A's Chrome (A has ${[...stub.chromeBookmarks("").values()].map((n) => n.t)})`);
});

test("SYNC-control: crash 0-2 s after a rename, nobody else edits: the rename survives", { todo: "step 9" }, async () => {
  const { key, other } = await crashBeforeCacheAndChromeSave({ publishedFirst: false, bLater: false });
  assert.ok(chromeNode("Local"), `A's Chrome keeps the rename (A has ${[...stub.chromeBookmarks("").values()].map((n) => n.t)})`);
  assert.equal(other.store.get(key)?.t, "Local");
});

async function threeInBar() {
  const ctx = await bridgeAndEngine();
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  await flush();
  await reloadBookmarks();
  S().addBookmark({ profileId: "default", url: "https://three.example/", title: "Three" });
  await flush();
  await reloadBookmarks();
  nowOffset += 10_000;
  for (const fn of fiveSecond.splice(0)) fn();
  return ctx;
}

test("REORDER: an extension's reorder after the app's reorder, saved by Chrome before a crash, isn't undone at relaunch", async () => {
  const { stopBridge, restartBridge } = await threeInBar();
  assert.deepEqual(barTitles(), ["One", "Two", "Three"], "control: start order");
  const three = chromeNode("Three");
  S().moveBookmark(three.id, S().bookmarks.roots.default.bar, 0);
  await flush();
  await reloadBookmarks();
  assert.deepEqual(barTitles(), ["Three", "One", "Two"], "control: app's move reached Chrome");
  stub.chromeBookmarkEdit("", [{ op: "move", id: three.id, parent: "bar", index: 2 }]);
  await flush();
  await reloadBookmarks();
  assert.deepEqual(barTitles(), ["One", "Two", "Three"], "control: extension's move reached Chrome");
  const atCrash = bridgeDocs();
  stopBridge();
  crashed(atCrash);
  restartBridge();
  try {
    await flush();
    await reloadBookmarks();
    assert.deepEqual(barTitles(), ["One", "Two", "Three"], `the extension's later order stands (bridge docs at crash: ${[...atCrash.keys()]})`);
  } finally {
    stopBridge();
  }
});

test("TIMER: two edits 4 s apart, every bridge timer fired, then an hour later an extension renames the first and the app crashes with Chrome's file saved: the extension's title stands", async () => {
  const { stopBridge, restartBridge } = await threeInBar();
  S().updateBookmark(chromeNode("One").id, { title: "One-a" });
  await flush();
  await reloadBookmarks();
  nowOffset += 4000;
  S().updateBookmark(chromeNode("Two").id, { title: "Two-a" });
  await flush();
  await reloadBookmarks();
  nowOffset += 1500;
  for (const fn of fiveSecond.splice(0)) fn();
  nowOffset += 3_600_000;
  for (const fn of fiveSecond.splice(0)) fn();
  stub.chromeBookmarkEdit("", [{ op: "update", id: chromeNode("Two-a").id, t: "Two-ext" }]);
  await flush();
  await reloadBookmarks();
  assert.ok(chromeNode("Two-ext"), "control: the extension's rename reached Chrome");
  const atCrash = bridgeDocs();
  stopBridge();
  crashed(atCrash);
  restartBridge();
  try {
    await flush();
    await reloadBookmarks();
    assert.ok(chromeNode("Two-ext"), `the extension's title stands (Chrome: ${barTitles()}; bridge docs at crash: ${[...atCrash.keys()]})`);
  } finally {
    stopBridge();
  }
});

test("LINGER+REORDER: an extension's reorder made an hour after the app's stands after a crash", async () => {
  const { stopBridge, restartBridge } = await threeInBar();
  S().updateBookmark(chromeNode("One").id, { title: "One-a" });
  await flush();
  await reloadBookmarks();
  nowOffset += 4000;
  const three = chromeNode("Three");
  S().moveBookmark(three.id, S().bookmarks.roots.default.bar, 0);
  await flush();
  await reloadBookmarks();
  nowOffset += 1500;
  for (const fn of fiveSecond.splice(0)) fn();
  nowOffset += 3_600_000;
  stub.chromeBookmarkEdit("", [{ op: "move", id: three.id, parent: "bar", index: 2 }]);
  await flush();
  await reloadBookmarks();
  assert.deepEqual(barTitles(), ["One-a", "Two", "Three"], "control: the extension's move reached Chrome");
  const atCrash = bridgeDocs();
  stopBridge();
  crashed(atCrash);
  restartBridge();
  try {
    await flush();
    await reloadBookmarks();
    assert.deepEqual(barTitles(), ["One-a", "Two", "Three"], `the extension's order from an hour ago stands (bridge docs at crash: ${[...atCrash.keys()]})`);
  } finally {
    stopBridge();
  }
});

test("GAP: a bookmark the user deleted stays deleted after a crash that lost a later push", async () => {
  const { stopBridge, restartBridge } = await threeInBar();
  const chromeBefore = snapshotChrome();
  const temp = S().addBookmark({ profileId: "default", url: "https://temp.example/", title: "Temp" });
  await flush();
  await reloadBookmarks();
  assert.ok(chromeNode("Temp"), "control: Temp reached Chrome");
  let open;
  gate.apply = new Promise((r) => (open = r));
  S().updateBookmark(chromeNode("One").id, { title: "One-b" });
  await flush();
  S().removeBookmark(chromeNode("Temp")?.id ?? temp);
  S().updateBookmark(chromeNode("Two").id, { title: "Two-user" });
  gate.apply = null;
  open();
  await flush();
  await reloadBookmarks();
  assert.ok(!chromeNode("Temp"), "control: the delete reached Chrome");
  stub.chromeBookmarkEdit("", [{ op: "update", id: chromeNode("Two-user").id, t: "Two-ext" }]);
  await flush();
  await reloadBookmarks();
  const atCrash = bridgeDocs();
  stopBridge();
  crashed(atCrash);
  restoreChrome(chromeBefore);
  restartBridge();
  try {
    await flush();
    await reloadBookmarks();
    assert.ok(!chromeNode("Temp"), `the deleted bookmark stays deleted (Chrome: ${barTitles()}; bridge docs at crash: ${[...atCrash.keys()]})`);
  } finally {
    stopBridge();
  }
});
