import "../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import "./switchOn.mjs";
const { fake, folder, shell, S, settle, launch, reset, files, assertNoSeqReused, onAndSynced, otherMac, appMac, native, titles, bookmarkOps, restoreDocs, useBrowser } = await import('./harness.mjs');

const realNow = Date.now;
const at = (ms) => (Date.now = () => realNow() + ms);

test("D4a: an edit made just before a crash is published after the relaunch, with its own time, over an older change elsewhere", async () => {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  const [key, value] = [...other.store].find(([, v]) => v.t === "One");
  other.store.set(key, { ...value, t: "Older on B" });
  await other.sync();
  const one = Object.values(S().bookmarks.nodes).find((n) => n.kind === "url" && n.title === "One");
  S().updateBookmark(one.id, { title: "Renamed just before the crash" });
  const again = await launch();
  again.startSync();
  await settle();
  for (let i = 0; i < 2; i++) await again.syncNow();
  await settle();
  await other.sync();
  assert.equal(other.store.get(key)?.t, "Renamed just before the crash");
  void syncId;
});

test("D4b: a local bookmark the folder never had survives a lost sync state and goes out", async () => {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  fake.failWrite = (scope) => scope === `p:${syncId}`;
  S().addBookmark({ profileId: "default", url: "https://unsent.example/", title: "Unsent" });
  await engine.syncNow();
  await settle();
  fake.failWrite = null;
  shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
  shell.docs.delete("sync-journal.nns");
  const again = await launch();
  again.startSync();
  await settle();
  for (let i = 0; i < 3; i++) await again.syncNow();
  await settle();
  assert.ok(titles().includes("Unsent"), "kept here");
  assert.ok(bookmarkOps(syncId).some((op) => op.v?.t === "Unsent"), "and published");
});

test("D6: a lost base doesn't renumber bookmark positions", async () => {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  for (const t of ["Two", "Three", "Four"]) S().addBookmark({ profileId: "default", url: `https://${t.toLowerCase()}.example/`, title: t });
  await engine.syncNow();
  await settle();
  const before = files().length;
  shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
  const again = await launch();
  again.startSync();
  await settle();
  for (let i = 0; i < 3; i++) await again.syncNow();
  await settle();
  const republished = files().slice(before).filter(({ scope }) => scope === `p:${syncId}`).flatMap(({ file }) => file.ops ?? []).filter((op) => op.k.startsWith("bm:"));
  assert.deepEqual(republished.map((op) => [op.v?.t, op.v?.pos]), [], "no bookmark record is rewritten");
});

test("D7a: a rebuild whose file stays unreadable for more than a day doesn't remove the local bookmarks it can't see", async () => {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const before = new Set(files().map((f) => f.payload));
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  await engine.syncNow();
  await settle();
  const later = new Set(files().filter((f) => !before.has(f.payload) && f.scope === `p:${syncId}`).map((f) => f.payload));
  const realRead = native.read;
  native.read = async (...args) => {
    const listing = await realRead(...args);
    const unreadable = listing.files.filter((f) => later.has(f.payload));
    return { ...listing, files: listing.files.filter((f) => !later.has(f.payload)), damaged: [...listing.damaged, ...unreadable.map((f) => ({ id: f.id, age: 0 }))] };
  };
  try {
    shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
    const again = await launch();
    again.startSync();
    await settle();
    for (const hours of [0, 25, 50]) {
      at(hours * 3_600_000);
      for (let i = 0; i < 2; i++) await again.syncNow();
      await settle();
    }
    assert.deepEqual(titles(), ["One", "Two"], "nothing it couldn't see is removed");
    assert.ok(!bookmarkOps(syncId).some((op) => op.v === null), "and nothing is published as deleted");
  } finally {
    native.read = realRead;
    Date.now = realNow;
  }
});

test("D7b: a Mac that lost its state and comes back after 46 days doesn't bring back a bookmark deleted and collected meanwhile", { todo: "step 8" }, async () => {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  S().addBookmark({ profileId: "default", url: "https://gone.example/", title: "Gone" });
  await engine.syncNow();
  await settle();
  const scope = `p:${syncId}`;
  const state = sync_emptyJoined();
  const clock = new (await import("../../../../../packages/sync/src/index.ts")).Clock("otherMac");
  const sync = await import("../../../../../packages/sync/src/index.ts");
  const store = new Map();
  const adapter = { prefix: "bm:", extract: () => ({ values: new Map(store) }), apply: (visible, changed) => { for (const k of changed) visible.has(k) ? store.set(k, visible.get(k)) : store.delete(k); } };
  const transport = { write: async (s, payload) => native.write("/sync", s, payload), read: async (s, known) => native.read("/sync", s, known), remove: async (s, ids) => native.remove("/sync", s, ids) };
  const run = () => sync.syncScope({ scope, state, transport, adapters: [adapter], clock, device: "otherMac" });
  await run();
  const [goneKey] = [...store].find(([, v]) => v.t === "Gone");
  store.delete(goneKey);
  await run();
  at(46 * 86_400_000);
  await sync.compact(state, transport, scope, "otherMac", Date.now(), { pruneGrace: 0 }, true);
  assert.ok(!files().some(({ scope: s, file }) => s === scope && JSON.stringify(file).includes(goneKey.slice(3)) && (file.ops ?? []).some((op) => op.k === goneKey && op.v === null)), "control: the tombstone is collected");
  try {
    shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
    const again = await launch();
    again.startSync();
    await settle();
    for (let i = 0; i < 3; i++) await again.syncNow();
    await settle();
    await run();
    assert.ok(!store.has(goneKey), "the deletion holds in the folder");
    assert.ok(!titles().includes("Gone"), "and here");
  } finally {
    Date.now = realNow;
  }
  function sync_emptyJoined() {
    return { records: {}, base: {}, vv: {}, extra: {}, seen: {}, files: {}, damaged: {}, outbox: [], seq: 0, pending: 0, unapplied: [], joined: true };
  }
});

