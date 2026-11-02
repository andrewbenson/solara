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
const native = globalThis.acTestNativeModules.SolaraSyncAdapter;
const realReadPasswords = native.readPasswords;
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
function appMac(prefix) {
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
  return { store, state, sync: () => sync.syncScope({ scope: "app", state, transport: rawTransport, adapters: [adapter], clock, device: "appMac" }) };
}

async function chosenWhileLocked({ gated }) {
  reset();
  const engine = await onAndSynced();
  const other = appMac("set:");
  await other.sync();
  other.store.set("set:appearance", { v: "dark" });
  await other.sync();
  await engine.syncNow();
  await settle();
  assert.equal(S().settings.appearance, "dark", "control: this Mac took B's dark");
  shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
  let unlock;
  if (gated) fake.unlockGate = new Promise((resolve) => (unlock = resolve));
  const again = await launch();
  again.startSync();
  await settle();
  if (!gated) await settle();
  S().updateSettings({ appearance: "light" });
  await settle();
  if (gated) {
    unlock();
    fake.unlockGate = null;
    await settle();
  }
  for (let i = 0; i < 3; i++) await again.syncNow();
  await settle();
  await other.sync();
  assertNoSeqReused();
  assert.equal(again.useSync.getState().status, "updated");
  assert.equal(S().settings.appearance, "light", `the choice made after the loss stands here (this Mac has ${S().settings.appearance})`);
  assert.deepEqual(other.store.get("set:appearance"), { v: "light" }, `and reaches B (B has ${JSON.stringify(other.store.get("set:appearance"))})`);
}

test("R1: after losing its state, a setting first chosen here while the Mac is still unlocking is replaced by the folder's older value", () => chosenWhileLocked({ gated: true }));
test("R1-control: same choice made after the state loads is kept and published", () => chosenWhileLocked({ gated: false }));

test("R1b: same while the Mac sits locked at launch until the recovery phrase is entered", async () => {
  reset();
  const engine = await onAndSynced();
  const other = appMac("set:");
  await other.sync();
  other.store.set("set:appearance", { v: "dark" });
  await other.sync();
  await engine.syncNow();
  await settle();
  assert.equal(S().settings.appearance, "dark", "control: this Mac took B's dark");
  shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
  fake.unlockResult = false;
  const again = await launch();
  again.startSync();
  await settle();
  assert.equal(again.useSync.getState().status, "locked", "control: this Mac is locked");
  S().updateSettings({ appearance: "light" });
  await settle();
  fake.unlockResult = true;
  assert.ok("ok" in (await again.enterRecoveryPhrase("/sync", "the phrase")));
  await settle();
  for (let i = 0; i < 3; i++) await again.syncNow();
  await settle();
  await other.sync();
  assertNoSeqReused();
  assert.equal(again.useSync.getState().status, "updated");
  assert.equal(S().settings.appearance, "light", `the choice made while locked stands here (this Mac has ${S().settings.appearance})`);
  assert.deepEqual(other.store.get("set:appearance"), { v: "light" }, `and reaches B (B has ${JSON.stringify(other.store.get("set:appearance"))})`);
});

test("R1-mechanism: same as R1, but appearance was chosen on this Mac before the loss, so the launch note sees the key", async () => {
  reset();
  const engine = await onAndSynced();
  const other = appMac("set:");
  await other.sync();
  S().updateSettings({ appearance: "dark" });
  await engine.syncNow();
  await settle();
  await other.sync();
  assert.deepEqual(other.store.get("set:appearance"), { v: "dark" });
  shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
  let unlock;
  fake.unlockGate = new Promise((resolve) => (unlock = resolve));
  const again = await launch();
  again.startSync();
  await settle();
  S().updateSettings({ appearance: "light" });
  await settle();
  unlock();
  fake.unlockGate = null;
  await settle();
  for (let i = 0; i < 3; i++) await again.syncNow();
  await settle();
  await other.sync();
  assert.equal(S().settings.appearance, "light");
  assert.deepEqual(other.store.get("set:appearance"), { v: "light" });
});
