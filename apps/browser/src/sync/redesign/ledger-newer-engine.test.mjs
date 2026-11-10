import "../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import('./switchOn.mjs');
const { shell, settle, reset, onAndSynced, passwordMac, native, realReadPasswords, appMac } = await import('./harness.mjs');

const host = await import("../journalHost.ts");
const SITE = "https://site.example";

test("LEDGER-newer: a password ledger from a newer version stops password sync with a reason and doesn't hold up the other types", fixedBy("step 3"), async () => {
  reset();
  const here = new Map();
  shell.passwordStores.set(null, here);
  native.readPasswords = async () => [...here.values()];
  try {
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const newer = JSON.stringify({ v: 3, profiles: {} });
    shell.docs.set("sync-pw-ledger.json", newer);
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    b.store.set(`pw:${SITE}\nme`, { o: SITE, u: "me", p: "from B" });
    await b.sync();
    const settings = appMac("set:");
    await settings.sync();
    settings.store.set("set:appearance", { v: "dark" });
    await settings.sync();
    const before = host.editJournal().lastInStepT;
    await engine.syncNow();
    await settle(60);
    await engine.syncNow();
    await settle(60);
    assert.equal(here.size, 0, "B's password isn't saved here");
    assert.match(engine.useSync.getState().passwordsError ?? "", /newer version/, "the Sync pane says why passwords stopped");
    assert.ok(host.editJournal().lastInStepT > before, "the edit journal still reaches step for the other types");
    assert.equal(shell.docs.get("sync-pw-ledger.json"), newer, "the newer ledger is left alone");
    shell.docs.set("sync-pw-ledger.json", JSON.stringify({ v: 1, profiles: {} }));
    await engine.syncNow();
    await settle(60);
    assert.equal(engine.useSync.getState().passwordsError, null, "control: with a ledger it can read, the reason goes away");
    assert.equal(JSON.parse(shell.docs.get("sync-pw-ledger.json")).v, 2, "and the older ledger is migrated to sealed digests");
  } finally {
    native.readPasswords = realReadPasswords;
  }
});

test("LEDGER-unreadable-shown: a password ledger that can't be read says so in the Sync pane while the other types keep syncing", fixedBy("step 3"), async () => {
  reset();
  const here = new Map();
  shell.passwordStores.set(null, here);
  native.readPasswords = async () => [...here.values()];
  try {
    const engine = await onAndSynced();
    const broken = JSON.stringify({ v: 2, profiles: { default: { L: 1 } } });
    shell.docs.set("sync-pw-ledger.json", broken);
    const settings = appMac("set:");
    await settings.sync();
    settings.store.set("set:appearance", { v: "dark" });
    await settings.sync();
    const before = host.editJournal().lastInStepT;
    await engine.syncNow();
    await settle(60);
    assert.match(engine.useSync.getState().passwordsError ?? "", /can't read this Mac's password sync records/, "the Sync pane says why passwords stopped");
    assert.ok(host.editJournal().lastInStepT > before, "the edit journal still reaches step for the other types");
    assert.equal(shell.docs.get("sync-pw-ledger.json"), broken, "the unreadable ledger is left alone");
    shell.docs.delete("sync-pw-ledger.json");
    await engine.syncNow();
    await settle(60);
    assert.equal(engine.useSync.getState().passwordsError, null, "control: once it reads, the reason goes away");
  } finally {
    native.readPasswords = realReadPasswords;
  }
});

test("LEDGER-older-shown: a password ledger whose update keeps failing says so in the Sync pane", fixedBy("step 3"), async () => {
  reset();
  const here = new Map();
  shell.passwordStores.set(null, here);
  native.readPasswords = async () => [...here.values()];
  const realMigrate = native.migrateLedger;
  try {
    const engine = await onAndSynced();
    shell.docs.set("sync-pw-ledger.json", JSON.stringify({ v: 1, profiles: {} }));
    native.migrateLedger = async () => null;
    await engine.syncNow();
    await settle(60);
    assert.match(engine.useSync.getState().passwordsError ?? "", /need updating and the update didn't finish/, "the Sync pane says why passwords stopped");
    assert.equal(JSON.parse(shell.docs.get("sync-pw-ledger.json")).v, 1, "control: the ledger is still the older one");
    native.migrateLedger = realMigrate;
    await engine.syncNow();
    await settle(60);
    assert.equal(engine.useSync.getState().passwordsError, null, "control: once the update finishes, the reason goes away");
    assert.equal(JSON.parse(shell.docs.get("sync-pw-ledger.json")).v, 2, "and the ledger is updated");
  } finally {
    native.migrateLedger = realMigrate;
    native.readPasswords = realReadPasswords;
  }
});
