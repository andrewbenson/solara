import assert from "node:assert/strict";
import { test } from "node:test";

let status = { active: true, scope: "everything" };
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => status,
    freeze: () => true,
    useSyncOrigins: () => true,
  },
};

const { nativeTabSleepRunning, standDown, startNativeStore } = await import("./nativeStore.ts");

test("native sleep handoff follows actual runner status and workspace ownership", () => {
  startNativeStore();
  assert.equal(nativeTabSleepRunning(), false);
  status = { ...status, nativeTabSleep: true };
  assert.equal(nativeTabSleepRunning(), true);
  status = { ...status, nativeTabSleep: false };
  assert.equal(nativeTabSleepRunning(), false);
  status = { active: true, scope: "settingsAndDownloads", nativeTabSleep: true };
  startNativeStore();
  assert.equal(nativeTabSleepRunning(), false);
  status = { active: true, scope: "everything", nativeTabSleep: true };
  startNativeStore();
  assert.equal(nativeTabSleepRunning(), true);
  standDown();
  assert.equal(nativeTabSleepRunning(), false);
});