test("D8: a twin made by copying the Mac (same device id, its Keychain item missing so the phrase is entered) never reuses a seq", async () => {
  reset();
  const engine = await onAndSynced();
  const copy = new Map(shell.docs);
  S().addBookmark({ profileId: "default", url: "https://original.example/", title: "On the original" });
  await engine.syncNow();
  await settle();
  const original = new Map(shell.docs);
  restoreDocs(copy);
  fake.unlockResult = false;
  const twin = await launch();
  twin.startSync();
  await settle();
  fake.unlockResult = true;
  assert.ok("ok" in (await twin.enterRecoveryPhrase("/sync", "the phrase")));
  await settle();
  const realRead = native.read;
  const seen = new Set(folder.keys());
  native.read = async (...args) => {
    const listing = await realRead(...args);
    return { ...listing, files: listing.files.filter((f) => !seen.has(f.id) || true) };
  };
  try {
    S().addBookmark({ profileId: "default", url: "https://twin.example/", title: "On the twin" });
    await twin.syncNow();
    await settle();
  } finally {
    native.read = realRead;
  }
  restoreDocs(original);
  const back = await launch();
  back.startSync();
  await settle();
  S().addBookmark({ profileId: "default", url: "https://original2.example/", title: "Original again" });
  await back.syncNow();
  await settle();
  assertNoSeqReused();
});

async function deletedWhileProfileOff({ renamedElsewhereAfter }) {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  const [key, value] = [...other.store].find(([, v]) => v.t === "One");
  const one = Object.values(S().bookmarks.nodes).find((n) => n.kind === "url" && n.title === "One");
  engine.setProfileSynced("default", false);
  await engine.syncNow();
  await settle();
  at(60_000);
  S().removeBookmark(one.id);
  if (renamedElsewhereAfter) {
    at(120_000);
    other.store.set(key, { ...value, t: "Renamed on B after the deletion" });
    await other.sync();
  }
  try {
    at(180_000);
    engine.setProfileSynced("default", true);
    for (let i = 0; i < 3; i++) await engine.syncNow();
    await settle();
    await other.sync();
  } finally {
    Date.now = realNow;
  }
  return { key, other };
}

test("D10a: a deletion made while the profile's sync was off goes out when it's turned back on, if nobody touched the item since", async () => {
  const { key, other } = await deletedWhileProfileOff({ renamedElsewhereAfter: false });
  assert.ok(!other.store.has(key), "the deletion reaches B");
  assert.ok(!titles().includes("One"));
});

test("D10a-conflict: a deletion made while off loses to a rename made elsewhere after it, and the bookmark comes back", { todo: "step 6" }, async () => {
  const { key, other } = await deletedWhileProfileOff({ renamedElsewhereAfter: true });
  assert.equal(other.store.get(key)?.t, "Renamed on B after the deletion", `B's later rename stands (B has ${JSON.stringify(other.store.get(key))})`);
  assert.ok(titles().includes("Renamed on B after the deletion"), "and the bookmark comes back here");
});

test("D10b: on a rejoin after Stop Syncing, a rename made while off wins over an older rename elsewhere", { todo: "step 6" }, async () => {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  const [key, value] = [...other.store].find(([, v]) => v.t === "One");
  await engine.stopSync?.();
  other.store.set(key, { ...value, t: "Older on B" });
  await other.sync();
  at(60_000);
  const one = Object.values(S().bookmarks.nodes).find((n) => n.kind === "url" && n.title === "One");
  S().updateBookmark(one.id, { title: "Renamed while off" });
  try {
    const again = await launch();
    again.startSync();
    await settle();
    assert.ok("ok" in ((await again.turnOnSync?.("/sync")) ?? (await again.enterRecoveryPhrase("/sync", "the phrase"))));
    for (let i = 0; i < 3; i++) await again.syncNow();
    await settle();
    await other.sync();
    assert.ok([...other.store.values()].some((v) => v.t === "Renamed while off"), `B gets the later rename (B has ${[...other.store.values()].map((v) => v.t)})`);
  } finally {
    Date.now = realNow;
  }
});

test("D11b: a setting changed here while joining, before the first cycle, isn't replaced by the synced one", { todo: "step 6" }, async () => {
  reset();
  const engine = await onAndSynced();
  const b = appMac("set:");
  await b.sync();
  b.store.set("set:appearance", { v: "dark" });
  await b.sync();
  void engine;
  shell.docs.clear();
  folder.forEach(() => {});
  const joiner = await launch();
  joiner.startSync();
  await settle();
  assert.ok("ok" in (await joiner.enterRecoveryPhrase("/sync", "the phrase")));
  S().updateSettings({ appearance: "light" });
  for (let i = 0; i < 3; i++) await joiner.syncNow();
  await settle();
  await b.sync();
  assert.equal(S().settings.appearance, "light", "the choice made here stands");
  assert.deepEqual(b.store.get("set:appearance"), { v: "light" });
});

