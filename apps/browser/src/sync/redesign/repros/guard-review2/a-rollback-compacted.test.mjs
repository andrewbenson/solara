import assert from "node:assert/strict";
import { test } from "node:test";
import "../../switchOn.mjs";

const realSetTimeout = globalThis.setTimeout;
globalThis.setTimeout = () => 0;
globalThis.clearTimeout = () => {};
globalThis.__DEV__ = false;

const folder = new Map();
let ids = 0;
const fake = {
  locked: false,
  unlockGate: null,
  unlockResult: true,
  failWrite: null,
  readGate: null,
  forgetGate: null,
  phraseGate: null,
  passwordReads: 0,
  seals: 0,
};
const guard = () => {
  if (fake.locked) throw new Error("locked");
};
globalThis.acTestNativeModules = {
  SolaraSyncAdapter: {
    async createSync(folder) {
      const account = this.newDeviceId();
      if (!(await this.createPhrase(account))) return null;
      await this.createChain(folder);
      return account;
    },
    newDeviceId: () => `dev${++ids}`,
    deviceName: () => "Test Mac",
    createPhrase: async () => {
      if (fake.phraseGate) await fake.phraseGate;
      fake.locked = false;
      return true;
    },
    enterPhrase: async () => {
      if (fake.phraseGate) await fake.phraseGate;
      fake.locked = false;
      return { ok: true };
    },
    createChain: async () => {},
    unlock: async () => {
      if (fake.unlockGate) await fake.unlockGate;
      if (fake.unlockResult) fake.locked = false;
      return fake.unlockResult;
    },
    forget: async () => {
      if (fake.forgetGate) await fake.forgetGate;
    },
    chainStatus: async () => (guard(), fake.chain ?? "ok"),
    write: async (_folder, scope, payload) => {
      guard();
      if (fake.failWrite?.(scope, JSON.parse(payload))) throw new Error("offline");
      const id = `f${++ids}`;
      folder.set(id, { scope, payload });
      return id;
    },
    read: async (_folder, scope, known) => {
      guard();
      const gate = fake.readGate?.(scope);
      if (gate) await gate;
      const here = [...folder].filter(([, f]) => f.scope === scope);
      return { files: here.filter(([id]) => !known.includes(id)).map(([id, f]) => ({ id, payload: f.payload })), pending: [], damaged: [], present: here.map(([id]) => id) };
    },
    remove: async (_folder, _scope, list) => list.forEach((id) => folder.delete(id)),
    deleteChain: async () => folder.clear(),
    sealLocal: async (text) => (fake.seals++, guard(), `sealed:${text}`),
    openLocal: async (sealed) => {
      guard();
      if (fake.openFails) throw new Error("couldn't open");
      return sealed.startsWith("sealed:") ? sealed.slice(7) : null;
    },
    readPasswords: async () => (fake.passwordReads++, []),
  },
};

const shell = await import("../../../../test-native/index.ts");
const sync = await import("../../../../../../../packages/sync/src/index.ts");
const { useBrowser } = await import("../../../../store/browser.ts");
const S = () => useBrowser.getState();
const emptyBookmarks = S().bookmarks;
const settle = async (n = 30) => {
  for (let i = 0; i < n; i++) await new Promise((resolve) => setImmediate(resolve));
};
let launches = 0;
const launch = async () => import(`../../../engine.ts?rev${++launches}`);

function reset() {
  S().hydrate({});
  useBrowser.setState({ bookmarks: emptyBookmarks, bookmarksReady: { default: true } });
  folder.clear();
  shell.docs.clear();
  shell.heldSaves.on = false;
  shell.heldSaves.fail = false;
  shell.heldSaves.only = null;
  shell.heldSaves.queue.length = 0;
  Object.assign(fake, { locked: false, unlockGate: null, unlockResult: true, failWrite: null, readGate: null, forgetGate: null, phraseGate: null, openFails: false, chain: "ok", passwordReads: 0, seals: 0 });
}

const files = () => [...folder.values()].map((f) => ({ scope: f.scope, file: JSON.parse(f.payload), payload: f.payload }));

