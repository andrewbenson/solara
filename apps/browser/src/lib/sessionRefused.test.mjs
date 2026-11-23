import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: false, reason: "the native store refused to import: session.json could not be parsed", refusedSession: "/data/session.json" }),
    snapshot: () => null,
    dispatch: () => null,
    catchUp: () => null,
    flush: () => false,
    freeze: () => true,
    addListener: () => ({ remove() {} }),
  },
};

const { docs, documentReads } = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
const { useToasts } = await import("../components/layout/toasts.ts");
const { flushPersistence, resumePersistence, startPersistence } = await import("./persist.ts");
const { persistenceRefused } = await import("./persistLatch.ts");

test("when the native store refused the session, JS never reads it and saves nothing, even after a resumed quit", () => {
  const session = "{ not json";
  const downloads = JSON.stringify({ version: 2, downloads: [] });
  docs.set("session.json", session);
  docs.set("downloads.json", downloads);
  const errors = [];
  const error = console.error;
  console.error = (...args) => errors.push(args.join(" "));
  try {
    startPersistence();
  } finally {
    console.error = error;
  }
  assert.deepEqual(documentReads.filter((name) => name === "session.json" || name === "downloads.json"), []);
  const s = useBrowser.getState();
  const windowId = s.createWindow({});
  s.updateSettings({ appearance: "dark" });
  s.upsertDownload({ id: "d", url: "https://e/", state: "complete", profile: "" });
  flushPersistence({ final: true });
  resumePersistence();
  flushPersistence({ final: true });
  assert.equal(docs.get("session.json"), session);
  assert.equal(docs.get("downloads.json"), downloads);
  assert.equal(docs.has("launch-look.json"), false);
  assert.equal(persistenceRefused(), true);
  assert.equal(useToasts.getState().notices[windowId], undefined, "the read-only session notice is gone with the JS read-only session");
  assert.ok(errors.some((e) => e.includes("saves nothing") && e.includes("refused to import")), errors.join("\n"));
});
