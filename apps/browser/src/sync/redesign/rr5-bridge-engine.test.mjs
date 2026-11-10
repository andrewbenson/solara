import "../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import "./switchOn.mjs";
const { S, settle, launch, reset, onAndSynced, otherMac, realSetTimeout, titles, files } = await import('./harness.mjs');

const stub = await import("../../test-native/index.ts");
const { solaraCoreNativeModules } = await import("../../test-native/solaracore.ts");
const { reloadBookmarks, startBookmarks } = await import("../../lib/bookmarks.ts");

const cef = solaraCoreNativeModules.SolaraCEF;
const realEngineCall = cef.engineCall;
const gate = { apply: null, refuse: null, refused: 0, scaleRetries: false };
cef.engineCall = async (name, profile, json) => {
  if (name === "ac_bookmarks_apply" && gate.refuse && String(json).includes(gate.refuse)) {
    gate.refused++;
    await new Promise((r) => realSetTimeout(r, 2));
    throw new Error("push refused");
  }
  if (name === "ac_bookmarks_apply" && gate.apply) await gate.apply;
  return realEngineCall(name, profile, json);
};
const stubbedTimeout = globalThis.setTimeout;
const pushRetryMs = new Set([1500, 3000, 6000, 12000, 24000, 48000, 60000]);
globalThis.setTimeout = (fn, ms, ...rest) =>
  ms === 5 ? realSetTimeout(fn, ms, ...rest) : ms === 2000 ? 1 : gate.scaleRetries && pushRetryMs.has(ms) && new Error().stack.includes("lib/bookmarks.ts") ? realSetTimeout(fn, ms / 100, ...rest) : stubbedTimeout(fn, ms, ...rest);

const flush = async () => {
  for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
};
const chromeNode = (title) => [...stub.chromeBookmarks("").values()].find((n) => n.k === "u" && n.t === title);

async function bridgeAndEngine() {
  reset();
  stub.bookmarkDbs.clear();
  let stop = startBookmarks();
  await flush();
  await reloadBookmarks();
  const engine = await onAndSynced();
  await flush();
  await reloadBookmarks();
  return { engine, stopBridge: () => stop(), restartBridge: () => (stop = startBookmarks()) };
}

test("RR5-control: with both running, an extension's rename in Chrome reaches the other Mac", async () => {
  const { engine, stopBridge } = await bridgeAndEngine();
  try {
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const other = otherMac(`p:${syncId}`);
    await other.sync();
    const one = chromeNode("One");
    assert.ok(one, "control: One is in Chrome");
    stub.chromeBookmarkEdit("", [{ op: "add", id: one.id, k: "u", t: "Renamed by an extension", u: one.u, a: one.a, parent: "bar", index: 0 }]);
    await flush();
    await reloadBookmarks();
    for (let i = 0; i < 2; i++) await engine.syncNow();
    await settle();
    await other.sync();
    assert.ok([...other.store.values()].some((v) => v.t === "Renamed by an extension"));
  } finally {
    stopBridge();
  }
});

test("RR5: an extension's rename made in Chrome while the app was quit, read at launch while an app edit is still pending, reaches the other Mac", async () => {
  const { engine, stopBridge, restartBridge } = await bridgeAndEngine();
  void engine;
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  const one = chromeNode("One");
  assert.ok(one, "control: One is in Chrome");
  stopBridge();
  stub.chromeBookmarkEdit("", [{ op: "add", id: one.id, k: "u", t: "Renamed by an extension", u: one.u, a: one.a, parent: "bar", index: 0 }]);
  await flush();
  let open;
  gate.apply = new Promise((r) => (open = r));
  S().addBookmark({ profileId: "default", url: "https://made-at-launch.example/", title: "Made at launch" });
  restartBridge();
  try {
    const again = await launch();
    again.startSync();
    await settle();
    await flush();
    await reloadBookmarks().catch(() => {});
    gate.apply = null;
    open();
    await flush();
    await reloadBookmarks();
    for (let i = 0; i < 3; i++) await again.syncNow();
    await settle();
    await other.sync();
    const there = [...other.store.values()].map((v) => v.t).sort();
    assert.ok(titles().includes("Renamed by an extension"), `the rename stands here (here: ${titles()})`);
    assert.ok(there.includes("Renamed by an extension"), `and reaches the other Mac (B has ${there})`);
  } finally {
    gate.apply = null;
    stopBridge();
  }
});

