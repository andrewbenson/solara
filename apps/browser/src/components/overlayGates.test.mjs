import assert from "node:assert/strict";
import { test } from "node:test";
const { engineOfferMounted, pillPresence, siteControlsMounted } = await import("./overlayGates.ts");

test("the cli pill mounts nothing while hidden and gone", () => {
  assert.deepEqual(pillPresence(false, false, false), { mounted: false, shown: false });
});

test("the cli pill mounts the moment it is shown, and reveals on the next frame", () => {
  assert.deepEqual(pillPresence(false, false, true), { mounted: true, shown: false });
  assert.deepEqual(pillPresence(true, true, true), { mounted: true, shown: true });
});

test("the cli pill stays mounted through its 250 ms hide, then unmounts", () => {
  assert.deepEqual(pillPresence(true, false, false), { mounted: true, shown: false });
  assert.deepEqual(pillPresence(false, false, false), { mounted: false, shown: false });
});

test("native site controls mount nothing while closed, mount on open, and stay mounted until the panel says it closed", () => {
  assert.equal(siteControlsMounted(false, false), false);
  assert.equal(siteControlsMounted(true, false), true);
  assert.equal(siteControlsMounted(true, true), true);
  assert.equal(siteControlsMounted(false, true), true);
});

test("the engine offer prompt mounts only for an offer, outside the new tab page and native prompts", () => {
  const offer = { site: "example.com", host: "example.com", canRemember: true };
  assert.equal(engineOfferMounted(null, false, false), false);
  assert.equal(engineOfferMounted(undefined, false, false), false);
  assert.equal(engineOfferMounted(offer, false, false), true);
  assert.equal(engineOfferMounted(offer, true, false), false);
  assert.equal(engineOfferMounted(offer, false, true), false);
});
