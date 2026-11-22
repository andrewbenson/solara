import assert from "node:assert/strict";
import { test } from "node:test";

const nativeAnchor = { value: null, writes: 0, supported: true };
const storeFake = {
  status: () => ({ active: true }),
  snapshot: () => JSON.stringify({ rev: 0, data: { settings: null, downloads: [] } }),
  dispatch: () => JSON.stringify({ rev: 0, patches: [] }),
  catchUp: () => null,
  flush: () => true,
  freeze: () => true,
  syncAnchor: () => nativeAnchor.value,
  setSyncAnchor: (text) => (nativeAnchor.writes++, (nativeAnchor.value = text), true),
};
globalThis.acTestNativeModules = { ...globalThis.acTestNativeModules, SolaraStoreAdapter: storeFake };
const R = new URL("../../", import.meta.url).href;
const { fixedBy } = await import("./switchOn.mjs");
const shell = await import(R + "test-native/index.ts");
const nativeStore = await import(R + "store/nativeStore.ts");
const host = await import(R + "sync/journalHost.ts");
const h = (ms) => `${ms.toString(36).padStart(9, "0")}.0000.dev1`;
const flushMicrotasks = () => new Promise((r) => setImmediate(r));
assert.ok(nativeStore.startNativeStore().active, "control: the native store is active");

function fresh() {
  shell.docs.clear();
  nativeAnchor.value = null;
  nativeAnchor.writes = 0;
  host.forgetEditJournal();
}

test("ANCHOR-reload: both halves read back together after a relaunch", fixedBy("step 4"), () => {
  fresh();
  host.editJournal();
  host.noteSeen("app", "set:theme", ["B", 2]);
  host.noteSeen("app", "pin:t:1", ["B", 3]);
  shell.docs.set("session.json", JSON.stringify({ version: 2, ...host.journalAnchor() }));
  host.forgetEditJournal();
  assert.deepEqual(host.seenOrigin("app", "set:theme"), ["B", 2]);
  assert.deepEqual(host.seenOrigin("app", "pin:t:1"), ["B", 3]);
});

test("ANCHOR-lost-by-either: a journal below the native anchor's g is lost even when session.json is behind", fixedBy("step 4"), () => {
  fresh();
  const j = host.editJournal();
  j.record("app", "set:a", { v: 1, h: h(1000), seen: null });
  const oldJournal = [shell.docs.get("sync-edits.json"), shell.docs.get("sync-edits.gen")];
  j.record("app", "set:b", { v: 2, h: h(2000), seen: null });
  host.noteSeen("app", "set:b", ["B", 5]);
  shell.docs.set("session.json", JSON.stringify({ version: 2, journalG: 1 }));
  shell.docs.set("sync-edits.json", oldJournal[0]);
  shell.docs.set("sync-edits.gen", oldJournal[1]);
  host.forgetEditJournal();
  assert.equal(host.editJournal().lost, true);
});

test("ANCHOR-seed: the first launch on the native store moves settings keys from session.json into the native anchor", fixedBy("step 4"), async () => {
  fresh();
  shell.docs.set("session.json", JSON.stringify({ version: 2, everSeen: { devices: ["B"], scopes: { app: { "set:theme": [0, 2], "prof:p": [0, 3] } } } }));
  host.editJournal();
  host.seenOrigin("app", "set:theme");
  await flushMicrotasks();
  assert.deepEqual(Object.keys(JSON.parse(nativeAnchor.value).everSeen.scopes.app).sort(), ["prof:p", "set:theme"]);
});

test("ANCHOR-guard-lifted: with the native anchor in place, a lost journal uses the normal fallback", fixedBy("step 4"), () => {
  fresh();
  nativeAnchor.value = JSON.stringify({ journalG: 3, journalT: 1000 });
  shell.docs.set("sync-edits.json", "{broken");
  shell.docs.set("sync-edits.gen", JSON.stringify({ v: 1, g: 3, T: 1000, vv: { app: {} } }));
  shell.docs.set("session.json", JSON.stringify({ version: 2, journalG: 3, journalT: 1000 }));
  assert.equal(host.editJournal().fallback, "union");
});

test("ANCHOR-everything: every key's anchor is in the native store", fixedBy("step 4"), () => {
  fresh();
  host.editJournal();
  host.noteSeen("app", "set:theme", ["B", 2]);
  host.noteSeen("app", "prof:abc", ["B", 3]);
  assert.deepEqual(Object.keys(JSON.parse(nativeAnchor.value).everSeen.scopes.app).sort(), ["prof:abc", "set:theme"]);
  assert.equal(host.journalAnchor().everSeen, undefined);
});

