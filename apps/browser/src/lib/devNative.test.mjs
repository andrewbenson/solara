import assert from "node:assert/strict";
import { test } from "node:test";

let frozen = false;
let invalid = false;
let active = true;
let absent = false;
let reads = 0;
let title = "native";
const sent = [];
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => (active ? { active: true, frozen } : { active: false, reason: "failed" }),
    snapshot: () => { reads++; return absent ? null : invalid ? "{invalid" : JSON.stringify({ rev: 0, data: { windows: {}, windowOrder: [], tabs: { t1: { title } }, settings: { appearance: "dark" } } }); },
    dispatch: (json) => { sent.push(JSON.parse(json)); return JSON.stringify({ rev: 0, result: "native-result" }); },
  },
};
const { useBrowser } = await import("../store/browser.ts");
const { startNativeStore } = await import("../store/nativeStore.ts");
const { installDevNative } = await import("./devNative.ts");

test("native seam reads each snapshot independently of the replica and dispatches only workspace commands", () => {
  globalThis.__DEV__ = true;
  startNativeStore();
  const ac = {};
  installDevNative(ac);
  assert.equal(ac.native.state().tabs.t1.title, "native");
  useBrowser.setState({ tabs: { t1: { title: "replica-only" } } });
  assert.equal(ac.native.state().tabs.t1.title, "native");
  title = "native-changed";
  assert.equal(ac.native.state().tabs.t1.title, "native-changed");
  assert.equal(reads, 3);
  assert.deepEqual(ac.native.status(), { active: true, frozen: false });
  assert.equal(ac.native.command("updateSettings", { appearance: "light" }), "native-result");
  assert.deepEqual(sent, [{ name: "updateSettings", args: [{ appearance: "light" }] }]);
  assert.throws(() => ac.native.command("applyState", {}), /workspace command/);
  ac.native.command("updateTab", "t1", { customTitle: undefined });
  assert.deepEqual(sent[1], { name: "updateTab", args: ["t1", { $unset: ["customTitle"] }] });
  frozen = true;
  assert.equal(ac.native.state(), null);
  frozen = false;
  invalid = true;
  assert.equal(ac.native.state(), null);
  invalid = false;
  absent = true;
  assert.equal(ac.native.state(), null);
  absent = false;
  active = false;
  assert.equal(ac.native.state(), null);
  assert.equal(ac.native.status().reason, "failed");
});

test("native seam is absent outside development", () => {
  globalThis.__DEV__ = false;
  const ac = {};
  installDevNative(ac);
  assert.equal(Object.hasOwn(ac, "native"), false);
});

const refusalChecks = await import("./devRefusalChecks.ts");

test("named refusal checks exercise real fallback mutations only without native ownership in development", () => {
  globalThis.__DEV__ = true;
  active = false;
  startNativeStore();
  useBrowser.setState({ tabs: {}, windows: {}, windowOrder: [] });
  const changed = refusalChecks.exerciseWorkspace();
  assert.equal(changed.tabs, 1);
  assert.equal(changed.appearance, true);
  assert.equal(typeof refusalChecks.exerciseDownloads(), "string");
  assert.deepEqual(useBrowser.getState().downloads, []);
  const count = useBrowser.getState().windowOrder.length;
  refusalChecks.exerciseWindowAfterCancel();
  assert.equal(useBrowser.getState().windowOrder.length, count + 1);
  globalThis.__DEV__ = false;
  assert.throws(() => refusalChecks.exerciseWorkspace(), /development workspace/);
  globalThis.__DEV__ = true;
  active = true;
  startNativeStore();
  assert.throws(() => refusalChecks.exerciseWorkspace(), /development workspace/);
});
