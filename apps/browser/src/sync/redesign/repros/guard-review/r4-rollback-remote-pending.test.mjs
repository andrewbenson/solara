import "../../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import "../../switchOn.mjs";
const { reset, onAndSynced, shell, S, settle, launch, native, otherMac, files } = await import('./harness.mjs');

async function scenario(pendingRemote) {
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
  other.store.set(key, { ...value, t: "Renamed again on B" });
  await other.sync();
  const fromB = new Set(files().filter((f) => f.file.device === "otherMac").map((f) => f.payload));
  const realRead = native.read;
  if (pendingRemote)
    native.read = async (...args) => {
      const listing = await realRead(...args);
      const stuck = listing.files.filter((f) => fromB.has(f.payload));
      return { ...listing, files: listing.files.filter((f) => !fromB.has(f.payload)), pending: [...listing.pending, ...stuck.map((f) => f.id)] };
    };
  try {
    shell.docs.clear();
    for (const [name, contents] of older) shell.docs.set(name, contents);
    const again = await launch();
    again.startSync();
    await settle();
    await again.syncNow();
    await again.syncNow();
    await settle();
  } finally {
    native.read = realRead;
  }
  await other.sync();
  return other.store.get(key)?.t;
}

test("R4: a rolled-back state whose newer remote batches are still downloading republishes a value it took from B over B's newer edit", async () => {
  assert.equal(await scenario(true), "Renamed again on B");
});

test("R4-control: same with every batch downloaded (B41)", async () => {
  assert.equal(await scenario(false), "Renamed again on B");
});
