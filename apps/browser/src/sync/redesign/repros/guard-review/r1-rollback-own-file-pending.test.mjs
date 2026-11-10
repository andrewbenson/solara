import "../../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import "../../switchOn.mjs";
const { reset, onAndSynced, shell, S, settle, launch, native, assertNoSeqReused, files, otherMac } = await import('./harness.mjs');

async function scenario(pendingOwn) {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const older = new Map(shell.docs);
  const before = new Set(files().map((f) => f.payload));
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  await engine.syncNow();
  await settle();
  const mine = files().filter((f) => !before.has(f.payload) && f.scope === `p:${syncId}` && f.file.kind === "log");
  assert.ok(mine.length > 0, "control: Two went out in its own batch");
  const hidden = new Set(mine.map((f) => f.payload));
  const realRead = native.read;
  if (pendingOwn)
    native.read = async (...args) => {
      const listing = await realRead(...args);
      const stuck = listing.files.filter((f) => hidden.has(f.payload));
      return { ...listing, files: listing.files.filter((f) => !hidden.has(f.payload)), pending: [...listing.pending, ...stuck.map((f) => f.id)] };
    };
  try {
    shell.docs.clear();
    for (const [name, contents] of older) shell.docs.set(name, contents);
    const again = await launch();
    again.startSync();
    await settle();
    S().addBookmark({ profileId: "default", url: "https://three.example/", title: "Three" });
    await again.syncNow();
    await again.syncNow();
    await settle();
  } finally {
    native.read = realRead;
  }
  const other = otherMac(`p:${syncId}`);
  await other.sync();
  return { b: [...other.store.values()].map((v) => v.t).sort() };
}

test("R1: a rolled-back state whose own newer batch is still downloading reuses that batch's seq for different changes, and B never gets Three", { todo: "step 7" }, async () => {
  const { b } = await scenario(true);
  assertNoSeqReused();
  assert.deepEqual(b, ["One", "Three", "Two"], "B converges on this Mac's bookmarks");
});

test("R1-control: same with this Mac's batch downloaded", async () => {
  const { b } = await scenario(false);
  assertNoSeqReused();
  assert.deepEqual(b, ["One", "Three", "Two"]);
});

test("R1b: B never gets Three even if the seq check is skipped", { todo: "step 7" }, async () => {
  const { b } = await scenario(true);
  assert.deepEqual(b, ["One", "Three", "Two"], "B converges on this Mac's bookmarks");
});