function assertNoSeqReused() {
  const seen = new Map();
  for (const { scope, file, payload } of files()) {
    if (file.kind !== "log") continue;
    const key = `${scope} ${file.device} ${file.seq}`;
    const ops = JSON.stringify(file.ops);
    assert.equal(seen.get(key) ?? ops, ops, `${key} was published twice with different changes`);
    seen.set(key, ops);
    void payload;
  }
}

async function onAndSynced() {
  const engine = await launch();
  engine.startSync();
  assert.ok("ok" in (await engine.turnOnSync("/sync")));
  S().addBookmark({ profileId: "default", url: "https://one.example/", title: "One" });
  await engine.syncNow();
  await settle();
  return engine;
}

const rawTransport = {
  write: async (scope, payload) => {
    const id = `f${++ids}`;
    folder.set(id, { scope, payload });
    return id;
  },
  read: async (scope, known) => {
    const here = [...folder].filter(([, f]) => f.scope === scope);
    return { files: here.filter(([id]) => !known.includes(id)).map(([id, f]) => ({ id, payload: f.payload })), pending: [], damaged: [], present: here.map(([id]) => id) };
  },
  remove: async (_scope, list) => list.forEach((id) => folder.delete(id)),
};

function otherMac(scope) {
  const store = new Map();
  const state = sync.emptyScope();
  state.joined = true;
  const clock = new sync.Clock("otherMac");
  const adapter = {
    prefix: "bm:",
    extract: () => ({ values: new Map(store) }),
    apply: (visible, changed) => {
      for (const k of changed) visible.has(k) ? store.set(k, visible.get(k)) : store.delete(k);
    },
  };
  return { store, sync: () => sync.syncScope({ scope, state, transport: rawTransport, adapters: [adapter], clock, device: "otherMac" }) };
}

function appMacWithState(prefix) {
  const store = new Map();
  const state = sync.emptyScope();
  state.joined = true;
  const clock = new sync.Clock("appMac");
  const adapter = {
    prefix,
    extract: () => ({ values: new Map(store) }),
    apply: (visible, changed) => {
      for (const k of changed) visible.has(k) ? store.set(k, visible.get(k)) : store.delete(k);
    },
  };
  return {
    store,
    state,
    sync: () => sync.syncScope({ scope: "app", state, transport: rawTransport, adapters: [adapter], clock, device: "appMac" }),
    compact: () => sync.compact(state, rawTransport, "app", "appMac", Date.now(), { pruneGrace: 0 }, true),
  };
}

test("A: a rolled-back (readable) state republishes a setting this Mac sent after the backup, once another Mac replaced it and compacted the folder", async () => {
  reset();
  const engine = await onAndSynced();
  const other = appMacWithState("set:");
  await other.sync();
  const backup = new Map(shell.docs);
  S().updateSettings({ appearance: "light" });
  await engine.syncNow();
  await settle();
  await other.sync();
  assert.deepEqual(other.store.get("set:appearance"), { v: "light" }, "control: B took this Mac's choice");
  other.store.set("set:appearance", { v: "dark" });
  await other.sync();
  await other.compact();
  const lightStillInFolder = files().some(({ scope, file }) => scope === "app" && JSON.stringify(file).includes('"light"'));
  assert.equal(lightStillInFolder, false, "control: compaction left no file carrying light");
  shell.docs.clear();
  for (const [name, contents] of backup) shell.docs.set(name, contents);
  const again = await launch();
  again.startSync();
  await settle();
  for (let i = 0; i < 3; i++) await again.syncNow();
  await settle();
  await other.sync();
  assertNoSeqReused();
  assert.equal(again.useSync.getState().status, "updated");
  assert.deepEqual(other.store.get("set:appearance"), { v: "dark" }, `B's newer choice survives this Mac's rollback (B now has ${JSON.stringify(other.store.get("set:appearance"))})`);
  assert.equal(S().settings.appearance, "dark");
});