test("RR5-nopending: same without an app edit pending at launch", async () => {
  const { engine, stopBridge, restartBridge } = await bridgeAndEngine();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  const one = chromeNode("One");
  stopBridge();
  stub.chromeBookmarkEdit("", [{ op: "add", id: one.id, k: "u", t: "Renamed by an extension", u: one.u, a: one.a, parent: "bar", index: 0 }]);
  await flush();
  restartBridge();
  try {
    const again = await launch();
    again.startSync();
    await settle();
    await flush();
    await reloadBookmarks();
    for (let i = 0; i < 3; i++) await again.syncNow();
    await settle();
    await other.sync();
    assert.ok(titles().includes("Renamed by an extension"), `the rename stands here (here: ${titles()}; Chrome: ${chromeNode("Renamed by an extension") ? "renamed" : "One"})`);
    assert.ok([...other.store.values()].some((v) => v.t === "Renamed by an extension"));
  } finally {
    stopBridge();
  }
});

test("RR5-stale-cache: after a crash before the 2 s cache save, an extension's rename made while the app was down reaches the other Mac", async () => {
  const { engine, stopBridge, restartBridge } = await bridgeAndEngine();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  stopBridge();
  restartBridge();
  await flush();
  await reloadBookmarks();
  const cacheBefore = stub.docs.get("bookmarks-cache.json");
  assert.ok(cacheBefore, "control: the cache was saved");
  const local = Object.values(S().bookmarks.nodes).find((n) => n.kind === "url" && n.title === "One");
  S().updateBookmark(local.id, { title: "Renamed in the app" });
  await flush();
  await reloadBookmarks();
  for (let i = 0; i < 2; i++) await engine.syncNow();
  await settle();
  assert.equal(chromeNode("Renamed in the app")?.id, local.id, "control: Chrome has the app's rename");
  stopBridge();
  stub.docs.set("bookmarks-cache.json", cacheBefore);
  const filesBeforeLaunch = files().length;
  const one = chromeNode("Renamed in the app");
  stub.chromeBookmarkEdit("", [{ op: "add", id: one.id, k: "u", t: "Renamed by an extension", u: one.u, a: one.a, parent: "bar", index: 0 }]);
  await flush();
  restartBridge();
  try {
    const again = await launch();
    again.startSync();
    await settle();
    await flush();
    await reloadBookmarks();
    for (let i = 0; i < 3; i++) await again.syncNow();
    await settle();
    await other.sync();
    const there = [...other.store.values()].map((v) => v.t).sort();
    assert.ok(titles().includes("Renamed by an extension"), `the extension's later rename stands here (here: ${titles()}; Chrome: ${[...stub.chromeBookmarks("").values()].filter((n) => n.k === "u").map((n) => n.t)})`);
    assert.ok(there.includes("Renamed by an extension"), `and reaches the other Mac (B has ${there})`);
    const resent = files().slice(filesBeforeLaunch).flatMap(({ file }) => file.ops ?? []).filter((op) => op.v?.t === "Renamed in the app");
    assert.deepEqual(resent, [], "this Mac's own earlier push isn't resent at launch");
  } finally {
    stopBridge();
  }
});

test("I6a: a crash after Chrome took a push but before the cache was written doesn't resend the pushed rename over a newer rename elsewhere", async () => {
  const { engine, stopBridge, restartBridge } = await bridgeAndEngine();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  stopBridge();
  restartBridge();
  await flush();
  await reloadBookmarks();
  const cacheBefore = stub.docs.get("bookmarks-cache.json");
  const local = Object.values(S().bookmarks.nodes).find((n) => n.kind === "url" && n.title === "One");
  S().updateBookmark(local.id, { title: "Pushed then crashed" });
  await flush();
  await reloadBookmarks();
  for (let i = 0; i < 2; i++) await engine.syncNow();
  await settle();
  assert.ok(chromeNode("Pushed then crashed"), "control: Chrome took the push");
  stopBridge();
  stub.docs.set("bookmarks-cache.json", cacheBefore);
  await other.sync();
  const [key, value] = [...other.store].find(([, v]) => v.t === "Pushed then crashed") ?? [];
  assert.ok(key, "control: B has the pushed rename");
  other.store.set(key, { ...value, t: "Newer rename on B" });
  await other.sync();
  const mark = files().length;
  restartBridge();
  try {
    const again = await launch();
    again.startSync();
    await settle();
    await flush();
    await reloadBookmarks();
    for (let i = 0; i < 3; i++) await again.syncNow();
    await settle();
    await other.sync();
    const resent = files().slice(mark).flatMap(({ file }) => file.ops ?? []).filter((op) => op.k === key);
    assert.deepEqual(resent.map((op) => op.v?.t), [], "the pushed rename isn't resent at launch");
    assert.equal(other.store.get(key)?.t, "Newer rename on B");
    assert.ok(titles().includes("Newer rename on B"), `and B's rename lands here (here: ${titles()})`);
  } finally {
    stopBridge();
  }
});

