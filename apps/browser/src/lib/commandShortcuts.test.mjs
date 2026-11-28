import assert from "node:assert/strict";
import { test } from "node:test";
const { emitAppEvent } = await import("../test-native/shell.ts");
const { menuBarRevision, shortcutHint, startShortcutHints } = await import("./commandShortcuts.ts");

test("legacy hints follow each native snapshot, including removals", async () => {
  startShortcutHints();
  const revision = menuBarRevision();
  emitAppEvent({ type: "shortcutHints", hints: [["findNext", "⌃F5"], ["findPrevious", "⇧⌘G"]] });
  await Promise.resolve();
  assert.equal(menuBarRevision(), revision + 1);
  assert.equal(shortcutHint("findNext"), "⌃F5");
  emitAppEvent({ type: "shortcutHints", hints: [["findPrevious", "⌃F5"]] });
  assert.equal(menuBarRevision(), revision + 2);
  assert.equal(shortcutHint("findNext"), undefined);
  assert.equal(shortcutHint("findPrevious"), "⌃F5");
});