test("A-control: same without the compaction (B41's shape) keeps B's choice", async () => {
  reset();
  const engine = await onAndSynced();
  const other = appMacWithState("set:");
  await other.sync();
  const backup = new Map(shell.docs);
  S().updateSettings({ appearance: "light" });
  await engine.syncNow();
  await settle();
  await other.sync();
  other.store.set("set:appearance", { v: "dark" });
  await other.sync();
  shell.docs.clear();
  for (const [name, contents] of backup) shell.docs.set(name, contents);
  const again = await launch();
  again.startSync();
  await settle();
  for (let i = 0; i < 3; i++) await again.syncNow();
  await settle();
  await other.sync();
  assert.deepEqual(other.store.get("set:appearance"), { v: "dark" });
  assert.equal(S().settings.appearance, "dark");
});

function otherMacWithState(scope) {
  const store = new Map();
  const state = sync.emptyScope();
  state.joined = true;
  const clock = new sync.Clock("otherMac");
  const adapter = {
    prefix: "bm:",
    extract: () => ({ values: new Map(store) }),
    apply: (visible, changed) => {
      for (const k of changed) visible.has(k) ? store.set(k, visible.get(k)) : store.delete(k);
    },
  };
  return {
    store,
    state,
    sync: () => sync.syncScope({ scope, state, transport: rawTransport, adapters: [adapter], clock, device: "otherMac" }),
    compact: () => sync.compact(state, rawTransport, scope, "otherMac", Date.now(), { pruneGrace: 0 }, true),
  };
}

function assertSeqsAboveSnapshots(device) {
  for (const { scope, file } of files()) {
    if (file.kind !== "snapshot") continue;
    const floor = file.vv[device] ?? 0;
    const below = files().filter((f) => f.scope === scope && f.file.kind === "log" && f.file.device === device && f.file.seq <= floor && f.file.at > file.at);
    assert.equal(below.length, 0, `${scope}: a batch written after the snapshot reuses seq ${below.map((f) => f.file.seq)} the snapshot already covers`);
  }
}

test("A2: B41 plus compaction: a rolled-back state republishes a rename it took from B over B's newer rename once B compacted", { todo: "step 6" }, async () => {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMacWithState(`p:${syncId}`);
  await other.sync();
  const older = new Map(shell.docs);
  const [key, value] = [...other.store].find(([, v]) => v.t === "One");
  other.store.set(key, { ...value, t: "Renamed on B" });
  await other.sync();
  await engine.syncNow();
  await settle();
  assert.ok(Object.values(S().bookmarks.nodes).some((n) => n.title === "Renamed on B"), "control: this Mac took B's first rename");
  other.store.set(key, { ...value, t: "Renamed again on B" });
  await other.sync();
  await other.compact();
  shell.docs.clear();
  for (const [name, contents] of older) shell.docs.set(name, contents);
  const deviceId = JSON.parse(shell.docs.get("sync.json")).deviceId;
  const again = await launch();
  again.startSync();
  await settle();
  for (let i = 0; i < 3; i++) await again.syncNow();
  await settle();
  await other.sync();
  assertNoSeqReused();
  assertSeqsAboveSnapshots(deviceId);
  assert.equal(other.store.get(key)?.t, "Renamed again on B", `B's newer rename survives the rollback (B now has ${other.store.get(key)?.t})`);
});

test("A3: B54 plus compaction: a rebuilding Mac whose state falls back to before it sent an edit resends it over B's newer one once B compacted", async () => {
  reset();
  await onAndSynced();
  shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
  const rebuilt = await launch();
  rebuilt.startSync();
  await settle();
  const beforeTheEdit = new Map(shell.docs);
  await rebuilt.syncNow();
  await settle();
  S().updateSettings({ appearance: "light" });
  await rebuilt.syncNow();
  await settle();
  const other = appMacWithState("set:");
  await other.sync();
  assert.deepEqual(other.store.get("set:appearance"), { v: "light" }, "control: the edit went out");
  other.store.set("set:appearance", { v: "dark" });
  await other.sync();
  await other.compact();
  shell.docs.clear();
  for (const [name, contents] of beforeTheEdit) shell.docs.set(name, contents);
  const again = await launch();
  again.startSync();
  await settle();
  for (let i = 0; i < 3; i++) await again.syncNow();
  await settle();
  await other.sync();
  assert.deepEqual(other.store.get("set:appearance"), { v: "dark" }, `B's newer choice survives (B has ${JSON.stringify(other.store.get("set:appearance"))})`);
  assert.equal(S().settings.appearance, "dark");
});
