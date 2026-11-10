import "../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import('./switchOn.mjs');
const { shell, settle, reset, onAndSynced, S, otherMac } = await import('./harness.mjs');
const host = await import("../journalHost.ts");

test("HOOK-in-step: a clean cycle records the last in-step time and every scope's vv in sync-edits.gen", fixedBy("step 4"), async () => {
  reset();
  host.forgetEditJournal();
  const engine = await onAndSynced();
  for (let i = 0; i < 2; i++) await engine.syncNow();
  await settle();
  const gen = JSON.parse(shell.docs.get("sync-edits.gen") ?? "null");
  assert.ok(gen?.T, `the gen doc has T (${shell.docs.get("sync-edits.gen")})`);
  const syncId = engine.useSync.getState().profiles.default.syncId;
  assert.ok(gen.vv.app && gen.vv[`p:${syncId}`], "and a vv per scope");
});

test("HOOK-seen: a setting record seen in the folder is noted as ever seen, with its origin", fixedBy("step 4"), async () => {
  reset();
  host.forgetEditJournal();
  const engine = await onAndSynced();
  const other = otherMac("app");
  await other.sync();
  other.store.set("set:searchEngine", { v: "duckduckgo" });
  await other.sync();
  for (let i = 0; i < 2; i++) await engine.syncNow();
  await settle();
  assert.ok(host.seenOrigin("app", "set:searchEngine"), "noted");
  void S;
});

test("HOOK-seen-before-apply: a setting from the folder is noted as seen before its adapter applies it", fixedBy("step 4"), async () => {
  reset();
  host.forgetEditJournal();
  const engine = await onAndSynced();
  const other = otherMac("app");
  await other.sync();
  other.store.set("set:searchEngine", { v: "duckduckgo" });
  await other.sync();
  const { settingsAdapter } = await import("../adapters.ts");
  let seenAtApply;
  const apply = settingsAdapter.apply;
  settingsAdapter.apply = (visible, changed, ...rest) => {
    if (changed.has("set:searchEngine")) seenAtApply ??= host.seenOrigin("app", "set:searchEngine");
    return apply(visible, changed, ...rest);
  };
  try {
    for (let i = 0; i < 2; i++) await engine.syncNow();
    await settle();
  } finally {
    settingsAdapter.apply = apply;
  }
  assert.ok(seenAtApply, "the origin was noted before the apply ran");
});

test("HOOK-survives-quit: a key noted as seen, then a quit before any store write, is remembered after a relaunch", fixedBy("step 4"), async () => {
  const { startPersistence, flushPersistence } = await import("../../lib/persist.ts");
  shell.docs.clear();
  host.forgetEditJournal();
  const stop = startPersistence();
  try {
    host.editJournal();
    host.noteSeen("app", "set:remembered", ["B", 5]);
    flushPersistence({ final: true });
  } finally {
    stop();
  }
  host.forgetEditJournal();
  assert.deepEqual(host.seenOrigin("app", "set:remembered"), ["B", 5]);
});
