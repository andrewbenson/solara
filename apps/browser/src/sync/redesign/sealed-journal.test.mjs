import "../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import('./switchOn.mjs');
const { shell, settle, reset, onAndSynced, launch, folder, S, native, realReadPasswords } = await import('./harness.mjs');

const JOURNAL = "sync-journal.nns";
const LEDGER = "sync-pw-ledger.json";
const OLDER = JSON.stringify({ v: 1, profiles: {} });
const SITE = "https://site.example";

const upgradeWith = async (journal) => {
  reset();
  const here = new Map();
  shell.passwordStores.set(null, here);
  native.readPasswords = async () => [...here.values()];
  await onAndSynced();
  shell.docs.set(LEDGER, OLDER);
  if (journal === null) shell.docs.delete(JOURNAL);
  else shell.docs.set(JOURNAL, journal);
  const engine = await launch();
  engine.startSync();
  await settle();
  const filesBefore = folder.size;
  here.set(`${SITE}\nme`, { origin: `${SITE}/`, url: `${SITE}/`, username: "me", password: "secret", created: Date.now(), modified: Date.now() });
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  await engine.syncNow();
  await settle(60);
  await engine.syncNow();
  await settle(60);
  const sent = [...folder.values()].slice(filesBefore).flatMap((f) => JSON.parse(f.payload).ops ?? []);
  return { engine, sent };
};

test("SEALED-journal: a journal that exists but won't open keeps passwords paused for the session, and the other types sync", fixedBy("sealed passwords"), async () => {
  try {
    const { engine, sent } = await upgradeWith("unopened-journal");
    assert.ok(sent.some((op) => op.k.startsWith("bm:")), "the bookmark goes out");
    assert.ok(!sent.some((op) => op.k.startsWith("pw:")), "no password goes out");
    assert.equal(shell.docs.get(LEDGER), OLDER, "the ledger isn't migrated over records the journal may have lost");
    assert.equal(engine.useSync.getState().status, "updated", "sync isn't stalled");
  } finally {
    native.readPasswords = realReadPasswords;
  }
});

test("SEALED-journal control: with no journal, the ledger migrates and the password goes out", fixedBy("sealed passwords"), async () => {
  try {
    const { sent } = await upgradeWith(null);
    assert.equal(JSON.parse(shell.docs.get(LEDGER)).v, 2, "the ledger migrates");
    assert.ok(sent.some((op) => op.k.startsWith("pw:")), "the password goes out");
  } finally {
    native.readPasswords = realReadPasswords;
  }
});
