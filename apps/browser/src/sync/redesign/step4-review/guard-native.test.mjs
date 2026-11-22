import assert from "node:assert/strict";
import { test } from "node:test";
import { fixedBy } from "../switchOn.mjs";

globalThis.acTestNativeModules = {
  ...globalThis.acTestNativeModules,
  SolaraStoreAdapter: {
    status: () => ({ active: true }),
    snapshot: () => JSON.stringify({ rev: 0, data: { settings: null, downloads: [] } }),
    dispatch: () => JSON.stringify({ rev: 0, patches: [] }),
    catchUp: () => null,
    flush: () => true,
    freeze: () => true,
  },
};
const shell = await import("../../../test-native/index.ts");
const nativeStore = await import("../../../store/nativeStore.ts");
const host = await import("../../journalHost.ts");

test("GUARD-native: with the native store active, a lost journal publishes nothing, since the anchor isn't next to the items yet", fixedBy("step 4"), () => {
  assert.ok(nativeStore.startNativeStore().active, "control: the native store is active");
  shell.docs.clear();
  host.forgetEditJournal();
  shell.docs.set("sync-edits.json", "{broken");
  shell.docs.set("sync-edits.gen", JSON.stringify({ v: 1, g: 3, T: 1000, vv: { app: {} }, gT: 0 }));
  shell.docs.set("session.json", JSON.stringify({ version: 2, journalG: 3 }));
  const j = host.editJournal();
  assert.equal(j.lost, true, "control: the journal is lost");
  assert.equal(j.fallback, "nothing");
});
