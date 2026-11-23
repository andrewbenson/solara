import "../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.setTimeout = () => 0;
globalThis.clearTimeout = () => {};
globalThis.__DEV__ = false;

const folder = new Map();
const calls = { unlock: 0, write: 0, read: 0, deleteChain: 0, forget: 0 };
let ids = 0;
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
    createPhrase: async () => true,
    createChain: async () => {},
    unlock: async () => (calls.unlock++, true),
    forget: async () => { calls.forget++; },
    deleteChain: async () => { calls.deleteChain++; },
    chainStatus: async () => "ok",
    write: async (_folder, scope, payload) => {
      calls.write++;
      const id = `f${folder.size + 1}`;
      folder.set(id, { scope, payload });
      return id;
    },
    read: async (_folder, scope, known) => {
      calls.read++;
      const here = [...folder].filter(([, f]) => f.scope === scope);
      const files = here.filter(([id]) => !known.includes(id)).map(([id, f]) => ({ id, payload: f.payload }));
      return { files, pending: [], damaged: [], present: here.map(([id]) => id) };
    },
    remove: async (_folder, _scope, list) => list.forEach((id) => folder.delete(id)),
    sealLocal: async (text) => `sealed:${text}`,
    openLocal: async (sealed) => (sealed.startsWith("sealed:") ? sealed.slice(7) : null),
    readPasswords: async () => null,
  },
};

const shell = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
const S = () => useBrowser.getState();
test("turning sync off or changing what it syncs does nothing while persistence is refused, so a session that saves nothing can't delete or rewrite sync data", async () => {
  S().hydrate({});
  useBrowser.setState({ bookmarksReady: { default: true } });
  const before = await import("./engine.ts?before");
  before.startSync();
  assert.ok("ok" in (await before.turnOnSync("/sync")));
  await before.syncNow();
  assert.match(shell.docs.get("sync.json") ?? "", /"enabled":true/);

  shell.unreadableDocs.set("session.json", "Permission denied");
  const { startPersistence } = await import("../lib/persist.ts");
  startPersistence();
  const docsBefore = new Map(shell.docs);
  const seen = { ...calls };
  const changesBefore = shell.documentChanges.length;
  const refused = await import("./engine.ts?refused");
  refused.startSync();
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setImmediate(resolve));
  refused.setTypeSynced("history", false);
  refused.setProfileSynced("default", false);
  const hostCalls = [];
  const host = new Proxy({}, { get: (_target, name) => (...args) => (hostCalls.push(String(name)), Promise.resolve(null)) });
  assert.equal(await refused.resumePairingInitialization(host), false);
  assert.ok("error" in (await refused.joinFromPairing({ handle: "h", stopGeneration: 0, generation: 1 }, host)));
  assert.deepEqual(hostCalls, [], "pairing recovery and join never touch the installation host");
  await refused.stopSync({ deleteData: true });
  assert.equal(refused.useSync.getState().status, "unavailable");
  assert.match(refused.useSync.getState().error ?? "", /couldn't read its saved session/);
  assert.deepEqual(calls, seen, "no chain deleted, no device forgotten, nothing read or written in the sync folder");
  assert.deepEqual(shell.documentChanges.slice(changesBefore).filter((change) => / sync/.test(change)), []);
  assert.deepEqual(new Map(shell.docs), docsBefore);
});
