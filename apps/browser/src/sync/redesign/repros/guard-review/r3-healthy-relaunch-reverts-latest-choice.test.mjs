import "../../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import "../../switchOn.mjs";
const { reset, onAndSynced, S, settle, launch, appMac } = await import('./harness.mjs');

test("R3: after a relaunch with a healthy state, a setting chosen here last is replaced by an older choice from another Mac when that Mac once had the same value", { todo: "step 6" }, async () => {
  reset();
  await onAndSynced();
  const other = appMac("set:");
  await other.sync();
  other.store.set("set:appearance", { v: "dark" });
  await other.sync();
  other.store.set("set:appearance", { v: "light" });
  await other.sync();
  S().updateSettings({ appearance: "dark" });
  const again = await launch();
  again.startSync();
  await settle();
  await again.syncNow();
  await again.syncNow();
  await settle();
  await other.sync();
  assert.equal(S().settings.appearance, "dark", "the choice made here last stands on this Mac");
  assert.deepEqual(other.store.get("set:appearance"), { v: "dark" }, "and reaches the other Mac");
});

test("R3-control: same, when the other Mac never had this Mac's value", async () => {
  reset();
  await onAndSynced();
  const other = appMac("set:");
  await other.sync();
  other.store.set("set:appearance", { v: "system" });
  await other.sync();
  other.store.set("set:appearance", { v: "light" });
  await other.sync();
  S().updateSettings({ appearance: "dark" });
  const again = await launch();
  again.startSync();
  await settle();
  await again.syncNow();
  await again.syncNow();
  await settle();
  await other.sync();
  assert.equal(S().settings.appearance, "dark");
  assert.deepEqual(other.store.get("set:appearance"), { v: "dark" });
});
