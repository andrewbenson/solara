import assert from "node:assert/strict";
import test from "node:test";
import { assertDockTrace, dockSpring } from "./top-strip-dock.mjs";

function trace(fps, { open = false, reversal = false } = {}) {
  const rows = [];
  const add = (t, p, v, target, moving) => rows.push([t, p, v, target, !target && !moving ? 1 : 0,
    -42 * (1 - p), 6 + 36 * p, 20.75 - Math.round(42 * (1 - p) * 2) / 2,
    !target && !moving ? 1 : 0, moving ? 1 : 0]);
  let from = open ? 0 : 1, to = open ? 1 : 0, velocity = 0, time = 100;
  add(0, from, 0, 1 - to, false);
  add(time, from, velocity, to, true);
  for (let frame = 1; frame <= 40; frame++) {
    const sample = dockSpring(from, to, velocity, frame / fps);
    add(time + frame * 1000 / fps, sample.position, sample.velocity, to, !sample.done);
    if (reversal && frame === 6 && to === 0) {
      from = sample.position;
      velocity = sample.velocity;
      to = 1;
      time += frame * 1000 / fps;
      add(time, from, velocity, to, true);
      frame = 0;
    }
    if (sample.done) break;
  }
  return rows;
}

for (const fps of [30, 60]) {
  for (const options of [{}, { open: true }, { reversal: true }]) {
    test(`${fps} Hz ${JSON.stringify(options)} accepts model samples`, () => {
      assertDockTrace(trace(fps, options), { fps, native: true, ...options });
    });
  }
}

test("rejects a wrong spring even when endpoints match", () => {
  const rows = trace(60);
  rows[4][1] += 0.1;
  rows[4][5] = -42 * (1 - rows[4][1]);
  rows[4][6] = 6 + 36 * rows[4][1];
  rows[4][7] = 20.75 - Math.round(42 * (1 - rows[4][1]) * 2) / 2;
  assert.throws(() => assertDockTrace(rows, { fps: 60, native: true }), /spring error/);
});

test("rejects reversal velocity reset", () => {
  const rows = trace(60, { reversal: true });
  rows.find((r, i) => i > 1 && r[3] === 1)[2] = 0;
  assert.throws(() => assertDockTrace(rows, { fps: 60, native: true, reversal: true }), /velocity|spring/);
});

test("rejects a late native peek and accepts a one-frame RN mount", () => {
  const rows = trace(60);
  const last = rows.at(-1);
  last[8] = 0;
  rows.push([...last]);
  rows.at(-1)[0] += 1000 / 60;
  rows.at(-1)[8] = 1;
  assert.throws(() => assertDockTrace(rows, { fps: 60, native: true }), /peek enables/);
  assertDockTrace(rows, { fps: 60, native: false });
  rows.at(-1)[0] += 1000 / 60;
  assert.throws(() => assertDockTrace(rows, { fps: 60, native: false }), /within one frame/);
});

test("rejects a slow settle without fitting a new start", () => {
  const rows = trace(60).map((r) => [r[0] > 100 ? 100 + (r[0] - 100) * 1.15 : r[0], ...r.slice(1)]);
  assert.throws(() => assertDockTrace(rows, { fps: 60, native: true }), /spring|settles/);
});

test("rejects sparse native motion padded with idle samples", () => {
  const rows = trace(60);
  const sparse = [rows[0], rows[1], ...Array.from({ length: 5 }, () => [...rows.at(-1)])];
  assert.throws(() => assertDockTrace(sparse, { fps: 60, native: true }), /moving samples|missing display sample/);
});

for (const native of [true, false]) {
  test(`${native ? "native" : "RN"} rejects a position jump at reversal`, () => {
    const rows = trace(60, { reversal: true });
    const turnIndex = rows.findIndex((r, i) => i > 1 && r[3] === 1);
    const turn = rows[turnIndex];
    turn[1] += 0.2;
    for (const row of rows.slice(turnIndex)) {
      const model = dockSpring(turn[1], 1, turn[2], (row[0] - turn[0]) / 1000);
      row[1] = model.position;
      row[2] = model.velocity;
      row[5] = -42 * (1 - row[1]);
      row[6] = 6 + 36 * row[1];
      row[7] = 20.75 - Math.round(42 * (1 - row[1]) * 2) / 2;
    }
    if (!native) turn[0] += 1;
    assert.throws(() => assertDockTrace(rows, { fps: 60, native, reversal: true }), /preceding position/);
  });
}

for (const fps of [30, 60]) {
  test(`${fps} Hz rejects a missing final moving sample`, () => {
    const rows = trace(fps);
    rows.splice(rows.length - 2, 1);
    assert.throws(() => assertDockTrace(rows, { fps, native: true }), /missing display sample/);
  });
}

test("requires moving samples after a reversal", () => {
  const rows = trace(60, { reversal: true });
  const turnIndex = rows.findIndex((r, i) => i > 1 && r[3] === 1);
  rows.splice(turnIndex + 3, rows.length - turnIndex - 4);
  assert.throws(() => assertDockTrace(rows, { fps: 60, native: true, reversal: true }), /moving samples|missing display sample/);
});

test("RN projected columns are not actual geometry assertions", () => {
  const rows = trace(60);
  for (const row of rows) row.splice(5, 3, 123, 456, 789);
  assertDockTrace(rows, { fps: 60, native: false });
  assert.throws(() => assertDockTrace(rows, { fps: 60, native: true }), /endpoint|follows/);
});


for (const options of [{}, { open: true }, { reversal: true }]) {
  test(`rejects insufficient moving rows despite dense timestamps ${JSON.stringify(options)}`, () => {
    const rows = trace(60, options);
    const phaseStart = options.reversal ? rows.findIndex((r, i) => i > 1 && r[3] === 1) : 1;
    for (const row of rows.slice(phaseStart + 3)) row[9] = 0;
    assert.throws(() => assertDockTrace(rows, { fps: 60, native: true, ...options }), /intermediate moving samples/);
  });
}

test("RN inherited frame clock accepts a continuous reversal boundary", () => {
  const rows = trace(60, { reversal: true });
  rows.find((r, i) => i > 1 && r[3] === 1)[0] += 1;
  assertDockTrace(rows, { fps: 60, native: false, reversal: true });
});

test("native still rejects actual intermediate geometry errors", () => {
  for (const column of [5, 6, 7]) {
    const rows = trace(60);
    rows[4][column] += 1;
    assert.throws(() => assertDockTrace(rows, { fps: 60, native: true }), /follow/);
  }
});
