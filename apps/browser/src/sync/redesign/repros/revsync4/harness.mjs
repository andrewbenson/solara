import assert from "node:assert/strict";
import { test } from "node:test";

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
const settle = async (n = 30) => {
  for (let i = 0; i < n; i++) await new Promise((resolve) => setImmediate(resolve));
};
let launches = 0;
const launch = async () => import(`../../../engine.ts?rev${++launches}`);

function reset() {
  S().hydrate({});
  useBrowser.setState({ bookmarksReady: { default: true } });
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
export { fake, folder, shell, sync, useBrowser, S, settle, launch, reset, files, assertNoSeqReused, onAndSynced, rawTransport, otherMac, realSetTimeout };
