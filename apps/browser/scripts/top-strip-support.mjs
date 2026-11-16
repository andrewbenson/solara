import assert from "node:assert/strict";

export function screenMatrix(visibleFrame, requested) {
  assert.ok(Array.isArray(visibleFrame) && visibleFrame.length === 4 && visibleFrame.every(Number.isFinite) && visibleFrame[2] >= 1 && visibleFrame[3] >= 1, `screen visible frame is unavailable or invalid: ${JSON.stringify(visibleFrame)}`);
  const maximum = Math.floor(visibleFrame[2]);
  const widths = requested.filter((width) => width <= maximum);
  const skipped = requested.filter((width) => width > maximum);
  if (skipped.length && !widths.includes(maximum)) widths.push(maximum);
  return { visibleFrame, maximum, widths, skipped, height: Math.min(800, Math.floor(visibleFrame[3])) };
}

export function failedConditions(conditions) {
  return Object.entries(conditions).flatMap(([name, condition]) => {
    try { return condition() ? [] : [name]; }
    catch (error) { return [`${name} (${error.message})`]; }
  });
}

export function downloadSamples(width, height) {
  const points = [];
  for (let y = 60; y < Math.min(700, height); y += 4) points.push([Math.max(0, width - 100), y]);
  const verticalCount = points.length;
  for (let x = Math.max(0, width - 500); x < width; x += 4) points.push([x, Math.min(140, height - 1)]);
  return { points, verticalCount };
}
