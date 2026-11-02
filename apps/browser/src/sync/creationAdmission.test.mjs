import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.setTimeout = () => 0;
globalThis.clearTimeout = () => {};
globalThis.__DEV__ = false;

const calls = [];
let refuse = false;
let gate;
globalThis.acTestNativeModules = {
  SolaraSyncAdapter: {
    newDeviceId: () => (calls.push("legacyAllocate"), "legacy"),
    deviceName: () => "Test Mac",
    createPhrase: async () => (calls.push("legacyPhrase"), true),
    createChain: async () => calls.push("legacyChain"),
    createSync: async (folder, permit) => {
      calls.push(["createSync", folder, permit]);
      if (gate) await gate;
      if (refuse) throw new Error("discovery changed");
      return "new-account";
    },
    forget: async (account) => calls.push(["forget", account]),
    sealLocal: async (text) => `sealed:${text}`,
    openLocal: async (text) => text.startsWith("sealed:") ? text.slice(7) : null,
    unlock: async () => true,
    chainStatus: async () => "ok",
    read: async () => ({ files: [], pending: [], damaged: [], present: [] }),
    write: async () => "file",
    remove: async () => {},
    readPasswords: async () => null,
  },
};

const shell = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
let serial = 0;
async function launch() {
  useBrowser.getState().hydrate({});
  useBrowser.setState({ bookmarksReady: { default: true } });
  shell.docs.clear();
  calls.length = 0;
  refuse = false;
  gate = null;
  return import(`./engine.ts?creation-${++serial}`);
}

test("C01 direct Turn On passes no consent and cannot reach legacy phrase or chain creation", async () => {
  const engine = await launch();
  assert.deepEqual(await engine.turnOnSync("/sync"), { ok: true });
  assert.deepEqual(calls, [["createSync", "/sync", null]]);
});

test("C02 late candidates refused by native admission do not enable sync or fall back", async () => {
  const engine = await launch();
  refuse = true;
  assert.ok("error" in await engine.turnOnSync("/sync"));
  assert.equal(engine.useSync.getState().enabled, false);
  assert.deepEqual(calls, [["createSync", "/sync", null]]);
});

test("C03 separate creation passes the captured inspection verbatim", async () => {
  const engine = await launch();
  assert.deepEqual(await engine.turnOnSync("/sync", "captured-inspection"), { ok: true });
  assert.deepEqual(calls, [["createSync", "/sync", "captured-inspection"]]);
});

test("C05 duplicate submit while native admission is held cannot create twice", async () => {
  const engine = await launch();
  let finish;
  gate = new Promise((resolve) => { finish = resolve; });
  const first = engine.turnOnSync("/sync", "one-use");
  const second = await engine.turnOnSync("/sync", "one-use");
  assert.ok("error" in second);
  finish();
  assert.deepEqual(await first, { ok: true });
  assert.deepEqual(calls, [["createSync", "/sync", "one-use"]]);
});

test("C06 API 36 without createSync refuses creation without calling legacy APIs", async () => {
  const engine = await launch();
  const native = globalThis.acTestNativeModules.SolaraSyncAdapter;
  const createSync = native.createSync;
  delete native.createSync;
  try {
    assert.deepEqual(await engine.turnOnSync("/sync"), { error: "Sync creation isn’t available in this build. Rebuild the app." });
    assert.deepEqual(calls, []);
    assert.equal(engine.useSync.getState().enabled, false);
  } finally {
    native.createSync = createSync;
  }
});

test("C07 API 36 without inspection capability returns no inspection", async () => {
  await launch();
  const { syncHandlers } = await import("../components/settings/native/sync.ts");
  let result;
  try { result = await syncHandlers["sync.inspectCreation"]("/sync"); } catch (error) { result = error.message; }
  assert.equal(result, null);
  assert.deepEqual(calls, []);
});
