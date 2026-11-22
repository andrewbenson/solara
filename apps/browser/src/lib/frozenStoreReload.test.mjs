import assert from "node:assert/strict";
import { test } from "node:test";

const sent = [];
let freezes = 0;
const data = { settings: { searchEngine: "duckduckgo", chosen: ["searchEngine"], inferred: [] }, downloads: [] };
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: true, frozen: true }),
    snapshot: () => JSON.stringify({ rev: 1, data }),
    dispatch(json, sinceRev) {
      sent.push(...[JSON.parse(json)].flat().map((c) => c.name));
      return JSON.stringify({ rev: Math.max(1, sinceRev), patches: [] });
    },
    catchUp: () => JSON.stringify({ rev: 1, patches: [] }),
    flush: () => "saved",
    freeze: () => {
      freezes++;
      return true;
    },
    addListener: () => ({ remove() {} }),
  },
};

const { docs, documentWrites } = await import("../test-native/index.ts");
docs.set("session.json", JSON.stringify({ version: 2, settings: { searchEngine: "bing" }, windows: [], tabs: [] }));
const before = docs.get("session.json");
const { useBrowser } = await import("../store/browser.ts");
const { flushPersistence, startPersistence } = await import("./persist.ts");
const { nativeOwnsWorkspace, nativeStoreActive } = await import("../store/nativeStore.ts");

test("a JS reload over a frozen native store saves nothing and writes no session.json", () => {
  const errors = [];
  const error = console.error;
  console.error = (...args) => errors.push(args.join(" "));
  try {
    startPersistence();
  } finally {
    console.error = error;
  }
  assert.equal(nativeOwnsWorkspace(), false);
  assert.equal(nativeStoreActive(), false);
  assert.ok(freezes >= 1, "fail-closed keeps the native store frozen");
  assert.ok(errors.some((message) => message.includes("frozen")), errors.join("\n"));
  useBrowser.setState({ settings: { ...useBrowser.getState().settings, searchEngine: "mojeek" } });
  flushPersistence();
  flushPersistence({ final: true });
  assert.deepEqual(documentWrites.filter((name) => name === "session.json"), []);
  assert.equal(docs.get("session.json"), before);
  assert.deepEqual(sent.filter((name) => name === "attachReplicaProfiles" || name === "applyState"), []);
});