test("I6b: an extension setting a bookmark back to a value this Mac pushed earlier, just before quitting, is kept and published at launch", async () => {
  const { engine, stopBridge, restartBridge } = await bridgeAndEngine();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMac(`p:${syncId}`);
  const local = Object.values(S().bookmarks.nodes).find((n) => n.kind === "url" && n.title === "One");
  S().updateBookmark(local.id, { title: "S" });
  await flush();
  await reloadBookmarks();
  await engine.syncNow();
  S().updateBookmark(local.id, { title: "U" });
  await flush();
  await reloadBookmarks();
  await engine.syncNow();
  await settle();
  await other.sync();
  const node = chromeNode("U");
  assert.ok(node, "control: Chrome has U");
  stopBridge();
  stub.chromeBookmarkEdit("", [{ op: "add", id: node.id, k: "u", t: "S", u: node.u, a: node.a, parent: "bar", index: 0 }]);
  await flush();
  restartBridge();
  try {
    const again = await launch();
    again.startSync();
    await settle();
    await flush();
    await reloadBookmarks();
    for (let i = 0; i < 3; i++) await again.syncNow();
    await settle();
    await other.sync();
    assert.ok(titles().includes("S"), `the extension's S stands here (here: ${titles()})`);
    assert.ok([...other.store.values()].some((v) => v.t === "S"), "and reaches B");
  } finally {
    stopBridge();
  }
});

test("AUDIT-docs-all: every Solara doc rolled back while Chrome's bookmarks aren't: a rename sync applied after the backup isn't resent over B's newer one", async () => {
  const { engine, stopBridge, restartBridge } = await bridgeAndEngine();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  stopBridge();
  restartBridge();
  await flush();
  await reloadBookmarks();
  const backup = new Map(stub.docs);
  const [key, value] = [...other.store].find(([, v]) => v.t === "One");
  other.store.set(key, { ...value, t: "R1 from B" });
  await other.sync();
  for (let i = 0; i < 2; i++) await engine.syncNow();
  await settle();
  await flush();
  await reloadBookmarks();
  assert.ok(chromeNode("R1 from B"), "control: Chrome took B's R1");
  other.store.set(key, { ...other.store.get(key), t: "R2 from B" });
  await other.sync();
  stopBridge();
  stub.docs.clear();
  for (const [k, v] of backup) stub.docs.set(k, v);
  const mark = files().length;
  restartBridge();
  try {
    const again = await launch();
    again.startSync();
    await settle();
    await flush();
    await reloadBookmarks();
    for (let i = 0; i < 3; i++) await again.syncNow();
    await settle();
    await other.sync();
    const sent = files().slice(mark).flatMap(({ file }) => file.ops ?? []).filter((op) => op.k === key);
    assert.deepEqual(sent.map((op) => op.v?.t), [], "nothing is resent for it");
    assert.equal(other.store.get(key)?.t, "R2 from B");
    assert.ok(titles().includes("R2 from B"), `and B's R2 lands here (here: ${titles()})`);
  } finally {
    stopBridge();
  }
});

test("AUDIT-chrome-bookmarks: Chrome's bookmarks rolled back while Solara's docs aren't: the older title isn't sent over the folder's newer one", { todo: "step 9" }, async () => {
  const { engine, stopBridge, restartBridge } = await bridgeAndEngine();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  const chromeBackup = new Map([...stub.chromeBookmarks("")].map(([id, n]) => [id, { ...n, children: [...(n.children ?? [])] }]));
  const [key, value] = [...other.store].find(([, v]) => v.t === "One");
  other.store.set(key, { ...value, t: "Newer from B" });
  await other.sync();
  for (let i = 0; i < 2; i++) await engine.syncNow();
  await settle();
  await flush();
  await reloadBookmarks();
  assert.ok(chromeNode("Newer from B"), "control: Chrome took B's rename");
  stopBridge();
  const db = stub.chromeBookmarks("");
  db.clear();
  for (const [id, n] of chromeBackup) db.set(id, n);
  const mark = files().length;
  restartBridge();
  try {
    const again = await launch();
    again.startSync();
    await settle();
    await flush();
    await reloadBookmarks();
    for (let i = 0; i < 3; i++) await again.syncNow();
    await settle();
    await other.sync();
    const sent = files().slice(mark).flatMap(({ file }) => file.ops ?? []).filter((op) => op.k === key);
    assert.deepEqual(sent.map((op) => op.v?.t), [], "the restored older title isn't sent");
    assert.equal(other.store.get(key)?.t, "Newer from B");
  } finally {
    stopBridge();
  }
});

