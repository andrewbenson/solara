import "../../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import "../../switchOn.mjs";
const { reset, onAndSynced, shell, S, settle, launch, files, otherMac, useBrowser } = await import('./harness.mjs');

async function scenario(offAtLaunch) {
  reset();
  useBrowser.setState({ historyReady: { default: true } });
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const scope = `p:${syncId}`;
  const b = otherMac(scope);
  await b.sync();
  const [key] = [...b.store.keys()];
  const backup = new Map(shell.docs);
  const mineBefore = files().filter((f) => f.scope === scope && f.file.kind === "log" && f.file.device !== "otherMac").length;
  b.store.set(key, { ...b.store.get(key), t: "B1" });
  await b.sync();
  await engine.syncNow();
  await settle();
  assert.deepEqual(Object.values(S().bookmarks.nodes).filter((n) => n.kind === "url").map((n) => n.title), ["B1"], "control: this Mac applied B1");
  assert.equal(files().filter((f) => f.scope === scope && f.file.kind === "log" && f.file.device !== "otherMac").length, mineBefore, "control: this Mac wrote nothing to the profile scope after the backup");
  b.store.set(key, { ...b.store.get(key), t: "B2" });
  await b.sync();
  shell.docs.clear();
  for (const [name, contents] of backup) shell.docs.set(name, contents);
  const meta = JSON.parse(shell.docs.get("sync.json"));
  meta.types = { ...meta.types, extensions: false, ...(offAtLaunch ? { bookmarks: false } : {}) };
  shell.docs.set("sync.json", JSON.stringify(meta));
  const again = await launch();
  again.startSync();
  await settle();
  await again.syncNow();
  await again.syncNow();
  await settle();
  if (offAtLaunch) {
    again.setTypeSynced("bookmarks", true);
    await settle();
    await again.syncNow();
    await again.syncNow();
    await settle();
  }
  await b.sync();
  return { here: Object.values(S().bookmarks.nodes).filter((n) => n.kind === "url").map((n) => n.title), there: b.store.get(key).t };
}

test("D1: a rolled-back state with bookmarks off at launch republishes a value it took from B over B's newer rename once bookmarks are turned on", { todo: "step 9" }, async () => {
  const { here, there } = await scenario(true);
  assert.equal(there, "B2", "B's newer rename survives on B");
  assert.deepEqual(here, ["B2"], "and lands here");
});

test("D1-control: same rolled-back state with bookmarks on at launch keeps B's newer rename", async () => {
  const { here, there } = await scenario(false);
  assert.equal(there, "B2");
  assert.deepEqual(here, ["B2"]);
});
