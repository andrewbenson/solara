import assert from "node:assert/strict";
import { test } from "node:test";

let active = false;
let safe = true;
const sent = [];
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active, ...(safe ? { safeMode: "option" } : {}) }),
    dispatch: (json) => { sent.push(...[JSON.parse(json)].flat()); return JSON.stringify({ rev: 0 }); },
    addListener: () => ({ remove() {} }),
  },
};
const { shellNativeModules } = await import("../test-native/shell.ts");
const notices = [];
shellNativeModules.SolaraShell.confirm = async (options) => { notices.push(options); return { confirmed: false, suppressed: false }; };
const { useBrowser } = await import("../store/browser.ts");
const { startNativeStore, attachReplica } = await import("../store/nativeStore.ts");

test("safe profile creation refuses visibly before stranding user writes in a transient engine profile", () => {
  startNativeStore();
  const before = useBrowser.getState().profiles;
  assert.equal(useBrowser.getState().createProfile({ name: "Transient" }), "");
  assert.equal(useBrowser.getState().profiles, before);
  assert.match(notices.at(-1).message, /cannot be saved|can't be saved/i);
  assert.match(notices.at(-1).message, /normal/i);
  safe = false;
  startNativeStore();
  const id = useBrowser.getState().createProfile({ name: "Durable normal profile" });
  assert.ok(id);
  assert.equal(useBrowser.getState().profiles[id].name, "Durable normal profile");
  safe = true;
  active = true;
  startNativeStore();
  attachReplica(useBrowser);
  const wrapped = useBrowser.getState().profiles;
  assert.equal(useBrowser.getState().createProfile({ name: "Transient native" }), "");
  assert.equal(useBrowser.getState().profiles, wrapped);
  assert.equal(sent.some((command) => command.name === "createProfile"), false);
  assert.equal(notices.length, 2);
});
