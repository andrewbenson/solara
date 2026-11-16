import assert from "node:assert/strict";
import { test } from "node:test";
import { topStripLeading } from "./topStripLeading.ts";

test("windowed top tabs reserve only the measured profile and its padding", () => {
  for (const [profileWidth, profileSlot] of [[0, 0], [26, 34], [52, 60], [80, 88], [140, 148]]) {
    const row = topStripLeading(900, profileWidth, false);
    assert.equal(row.profileLeft, 86);
    assert.equal(row.profileSlot, profileSlot);
    assert.equal(row.leading, row.profileLeft + row.profileSlot);
    assert.equal(row.right, 84);
    assert.equal(row.pageWidth + row.leading + row.right, 900);
  }
});

test("fullscreen reserves the base name slot and no slot when no name shows", () => {
  for (const profileWidth of [32, 80, 140]) {
    const row = topStripLeading(900, profileWidth, true);
    assert.equal(row.profileLeft, 8);
    assert.equal(row.profileSlot, Math.max(84, profileWidth + 8));
    assert.equal(row.leading, 8 + row.profileSlot);
  }
  assert.equal(topStripLeading(900, 0, true).leading, 8);
  assert.equal(topStripLeading(30, 140, true).pageWidth, 0);
});
