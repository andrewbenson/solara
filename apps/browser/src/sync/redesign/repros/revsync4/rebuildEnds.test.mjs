import "../../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import "../../switchOn.mjs";
const { fake, folder, shell, sync, S, settle, launch, reset, files, otherMac, useBrowser, onAndSynced, rawTransport, realSetTimeout } = await import('./harness.mjs');

const native = globalThis.acTestNativeModules.SolaraSyncAdapter;
const realReadPasswords = native.readPasswords;

test("R-unapplied: a rebuild that ends while bookmarks couldn't be applied republishes stale local bookmarks on the next cycle", async () => {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  const [key, value] = [...other.store].find(([, v]) => v.t === "One");
  other.store.set(key, { ...value, t: "Renamed on B" });
  await other.sync();
  shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
  const again = await launch();
  again.startSync();
  await settle();
  useBrowser.setState({ bookmarksReady: {} });
  await again.syncNow();
  await settle();
  assert.equal(JSON.parse(shell.docs.get("sync.json")).rebuilding, undefined, "the rebuild ended although bookmarks were never applied");
  useBrowser.setState({ bookmarksReady: { default: true } });
  await again.syncNow();
  await again.syncNow();
  await settle();
  await other.sync();
  assert.equal(other.store.get(key)?.t, "Renamed on B", `B's rename survives (B now has ${other.store.get(key)?.t})`);
});

function passwordMac(scope) {
  const store = new Map();
  const state = sync.emptyScope();
  state.joined = true;
  const clock = new sync.Clock("pwMac");
  const adapter = {
    prefix: "pw:",
    extract: () => ({ values: new Map(store) }),
    apply: (visible, changed) => {
      for (const k of changed) visible.has(k) ? store.set(k, visible.get(k)) : store.delete(k);
    },
  };
  return { store, sync: () => sync.syncScope({ scope, state, transport: rawTransport, adapters: [adapter], clock, device: "pwMac" }) };
}

test("R-passwords: a rebuilt passwords scope keeps the stale local password, then republishes it over B's newer one", async () => {
  reset();
  const here = new Map([["https://site.example\nme", { origin: "https://site.example/", url: "https://site.example/", username: "me", password: "old", created: 1 }]]);
  shell.passwordStores.set(null, here);
  native.readPasswords = async () => [...here.values()];
  const realST = globalThis.setTimeout;
  globalThis.setTimeout = (fn, ms) => (ms === 250 ? realSetTimeout(fn, 0) : 0);
  try {
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    const key = "pw:https://site.example\nme";
    assert.equal(b.store.get(key)?.p, "old", "control: B has this Mac's password");
    b.store.set(key, { ...b.store.get(key), p: "new-from-B" });
    await b.sync();
    shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
    const again = await launch();
    again.startSync();
    await settle();
    for (let i = 0; i < 3; i++) {
      await again.syncNow();
      await settle(60);
    }
    const realNow = Date.now;
    Date.now = () => realNow() + 60_000;
    try {
      console.log("rebuilding after the first cycles:", JSON.parse(shell.docs.get("sync.json")).rebuilding, "local password:", here.get("https://site.example\nme")?.password);
      await again.syncNow();
      await settle(60);
    } finally {
      Date.now = realNow;
    }
    await b.sync();
    assert.equal(b.store.get(key)?.p, "new-from-B", `B's newer password survives this Mac's rebuild (B has ${b.store.get(key)?.p}, this Mac ${here.get("https://site.example\nme")?.password})`);
  } finally {
    globalThis.setTimeout = realST;
    native.readPasswords = realReadPasswords;
  }
});

test("R-lock: an adapter that throws while the rebuild baseline is taken locks a healthy, unlocked Mac", async () => {
  reset();
  await onAndSynced();
  shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
  native.readPasswords = async () => {
    throw new Error("password store not ready");
  };
  try {
    const again = await launch();
    again.startSync();
    await settle();
    assert.notEqual(again.useSync.getState().status, "locked", `status ${again.useSync.getState().status}: ${again.useSync.getState().error}`);
  } finally {
    native.readPasswords = realReadPasswords;
  }
});
