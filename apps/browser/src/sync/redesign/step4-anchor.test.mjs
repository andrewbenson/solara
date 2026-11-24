import assert from "node:assert/strict";
import { test } from "node:test";
import { fixedBy } from "./switchOn.mjs";

const shell = await import("../../test-native/index.ts");
const host = await import("../journalHost.ts");
const { syncRedesign } = await import("../redesignSwitch.ts");

const fresh = () => {
  shell.docs.clear();
  host.forgetEditJournal();
};
const h = (ms) => `${ms.toString(36).padStart(9, "0")}.0000.dev1`;

test("ANCHOR-journalG: the session doc carries the journal's g only with the switch on", fixedBy("step 4"), () => {
  fresh();
  const j = host.editJournal();
  j.record("p:1", "bm:a", { v: 1, h: h(1000), seen: null });
  assert.deepEqual(host.journalAnchor(), { journalG: 1 });
});

test("ANCHOR-off: with the switch off there's no journal and no anchor", () => {
  fresh();
  const was = syncRedesign.on;
  syncRedesign.on = false;
  try {
    assert.equal(host.editJournal(), null);
    assert.deepEqual(host.journalAnchor(), {});
  } finally {
    syncRedesign.on = was;
  }
});

test("ANCHOR-rollback: the journal and gen doc rolled back together, under a session doc that reflects a later g, open as lost", fixedBy("step 4"), () => {
  fresh();
  const j = host.editJournal();
  j.record("p:1", "bm:a", { v: 1, h: h(1000), seen: null });
  const backup = [shell.docs.get("sync-edits.json"), shell.docs.get("sync-edits.gen")];
  j.record("p:1", "bm:b", { v: 2, h: h(2000), seen: null });
  shell.docs.set("session.json", JSON.stringify({ version: 2, ...host.journalAnchor() }));
  shell.docs.set("sync-edits.json", backup[0]);
  shell.docs.set("sync-edits.gen", backup[1]);
  host.forgetEditJournal();
  assert.equal(host.editJournal().lost, true);
});

test("ANCHOR-in-step: a cycle with nothing pending, damaged, unapplied or unsent records T and every scope's vv", fixedBy("step 4"), () => {
  fresh();
  host.editJournal();
  const scope = (extra = {}) => ({ unapplied: [], pending: 0, damaged: {}, outbox: [], vv: { dev1: 2, dev2: 4 }, ...extra });
  host.noteInStep({ app: scope(), "p:1": scope({ unapplied: ["bm:x"] }) }, 5000);
  assert.equal(JSON.parse(shell.docs.get("sync-edits.gen") ?? "{}").T ?? null, null, "not in step while a key is unapplied");
  host.noteInStep({ app: scope(), "p:1": scope() }, 6000);
  const gen = JSON.parse(shell.docs.get("sync-edits.gen"));
  assert.equal(gen.T, 6000);
  assert.deepEqual(gen.vv, { app: { dev1: 2, dev2: 4 }, "p:1": { dev1: 2, dev2: 4 } });
});

test("SEEN-store: a key seen in a store-backed type's records is saved with the session doc, with its last origin", fixedBy("step 4"), () => {
  fresh();
  host.editJournal();
  host.noteSeen("app", "set:theme", ["dev2", 7]);
  host.noteSeen("app", "set:theme", ["dev3", 2]);
  host.noteSeen("p:1", "bm:x", ["dev2", 1]);
  assert.deepEqual(host.journalAnchor().everSeen, { devices: ["dev3"], scopes: { app: { "set:theme": [0, 2] } } }, "bookmarks keep their origins in Chrome, not here; devices are stored once");
  shell.docs.set("session.json", JSON.stringify({ version: 2, ...host.journalAnchor() }));
  host.forgetEditJournal();
  assert.deepEqual(host.seenOrigin("app", "set:theme"), ["dev3", 2], "it reads back with the session doc");
});

test("SEEN-rollback: the ever-seen keys roll back with the session doc they're written in", fixedBy("step 4"), () => {
  fresh();
  host.editJournal();
  host.noteSeen("app", "set:a", ["dev2", 1]);
  const backup = JSON.stringify({ version: 2, ...host.journalAnchor() });
  host.noteSeen("app", "set:b", ["dev2", 2]);
  shell.docs.set("session.json", backup);
  host.forgetEditJournal();
  assert.equal(host.seenOrigin("app", "set:b"), undefined);
  assert.deepEqual(host.seenOrigin("app", "set:a"), ["dev2", 1]);
});
