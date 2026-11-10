import "../../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import "../../switchOn.mjs";
const { reset, onAndSynced, shell, settle, launch, native, S, otherMac, titles } = await import('./harness.mjs');
const { sealedState } = await import('../../../sealedState.mjs');

const realNow = Date.now;

async function scenario(flicker) {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const scope = `p:${syncId}`;
  const b = otherMac(scope);
  await b.sync();
  b.store.set("bm:from-b", { k: "u", p: "bar", t: "FromB", u: "https://b.example/", a: 1, pos: "z" });
  await b.sync();
  shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
  let reads = 0;
  const realRead = native.read;
  native.read = async (...args) => {
    const listing = await realRead(...args);
    if (args[1] !== scope) return listing;
    reads++;
    const shown = flicker ? reads % 2 === 1 : reads <= 1;
    return shown ? { ...listing, pending: [...listing.pending, "stuck"], present: [...listing.present, "stuck"] } : listing;
  };
  try {
    const again = await launch();
    again.startSync();
    await settle();
    for (let hour = 0; hour <= 72; hour += 6) {
      Date.now = () => realNow() + hour * 3_600_000;
      await again.syncNow();
      await settle();
    }
    const sealed = sealedState(shell.docs);
    return { here: titles(), rebuilding: sealed[scope].rebuild };
  } finally {
    native.read = realRead;
    Date.now = realNow;
  }
}

test("A2 (passes, no finding): a lost state applies within three days while one folder file keeps dropping out of the listing and coming back as pending", async () => {
  const { here, rebuilding } = await scenario(true);
  assert.deepEqual(here, ["FromB", "One"], "B's bookmark lands here within three days");
});

test("A2-control: the same file pending for good is given up after a day", async () => {
  const { here } = await scenario(false);
  assert.deepEqual(here, ["FromB", "One"]);
});
