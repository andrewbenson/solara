import assert from "node:assert/strict";
import { test } from "node:test";
import { docs, documentChanges, documentReads } from "../test-native/index.ts";
import { useBrowser } from "../store/browser.ts";
import { flushPersistence, resumePersistence, startPersistence } from "./persist.ts";
import { persistenceRefused, refusedSessionPath } from "./persistLatch.ts";

test("a missing store module refuses persistence without reading or writing the JS session", () => {
  const session = JSON.stringify({ version: 2, settings: { searchEngine: "bing" }, windows: [], tabs: [] });
  docs.set("session.json", session);
  const reads = documentReads.length;
  const changes = documentChanges.length;
  const stop = startPersistence();
  assert.equal(persistenceRefused(), true);
  assert.match(refusedSessionPath(), /the native store module is missing/);
  assert.deepEqual(documentReads.slice(reads).filter((n) => n === "session.json"), []);
  useBrowser.getState().updateSettings({ appearance: "dark" });
  flushPersistence({ final: true });
  resumePersistence();
  flushPersistence({ final: true });
  stop();
  assert.equal(docs.get("session.json"), session);
  assert.deepEqual(documentChanges.slice(changes), []);
});
