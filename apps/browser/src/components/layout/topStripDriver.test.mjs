import assert from "node:assert/strict";
import test from "node:test";
import { screenMatrix, failedConditions, downloadSamples } from "../../../scripts/top-strip-support.mjs";

test("strip matrix fits a 1600 by 680 visible screen and records unsupported widths", () => {
  const matrix = screenMatrix([0, 40, 1600, 680], [800, 1000, 1600, 2000]);
  assert.deepEqual(matrix.widths, [800, 1000, 1600]);
  assert.deepEqual(matrix.skipped, [2000]);
  assert.equal(matrix.height, 680);
});

test("strip matrix includes the screen limit when standard widths do not reach it", () => {
  const matrix = screenMatrix([-1280, 0, 1280.75, 720.5], [800, 1000, 1600, 2000]);
  assert.deepEqual(matrix.widths, [800, 1000, 1280]);
  assert.deepEqual(matrix.skipped, [1600, 2000]);
  assert.equal(matrix.height, 720);
  assert.throws(() => screenMatrix(null, [800]), /visible frame/);
});

test("snapshot diagnostics name every failed condition and preserve passing conditions", () => {
  assert.deepEqual(failedConditions({
    "snapshot consistent": () => true,
    "content height is 680": () => false,
    "Downloads has a frame": () => { throw new Error("missing frame"); },
  }), ["content height is 680", "Downloads has a frame (missing frame)"]);
});

test("download samples stay in the available window and split vertical and horizontal sweeps", () => {
  const { points, verticalCount } = downloadSamples(1280, 680);
  assert.equal(verticalCount, 155);
  assert.deepEqual(points[0], [1180, 60]);
  assert.deepEqual(points[154], [1180, 676]);
  assert.deepEqual(points[155], [780, 140]);
  assert.deepEqual(points.at(-1), [1276, 140]);
  assert.ok(points.every(([x, y]) => x < 1280 && y < 680));
});

test("download samples never request a point outside a small window", () => {
  assert.ok(downloadSamples(80, 100).points.every(([x, y]) => x >= 0 && x < 80 && y >= 0 && y < 100));
});
