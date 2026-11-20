import assert from "node:assert/strict";
import { test } from "node:test";

const { applyNativeRenameState, resetNativeRenames } = await import("./renameMirror.ts");
const { setSidebarUi, sidebarUi } = await import("./state.ts");

const renaming = () => sidebarUi().renaming;
const clear = () => {
  resetNativeRenames({});
  setSidebarUi({ renaming: null });
};

test("a native rename state is mirrored, and an older one is dropped", () => {
  clear();
  assert.equal(applyNativeRenameState("w1", "tab", "a", 1), true);
  assert.deepEqual(renaming(), { windowId: "w1", kind: "tab", id: "a" });
  assert.equal(applyNativeRenameState("w1", null, "", 3), true);
  assert.equal(renaming(), null);
  assert.equal(applyNativeRenameState("w1", "tab", "a", 2), false);
  assert.equal(renaming(), null);
  assert.equal(applyNativeRenameState("w1", "group", "g", 3), false);
  assert.equal(applyNativeRenameState("w1", "group", "g", 4), true);
  assert.deepEqual(renaming(), { windowId: "w1", kind: "group", id: "g" });
});

test("ending one window's rename keeps another window's", () => {
  clear();
  applyNativeRenameState("w2", "tab", "x", 1);
  applyNativeRenameState("w3", "tab", "y", 1);
  assert.deepEqual(renaming(), { windowId: "w3", kind: "tab", id: "y" });
  applyNativeRenameState("w2", null, "", 2);
  assert.deepEqual(renaming(), { windowId: "w3", kind: "tab", id: "y" });
  applyNativeRenameState("w2", "tab", "x2", 3);
  applyNativeRenameState("w3", null, "", 2);
  assert.deepEqual(renaming(), { windowId: "w2", kind: "tab", id: "x2" });
});

test("an end for a window the slot doesn't show leaves the slot alone", () => {
  clear();
  applyNativeRenameState("w6", "tab", "p", 1);
  setSidebarUi({ renaming: { windowId: "elsewhere", kind: "tab", id: "q" } });
  applyNativeRenameState("w6", null, "", 2);
  assert.deepEqual(renaming(), { windowId: "elsewhere", kind: "tab", id: "q" });
});

test("a reset carries each window's sequence, so an older state can't come back after it", () => {
  clear();
  applyNativeRenameState("w4", "tab", "a", 5);
  applyNativeRenameState("w7", "tab", "b", 2);
  resetNativeRenames({ w4: 6, w7: 3 });
  assert.equal(renaming(), null);
  assert.equal(applyNativeRenameState("w4", "tab", "a", 5), false);
  assert.equal(applyNativeRenameState("w7", "tab", "b", 3), false);
  assert.equal(renaming(), null);
  assert.equal(applyNativeRenameState("w4", "tab", "c", 7), true);
  assert.deepEqual(renaming(), { windowId: "w4", kind: "tab", id: "c" });
});

test("a reset that arrives after a newer state for that window keeps the newer state", () => {
  clear();
  applyNativeRenameState("w8", "tab", "a", 1);
  applyNativeRenameState("w8", "tab", "b", 3);
  resetNativeRenames({ w8: 2 });
  assert.deepEqual(renaming(), { windowId: "w8", kind: "tab", id: "b" });
});

test("a kind that isn't tab or group counts as an end", () => {
  clear();
  applyNativeRenameState("w5", "tab", "a", 1);
  applyNativeRenameState("w5", "folder", "f", 2);
  assert.equal(renaming(), null);
});