test("I3-failed-push: a push that fails leaves no live intent, so an extension later setting that same value is published", async () => {
  const { engine, stopBridge } = await bridgeAndEngine();
  try {
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const other = otherMac(`p:${syncId}`);
    await other.sync();
    const [key, value] = [...other.store].find(([, v]) => v.t === "One");
    gate.refuse = "Pushed but refused";
    gate.scaleRetries = true;
    other.store.set(key, { ...value, t: "Pushed but refused" });
    await other.sync();
    await engine.syncNow().catch(() => {});
    await settle();
    await flush();
    await reloadBookmarks().catch(() => {});
    assert.ok(gate.refused > 0, "control: the push was refused");
    const start = gate.refused;
    await new Promise((r) => realSetTimeout(r, 600));
    await reloadBookmarks().catch(() => {});
    const during = gate.refused - start;
    assert.ok(during <= 8, `pushes Chrome keeps refusing back off (${during} refused calls in 60 scaled seconds)`);
    assert.ok(during >= 2, `and are still retried (${during})`);
    assert.ok(!chromeNode("Pushed but refused"), "control: Chrome never took it");
    other.store.set(key, { ...other.store.get(key), t: "Later on B" });
    await other.sync();
    for (let i = 0; i < 2; i++) await engine.syncNow().catch(() => {});
    await settle();
    await flush();
    await reloadBookmarks().catch(() => {});
    for (let i = 0; i < 100 && !chromeNode("Later on B"); i++) await new Promise((r) => realSetTimeout(r, 10));
    const node = chromeNode("Later on B");
    assert.ok(node, `control: Chrome took B's later rename (Chrome: ${[...stub.chromeBookmarks("").values()].map((n) => n.t)})`);
    stub.chromeBookmarkEdit("", [{ op: "add", id: node.id, k: "u", t: "Pushed but refused", u: node.u, a: node.a, parent: "bar", index: 0 }]);
    await flush();
    await reloadBookmarks().catch(() => {});
    gate.refuse = null;
    for (let i = 0; i < 2; i++) await engine.syncNow();
    await settle();
    await flush();
    await reloadBookmarks();
    for (let i = 0; i < 2; i++) await engine.syncNow();
    await settle();
    await other.sync();
    assert.equal(other.store.get(key)?.t, "Pushed but refused", "the extension's edit reaches B");
    gate.refuse = "Refused after a success";
    const before = gate.refused;
    S().addBookmark({ profileId: "default", url: "https://after.example/", title: "Refused after a success" });
    await new Promise((r) => realSetTimeout(r, 40));
    assert.ok(gate.refused - before >= 2, `a success resets the back-off: the first retry comes at once (${gate.refused - before} calls in 40 ms)`);
  } finally {
    gate.refuse = null;
    gate.refused = 0;
    gate.scaleRetries = false;
    stopBridge();
  }
});

test("MARK-settles: one extension edit leads to a bounded number of bridge calls, and then none", async () => {
  const { engine, stopBridge } = await bridgeAndEngine();
  const counts = { apply: 0, tree: 0 };
  const counting = cef.engineCall;
  cef.engineCall = async (name, profile, json) => {
    if (name === "ac_bookmarks_apply") counts.apply++;
    if (name === "ac_bookmarks_tree") counts.tree++;
    return counting(name, profile, json);
  };
  try {
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const other = otherMac(`p:${syncId}`);
    await other.sync();
    const one = chromeNode("One");
    stub.chromeBookmarkEdit("", [{ op: "add", id: one.id, k: "u", t: "Renamed by an extension", u: one.u, a: one.a, parent: "bar", index: 0 }]);
    for (let i = 0; i < 3; i++) {
      await flush();
      await reloadBookmarks();
      await engine.syncNow();
      await settle();
    }
    let first = { ...counts };
    for (let quiet = 0, waited = 0; quiet < 10 && waited < 300; waited++) {
      await new Promise((r) => realSetTimeout(r, 10));
      if (counts.apply === first.apply && counts.tree === first.tree) quiet++;
      else (first = { ...counts }), (quiet = 0);
    }
    assert.ok(first.apply + first.tree <= 12, `one edit costs a few calls (${JSON.stringify(first)})`);
    await new Promise((r) => realSetTimeout(r, 200));
    await flush();
    assert.deepEqual(counts, first, "and then the bridge is quiet");
    await other.sync();
    assert.ok([...other.store.values()].some((v) => v.t === "Renamed by an extension"), "control: the edit reached B");
  } finally {
    cef.engineCall = counting;
    stopBridge();
  }
});

