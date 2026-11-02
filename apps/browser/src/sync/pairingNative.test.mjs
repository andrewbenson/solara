import assert from "node:assert/strict";
import { test } from "node:test";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

globalThis.__DEV__ = false;
const timers = [];
globalThis.setTimeout = (fn, ms) => { timers.push({ fn, ms }); return timers.length; };
globalThis.clearTimeout = () => {};
const listeners = [];
const calls = { query: 0, consume: 0, initialize: 0, create: 0, write: 0 };
const request = { handle: "opaque-handle", folder: "/sync", folderIdentity: "volume:inode", cid: "b".repeat(32), generation: 1, stopGeneration: 0 };
let marker;
let saved = false;
const native = {
  invalidatePairing: () => {},
  addListener: (name, listener) => { assert.equal(name, "pairingInstallationReady"); listeners.push(listener); return { remove() {} }; },
  consumePairingInstallation: async (_handle, priorState) => {
    calls.consume++;
    marker = { transaction: "a".repeat(64), folder: request.folder, folderIdentity: request.folderIdentity, cid: request.cid, deviceId: "baaaaaaaaaaaaaaaaaaaaaaaaa", account: "baaaaaaaaaaaaaaaaaaaaaaaaa", generation: 1, stopGeneration: 0, phase: "prepared", route: "onboarding", priorState };
    return marker;
  },
  savePairingInstallation: async () => { saved = true; },
  readPairingInstallation: async (value) => ({ ...value, phase: saved ? "key-saved" : "prepared" }),
  recoverPairingInstallation: async () => null,
  stopPairingInstallation: async () => {},
  reconcilePairingApplied: async () => null,
  checkpointPairingApplied: async () => { throw new Error("no authoritative adapter"); },
  acknowledgePairingInitialization: async () => { calls.initialize++; if (calls.initialize === 1) throw new Error("transient private initialization failure"); },
  acknowledgePairingReady: async () => {},
  pairingInstallationRequest: async () => { calls.query++; return request; },
  newDeviceId: () => { calls.create++; return "forbidden-device"; },
  createSync: async () => { calls.create++; return "forbidden-account"; },
  deviceName: () => "Native Mac",
  write: async () => { calls.write++; return "file"; },
  read: async () => ({ files: [], pending: [], damaged: [], present: [] }),
  sealLocal: async (text) => `sealed:${text}`,
  openLocal: async () => null,
  forget: async () => {},
};
globalThis.acTestNativeModules = { SolaraSyncAdapter: native };
const shell = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
const adapter = await import("./pairingNative.ts");
const settle = async () => { for (let i = 0; i < 40; i++) await new Promise((resolve) => setImmediate(resolve)); };

test("startup subscribes once before querying the native admitted installation and uses joinFromPairing", async () => {
  useBrowser.getState().hydrate({});
  shell.docs.clear();
  adapter.startPairingSync();
  adapter.startPairingSync();
  assert.equal(listeners.length, 1, "one JS subscriber per runtime");
  await settle();
  assert.equal(calls.consume, 1);
  assert.equal(calls.initialize, 1);
  const document = JSON.parse(shell.docs.get("sync.json"));
  assert.equal(document.v, 2);
  assert.equal(document.joinTransaction, "a".repeat(64));
  assert.equal(document.bootstrap.phase, "awaiting-profile");
  assert.equal(calls.create + calls.write, 0);
  const retry = timers.find((timer) => timer.ms === 1000);
  assert.equal(typeof retry?.fn, "function", "committed initialization retries without a new pairing session");
  retry.fn();
  await settle();
  assert.equal(calls.initialize, 2);
  assert.equal(calls.consume, 1, "retry resumes the existing durable v2 transaction");
  listeners[0]();
  listeners[0]();
  await settle();
  assert.equal(calls.consume, 1);
});

const requiredMethods = ["addListener", "invalidatePairing", "consumePairingInstallation", "savePairingInstallation", "readPairingInstallation", "recoverPairingInstallation", "stopPairingInstallation", "reconcilePairingApplied", "checkpointPairingApplied", "acknowledgePairingInitialization", "acknowledgePairingReady", "pairingInstallationRequest"];
const startupProbe = `
import assert from "node:assert/strict";
globalThis.__DEV__ = false;
globalThis.setTimeout = () => 0;
globalThis.clearTimeout = () => {};
const calls = { listen: 0, query: 0, consume: 0, recover: 0, unlock: 0 };
const native = {
  addListener: () => { calls.listen++; return { remove() {} }; },
  invalidatePairing: () => {},
  consumePairingInstallation: async () => { calls.consume++; return null; },
  savePairingInstallation: async () => {},
  readPairingInstallation: async () => null,
  recoverPairingInstallation: async () => { calls.recover++; return null; },
  stopPairingInstallation: async () => {},
  reconcilePairingApplied: async () => null,
  checkpointPairingApplied: async () => null,
  acknowledgePairingInitialization: async () => {},
  acknowledgePairingReady: async () => {},
  pairingInstallationRequest: async () => { calls.query++; return null; },
  deviceName: () => "Native Mac",
  unlock: async () => { calls.unlock++; return true; },
  openLocal: async () => null,
  sealLocal: async (text) => text,
  read: async () => ({ files: [], pending: [], damaged: [], present: [] }),
};
delete native[process.env.PAIRING_MISSING];
globalThis.acTestNativeModules = { SolaraSyncAdapter: native };
const shell = await import(${JSON.stringify(new URL("../test-native/index.ts", import.meta.url).href)});
const { useBrowser } = await import(${JSON.stringify(new URL("../store/browser.ts", import.meta.url).href)});
useBrowser.getState().hydrate({});
shell.docs.set("sync.json", JSON.stringify({ v: 1, enabled: true, folder: "/sync", deviceId: "ordinary-device", clock: null, types: {}, profiles: {}, scopes: {}, lastSyncedAt: null, setupAt: null, joining: false }));
const { startPairingSync } = await import(${JSON.stringify(new URL("./pairingNative.ts", import.meta.url).href)});
startPairingSync();
startPairingSync();
for (let i = 0; i < 40; i++) await new Promise((resolve) => setImmediate(resolve));
assert.equal(calls.listen, 0, "partial pairing capability cannot subscribe");
assert.equal(calls.query + calls.consume + calls.recover, 0, "partial pairing capability cannot query or admit");
assert.equal(calls.unlock, 1, "ordinary sync still starts");
assert.equal(JSON.parse(shell.docs.get("sync.json")).v, 1);
`;
for (const missing of requiredMethods) {
  test(`startup without ${missing} uses ordinary sync without pairing subscription or admission`, () => {
    const result = spawnSync(process.execPath, ["--no-warnings", "--import", fileURLToPath(new URL("../test-loader.mjs", import.meta.url)), "--input-type=module", "--eval", startupProbe], { env: { ...process.env, PAIRING_MISSING: missing }, encoding: "utf8", timeout: 20000 });
    assert.equal(result.status, 0, result.stderr || result.stdout);
  });
}
