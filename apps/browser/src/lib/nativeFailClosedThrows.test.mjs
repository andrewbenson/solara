import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: true }),
    snapshot: () => { throw new Error("snapshot unavailable"); },
    dispatch: () => null,
    catchUp: () => null,
    flush: () => false,
    freeze: () => ((globalThis.__frozenNative = true), true),
    addListener: () => ({ remove() {} }),
  },
};

const { docs } = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
const { flushPersistence, startPersistence } = await import("./persist.ts");
const { nativeOwnsWorkspace, nativeStoreActive } = await import("../store/nativeStore.ts");

test("when the native store owns the workspace but its snapshot throws, nothing is saved and the failure is reported", () => {
  const session = JSON.stringify({ version: 2, settings: { searchEngine: "bing" }, windows: [], tabs: [] });
  docs.set("session.json", session);
  docs.delete("downloads.json");
  const errors = [];
  const error = console.error;
  console.error = (...args) => errors.push(args.join(" "));
  try {
    startPersistence();
  } finally {
    console.error = error;
  }
  assert.ok(errors.some((e) => e.includes("snapshot unavailable")));
  useBrowser.getState().createWindow({ url: "https://lost.example/" });
  flushPersistence({ final: true });
  assert.equal(docs.get("session.json"), session);
  assert.equal(docs.has("downloads.json"), false);
  assert.ok(errors.some((e) => e.includes("saves nothing")));
  assert.equal(nativeOwnsWorkspace(), false, "the tab strip and every other writer stop feeding the native store");
  assert.equal(nativeStoreActive(), false);
  assert.equal(globalThis.__frozenNative, true, "the native writer is frozen too");
});
