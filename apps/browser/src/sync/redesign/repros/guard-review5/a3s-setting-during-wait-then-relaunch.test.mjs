import "../../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import "../../switchOn.mjs";
const { reset, onAndSynced, settle, launch, native, S, appMac } = await import('./harness.mjs');

const realNow = Date.now;

async function scenario(relaunchInsideWait) {
  reset();
  await onAndSynced();
  const other = appMac("set:");
  await other.sync();
  other.store.set("set:appearance", { v: "light" });
  await other.sync();
  const realRead = native.read;
  native.read = async (...args) => {
    const listing = await realRead(...args);
    return args[1] === "app" ? { ...listing, pending: [...listing.pending, "stuck"], present: [...listing.present, "stuck"] } : listing;
  };
  try {
    let again = await launch();
    again.startSync();
    await settle();
    await again.syncNow();
    await settle();
    Date.now = () => realNow() + 2 * 60_000;
    assert.notEqual(S().settings.appearance, "light", "control: the wait held the other Mac's choice back");
    S().updateSettings({ appearance: "dark" });
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
    await other.sync();
    return { here: S().settings.appearance, there: other.store.get("set:appearance")?.v };
  } finally {
    native.read = realRead;
    Date.now = realNow;
  }
}

test("A3s: a setting chosen during the load's wait, then a relaunch before the wait ends, is replaced by the other Mac's older choice", { todo: "step 11" }, async () => {
  const { here, there } = await scenario(true);
  assert.equal(here, "dark", "the later choice made here stands here");
  assert.equal(there, "dark", "and reaches the other Mac");
});

test("A3s-control: the same choice with no relaunch inside the wait is published once the wait ends", async () => {
  const { here, there } = await scenario(false);
  assert.equal(here, "dark");
  assert.equal(there, "dark");
});
