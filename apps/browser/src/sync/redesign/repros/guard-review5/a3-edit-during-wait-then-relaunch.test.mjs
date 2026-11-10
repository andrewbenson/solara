import "../../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import "../../switchOn.mjs";
const { reset, onAndSynced, settle, launch, native, S, otherMac, titles } = await import('./harness.mjs');

const realNow = Date.now;

async function scenario(relaunchInsideWait, renamedOnB = true) {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const scope = `p:${syncId}`;
  const b = otherMac(scope);
  await b.sync();
  const [key] = [...b.store.keys()];
  if (renamedOnB) {
    b.store.set(key, { ...b.store.get(key), t: "RenamedOnB" });
    await b.sync();
  }
  const realRead = native.read;
  native.read = async (...args) => {
    const listing = await realRead(...args);
    return args[1] === scope ? { ...listing, pending: [...listing.pending, "stuck"], present: [...listing.present, "stuck"] } : listing;
  };
  try {
    let again = await launch();
    again.startSync();
    await settle();
    await again.syncNow();
    await settle();
    Date.now = () => realNow() + 2 * 60_000;
    const one = Object.values(S().bookmarks.nodes).find((n) => n.kind === "url" && n.title === "One");
    assert.ok(one, "control: the wait held B's rename back, so this Mac still shows One");
    S().updateBookmark(one.id, { title: "RenamedHereLater" });
    S().addBookmark({ profileId: "default", url: "https://four.example/", title: "Four" });
    await again.syncNow();
    await settle();
    if (relaunchInsideWait) {
      Date.now = () => realNow() + 4 * 60_000;
      again = await launch();
      again.startSync();
      await settle();
      await again.syncNow();
      await settle();
    }
    Date.now = () => realNow() + 30 * 60_000;
    await again.syncNow();
    await again.syncNow();
    await settle();
    await b.sync();
    return { here: titles(), there: [...b.store.values()].map((v) => v.t).sort() };
  } finally {
    native.read = realRead;
    Date.now = realNow;
  }
}

test("A3: a rename made during the load's wait, then a relaunch before the wait ends, is reverted to B's older rename", { todo: "step 11" }, async () => {
  const { here, there } = await scenario(true);
  assert.deepEqual(here, ["Four", "RenamedHereLater"], "the later rename made here stands here");
  assert.deepEqual(there, ["Four", "RenamedHereLater"], "and reaches B");
});

test("A3-control: the same rename with no relaunch inside the wait is published once the wait ends", async () => {
  const { here, there } = await scenario(false);
  assert.deepEqual(here, ["Four", "RenamedHereLater"]);
  assert.deepEqual(there, ["Four", "RenamedHereLater"]);
});

test("A3-control2: the same edit and relaunch inside the wait, when B never touched the key, is kept and published", async () => {
  const { here, there } = await scenario(true, false);
  assert.deepEqual(here, ["Four", "RenamedHereLater"]);
  assert.deepEqual(there, ["Four", "RenamedHereLater"]);
});
