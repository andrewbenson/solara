import "../../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import "../../switchOn.mjs";
const { fake, folder, shell, S, settle, launch, reset, files, otherMac, assertNoSeqReused, onAndSynced } = await import('./harness.mjs');
const { sealedState } = await import('../../../sealedState.mjs');

test("R-rollback: a rolled-back (but readable) sync state republishes values this Mac took from B since the backup, over B's newer edit", async () => {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  const older = new Map(shell.docs);
  const [key, value] = [...other.store].find(([, v]) => v.t === "One");
  other.store.set(key, { ...value, t: "Renamed on B" });
  await other.sync();
  await engine.syncNow();
  await settle();
  const here = () => Object.values(S().bookmarks.nodes).filter((n) => n.kind === "url").map((n) => n.title);
  assert.ok(here().includes("Renamed on B"), "control: this Mac took B's first rename");
  other.store.set(key, { ...value, t: "Renamed again on B" });
  await other.sync();
  shell.docs.clear();
  for (const [name, contents] of older) shell.docs.set(name, contents);
  const again = await launch();
  again.startSync();
  await settle();
  await again.syncNow();
  await again.syncNow();
  await settle();
  await other.sync();
  assertNoSeqReused();
  assert.equal(again.useSync.getState().status, "updated");
  assert.equal(other.store.get(key)?.t, "Renamed again on B", `B's newer rename survives this Mac's rollback (B now has ${other.store.get(key)?.t}, this Mac ${here()})`);
});

test("R-rollback-outbox: a rolled-back state sealed mid-publish (outbox not empty) writes its outbox before the pull raises the seq", async () => {
  reset();
  const engine = await onAndSynced();
  const older = new Map(shell.docs);
  for (const title of ["Two", "Three"]) {
    S().addBookmark({ profileId: "default", url: `https://${title}.example/`, title });
    await engine.syncNow();
  }
  S().updateSettings({ searchEngine: "bing" });
  await engine.syncNow();
  await settle();
  const state = sealedState(older);
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const scope = state[`p:${syncId}`];
  const dev = JSON.parse(older.get("sync.json")).deviceId;
  const h = `${Date.now().toString(36).padStart(9, "0")}.0000.${dev}`;
  scope.outbox = [{ k: "bm:outboxed", h, v: { k: "u", p: "bar", t: "Outboxed", u: "https://outboxed.example/", a: 1, pos: "z" } }];
  scope.records["bm:outboxed"] = { h, v: scope.outbox[0].v, o: [dev, scope.seq + 1] };
  older.set("sync-state.nns", `sealed:${JSON.stringify(state)}`);
  shell.docs.clear();
  for (const [name, contents] of older) shell.docs.set(name, contents);
  const again = await launch();
  again.startSync();
  await settle();
  await again.syncNow();
  await settle();
  assertNoSeqReused();
});