test("ANCHOR-T-rises: after a loss lowers the native half's T, the next in-step cycle raises both halves again, so union comes back", fixedBy("step 4"), () => {
  const quiet = (vv) => ({ app: { unapplied: [], pending: 0, damaged: {}, outbox: [], vv } });
  const saveSession = () => shell.docs.set("session.json", JSON.stringify({ version: 2, ...host.journalAnchor() }));
  const nativeT = () => JSON.parse(nativeAnchor.value ?? "{}").journalT ?? 0;
  fresh();
  let j = host.editJournal();
  j.record("app", "set:a", { v: 1, h: h(1000), seen: null });
  host.noteInStep(quiet({ B: 1 }), 10_000);
  saveSession();
  const before = shell.docs.get("session.json");
  const nativeBefore = nativeAnchor.value;
  host.noteInStep(quiet({ B: 2 }), 20_000);
  saveSession();
  assert.equal(nativeT(), 20_000, "control: the native half follows T");
  shell.docs.set("session.json", before);
  nativeAnchor.value = nativeBefore;
  shell.docs.set("sync-edits.json", "{broken");
  host.forgetEditJournal();
  j = host.editJournal();
  assert.equal(j.fallback, "nothing", "control: the restored, older halves mean nothing");
  saveSession();
  host.noteInStep(quiet({ B: 3 }), 30_000);
  saveSession();
  assert.equal(nativeT(), 30_000, "the native half rises with the next T");
  assert.equal(JSON.parse(shell.docs.get("session.json")).journalT, 30_000, "so does session.json's");
  shell.docs.set("sync-edits.json", "{broken");
  host.forgetEditJournal();
  assert.equal(host.editJournal().fallback, "union", "union is back after one in-step cycle");
});

test("ANCHOR-g-stale: a command's g++ reaches the native anchor, so the journal and gen doc rolled back together under a current native store are lost", fixedBy("step 4"), () => {
  assert.ok(nativeStore.startNativeStore().active);
  shell.docs.clear();
  nativeAnchor.value = null;
  host.forgetEditJournal();
  const j = host.editJournal();
  host.noteSeen("app", "set:theme", ["B", 1]);
  j.record("app", "set:a", { v: 1, h: h(1000), seen: null });
  const old = [shell.docs.get("sync-edits.json"), shell.docs.get("sync-edits.gen")];
  j.record("app", "set:b", { v: 2, h: h(2000), seen: null });
  j.record("app", "set:c", { v: 3, h: h(3000), seen: null });
  const anchorG = JSON.parse(nativeAnchor.value).journalG ?? 0;
  shell.docs.set("sync-edits.json", old[0]);
  shell.docs.set("sync-edits.gen", old[1]);
  host.forgetEditJournal();
  assert.equal(host.editJournal().lost, true, `the store's items reflect g 3, but the native anchor says g ${anchorG}`);
});

test("ANCHOR-record-erases-seen: a command before anything loads everSeen keeps the native anchor's ever-seen keys", fixedBy("step 4"), () => {
  assert.ok(nativeStore.startNativeStore().active);
  shell.docs.clear();
  nativeAnchor.value = JSON.stringify({ journalG: 1, everSeen: { devices: ["B"], scopes: { app: { "set:theme": [0, 2] } } } });
  shell.docs.set("session.json", JSON.stringify({ version: 2, journalG: 1 }));
  host.forgetEditJournal();
  host.editJournal().record("app", "set:a", { v: 1, h: h(1000), seen: null });
  const saved = JSON.parse(nativeAnchor.value);
  assert.equal(saved.journalG, 2, "control: the command's g reached the native anchor");
  assert.deepEqual(saved.everSeen?.scopes?.app?.["set:theme"], [0, 2], `the saved ever-seen key is gone: ${nativeAnchor.value}`);
});

test("ANCHOR-instep-erases-seen: a first in-step cycle with no applies keeps the native anchor's ever-seen keys", fixedBy("step 4"), () => {
  assert.ok(nativeStore.startNativeStore().active);
  const quiet = (vv) => ({ app: { unapplied: [], pending: 0, damaged: {}, outbox: [], vv } });
  shell.docs.clear();
  nativeAnchor.value = JSON.stringify({ journalG: 1, everSeen: { devices: ["B"], scopes: { app: { "set:theme": [0, 2] } } } });
  shell.docs.set("session.json", JSON.stringify({ version: 2, journalG: 1 }));
  host.forgetEditJournal();
  host.editJournal();
  host.noteInStep(quiet({ B: 2 }), 10_000);
  const saved = JSON.parse(nativeAnchor.value);
  assert.equal(saved.journalT, 10_000, "control: the in-step point reached the native anchor");
  assert.deepEqual(saved.everSeen?.scopes?.app?.["set:theme"], [0, 2], `the saved ever-seen key is gone: ${nativeAnchor.value}`);
});

test("ANCHOR-unsupported: on a native store that can't hold an anchor, every key's anchor stays in session.json", fixedBy("step 4"), () => {
  const setSyncAnchor = storeFake.setSyncAnchor;
  delete storeFake.setSyncAnchor;
  try {
    assert.ok(nativeStore.startNativeStore().active);
    shell.docs.clear();
    nativeAnchor.value = null;
    host.forgetEditJournal();
    host.editJournal().record("app", "set:a", { v: 1, h: h(1000), seen: null });
    host.noteSeen("app", "set:a", ["B", 1]);
    const anchor = host.journalAnchor();
    assert.ok(anchor.everSeen?.scopes?.app?.["set:a"], `a settings key's ever-seen entry stays in session.json: ${JSON.stringify(anchor)}`);
    assert.equal(anchor.journalG, 1);
    assert.equal(nativeAnchor.value, null, "control: nothing reached the native store");
  } finally {
    storeFake.setSyncAnchor = setSyncAnchor;
  }
});
