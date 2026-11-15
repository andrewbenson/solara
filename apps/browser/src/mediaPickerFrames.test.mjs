import assert from "node:assert/strict";
import { test } from "node:test";
import { mediaPickerFrames } from "../scripts/lib/media-picker-frames.mjs";

test("media picker expectations retain the 1280 point fixture's placement", () => {
  assert.deepEqual(mediaPickerFrames(1280), {
    cast: [925, 55, 340, 185],
    share: [501.5, 55, 460, 423],
  });
});

test("media picker expectations use the actual window width after screen constraint", () => {
  assert.deepEqual(mediaPickerFrames(1024), {
    cast: [669, 55, 340, 185],
    share: [373.5, 55, 460, 423],
  });
});

test("media picker expectations keep the margins when a pane narrows both pickers", () => {
  assert.deepEqual(mediaPickerFrames(500), {
    cast: [206, 55, 279, 185],
    share: [202, 55, 279, 423],
  });
});
