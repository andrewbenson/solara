import "../../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import "../../switchOn.mjs";
const { reset, onAndSynced, shell, settle, launch, native, files, S, otherMac, titles } = await import('./harness.mjs');
const { sealedState } = await import('../../../sealedState.mjs');

async function scenario(stuckFile) {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const scope = `p:${syncId}`;
  const b = otherMac(scope);
  await b.sync();
  const realRead = native.read;
  if (stuckFile) {
    native.read = async (...args) => {
      const listing = await realRead(...args);
      return args[1] === scope && !args[2].includes("stuck") ? { ...listing, pending: [...listing.pending, "stuck"], present: [...listing.present, "stuck"] } : listing;
    };
    await engine.syncNow();
    await settle();
    const sealed = sealedState(shell.docs);
    assert.ok(sealed[scope].pendingSince?.stuck, "control: the stuck file is saved as pending");
    sealed[scope].pendingSince.stuck = Date.now() - 3 * 86_400_000;
    shell.docs.set("sync-state.nns", `sealed:${JSON.stringify(sealed)}`);
  }
  try {
    b.store.set("bm:from-b", { k: "u", p: "bar", t: "FromB", u: "https://b.example/", a: 1, pos: "z" });
    await b.sync();
    const again = await launch();
    again.startSync();
    await settle();
    S().addBookmark({ profileId: "default", url: "https://three.example/", title: "Three" });
    await again.syncNow();
    await again.syncNow();
    await settle();
    await b.sync();
    return { there: [...b.store.values()].map((v) => v.t).sort(), here: titles() };
  } finally {
    native.read = realRead;
  }
}

test("A1: a file pending for three days, which the rest of the engine has given up on, still holds every launch's publish and apply for ten minutes", { todo: "step 11" }, async () => {
  const { there, here } = await scenario(true);
  assert.deepEqual(there, ["FromB", "One", "Three"], "the bookmark added after the relaunch reaches B");
  assert.deepEqual(here, ["FromB", "One", "Three"], "and B's new bookmark lands here");
});

test("A1-control: the same relaunch with no stuck file publishes and applies at once", async () => {
  const { there, here } = await scenario(false);
  assert.deepEqual(there, ["FromB", "One", "Three"]);
  assert.deepEqual(here, ["FromB", "One", "Three"]);
});
