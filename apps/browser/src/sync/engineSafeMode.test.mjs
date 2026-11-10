import "../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.setTimeout = () => 0;
globalThis.clearTimeout = () => {};
globalThis.__DEV__ = false;

const folder = new Map();
const calls = { unlock: 0, write: 0, read: 0 };
let ids = 0;
let safeMode = null;
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: false, reason: "not launched", ...(safeMode ? { safeMode } : {}) }),
  },
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
    forget: async () => {},
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
const { startNativeStore, nativeSafeMode } = await import("../store/nativeStore.ts");
const S = () => useBrowser.getState();

test("a safe launch starts no sync, so its empty workspace never reaches the other Macs as deletions", async () => {
  S().hydrate({});
  useBrowser.setState({ bookmarksReady: { default: true } });
  startNativeStore();
  assert.equal(nativeSafeMode(), false);
  const before = await import("./engine.ts?before");
  before.startSync();
  assert.ok("ok" in (await before.turnOnSync("/sync")));
  await before.syncNow();
  assert.match(shell.docs.get("sync.json") ?? "", /"enabled":true/);

  safeMode = "failedLaunches";
  startNativeStore();
  assert.equal(nativeSafeMode(), true);
  const docsBefore = new Map(shell.docs);
  const seen = { ...calls };
  const safe = await import("./engine.ts?safe");
  safe.startSync();
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setImmediate(resolve));
  S().hydrate({});
  S().updateSettings({ appearance: "dark" });
  S().addBookmark({ profileId: "default", url: "https://from-the-safe-window.example/", title: "Safe" });
  await safe.syncNow();
  assert.equal(safe.useSync.getState().status, "unavailable");
  assert.match(safe.useSync.getState().error ?? "", /safe mode/);
  assert.ok("error" in (await safe.turnOnSync("/sync")));
  assert.deepEqual(calls, seen);
  assert.deepEqual(new Map(shell.docs), docsBefore);
});