const snapshotChrome = () => new Map([...stub.chromeBookmarks("")].map(([id, n]) => [id, { ...n, children: n.children ? [...n.children] : n.children }]));
const restoreChrome = (snap) => {
  const db = stub.chromeBookmarks("");
  db.clear();
  for (const [id, n] of snap) db.set(id, { ...n, children: n.children ? [...n.children] : n.children });
};

async function renameThenCrash(chromeLostThePush) {
  const { engine, stopBridge, restartBridge } = await bridgeAndEngine();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  const [key] = [...other.store].find(([, v]) => v.t === "One");
  const beforePush = snapshotChrome();
  const one = chromeNode("One");
  S().updateBookmark(one.id, { title: "Renamed here" });
  await flush();
  await reloadBookmarks();
  assert.ok(chromeNode("Renamed here"), "control: the push reached Chrome's model");
  const unsavedAtCrash = stub.docs.get("bookmarks-unsaved.json");
  stopBridge();
  if (unsavedAtCrash !== undefined) stub.docs.set("bookmarks-unsaved.json", unsavedAtCrash);
  if (chromeLostThePush) restoreChrome(beforePush);
  restartBridge();
  try {
    const again = await launch();
    again.startSync();
    await settle();
    await flush();
    await reloadBookmarks();
    for (let i = 0; i < 3; i++) await again.syncNow();
    await settle();
    await flush();
    await reloadBookmarks();
    await other.sync();
    assert.equal(other.store.get(key)?.t, "Renamed here", "the user's rename reaches B");
    assert.ok(chromeNode("Renamed here"), `and stays in Chrome (Chrome: ${[...stub.chromeBookmarks("").values()].map((n) => n.t)})`);
  } finally {
    stopBridge();
  }
}

test("REBUILD-keeps-entries-control: the same crash with Chrome's file saved publishes the rename", async () => {
  await renameThenCrash(false);
});

test("REBUILD-keeps-entries: a crash before Chrome saved the push of the user's rename (Chrome's file older than the cache) keeps the rename and publishes it", { todo: "step 9" }, async () => {
  await renameThenCrash(true);
});

test("LAUNCH-keeps-stamp: an extension edit already published, seen again at launch against a stale cache, keeps its stamp and loses to B's newer rename", async () => {
  const { engine, stopBridge, restartBridge } = await bridgeAndEngine();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  const [key] = [...other.store].find(([, v]) => v.t === "One");
  stopBridge();
  restartBridge();
  await flush();
  await reloadBookmarks();
  const staleCache = stub.docs.get("bookmarks-cache.json");
  const one = chromeNode("One");
  stub.chromeBookmarkEdit("", [{ op: "add", id: one.id, k: "u", t: "By an extension", u: one.u, a: one.a, parent: "bar", index: 0 }]);
  await flush();
  await reloadBookmarks();
  for (let i = 0; i < 2; i++) await engine.syncNow();
  await settle();
  await other.sync();
  assert.equal(other.store.get(key)?.t, "By an extension", "control: the extension's edit was published");
  other.store.set(key, { ...other.store.get(key), t: "Newer on B" });
  await other.sync();
  stopBridge();
  if (staleCache !== undefined) stub.docs.set("bookmarks-cache.json", staleCache);
  const mark = files().length;
  restartBridge();
  try {
    const again = await launch();
    again.startSync();
    await settle();
    await flush();
    await reloadBookmarks();
    for (let i = 0; i < 3; i++) await again.syncNow();
    await settle();
    await flush();
    await reloadBookmarks();
    await other.sync();
    const sent = files().slice(mark).flatMap(({ file }) => file.ops ?? []).filter((op) => op.k === key).map((op) => op.v?.t);
    assert.deepEqual(sent, [], "nothing is resent for it");
    assert.equal(other.store.get(key)?.t, "Newer on B");
    assert.ok(chromeNode("Newer on B"), "and B's rename lands here");
  } finally {
    stopBridge();
  }
});
