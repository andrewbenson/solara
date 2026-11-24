import assert from "node:assert/strict";

export function dockSpring(from, to, velocity, seconds) {
  const omega = 2 * Math.PI / 0.215;
  const decay = 0.79 * omega;
  const frequency = omega * Math.sqrt(1 - 0.79 ** 2);
  const displacement = from - to;
  const b = (velocity + decay * displacement) / frequency;
  const envelope = Math.exp(-decay * seconds);
  const wave = displacement * Math.cos(frequency * seconds) + b * Math.sin(frequency * seconds);
  const speed = envelope * (-decay * wave - displacement * frequency * Math.sin(frequency * seconds) + b * frequency * Math.cos(frequency * seconds));
  const position = to + envelope * wave;
  const done = Math.abs(speed) <= 0.01 && Math.abs(to - position) <= 0.001;
  return { position: done ? to : position, velocity: done ? 0 : speed, done };
}

export function assertDockTrace(rows, { fps, native, reversal = false }) {
  assert.ok(rows.length > 6 && rows.length <= 256, `bounded dock samples: ${rows.length}`);
  assert.ok(fps === 30 || fps === 60, `supported display rate: ${fps}`);
  for (const row of rows) {
    assert.equal(row.length, 10);
    assert.ok(row.every(Number.isFinite), `finite sample: ${row}`);
  }
  const startIndex = rows.findIndex((r) => r[9] === 1);
  assert.ok(startIndex > 0, "armed before the command started moving");
  const start = rows[startIndex];
  assert.equal(start[1], 1 - start[3], "command starts at the opposite exact endpoint");
  assert.equal(start[2], 0, "first command starts at rest");
  for (let i = 1; i < rows.length; i++) {
    const gap = rows[i][0] - rows[i - 1][0];
    assert.ok(gap >= 0, "trace time is monotonic");
    if (rows[i - 1][9] === 1) {
      assert.ok(gap <= (native ? 1.75 : 3.5) * 1000 / fps, `missing display sample: ${gap} ms at ${fps} Hz`);
    }
  }
  const turnIndex = rows.findIndex((r, i) => i > startIndex && r[3] !== start[3]);
  assert.equal(turnIndex >= 0, reversal, "only the reversal leg changes target mid-run");
  const end = rows.findLast((r) => r[9] === 0);
  assert.ok(end, "a settled sample was recorded");
  const target = reversal ? 1 : start[3];
  assert.equal(end[1], target, "exact dock endpoint");
  if (native) {
    assert.ok(end[5] === (target ? 0 : -42), "exact strip endpoint");
    assert.equal(end[6], target ? 42 : 6, "exact card endpoint");
    assert.equal(end[7], target ? 20.75 : -21.25, "exact button endpoint");
    for (const row of rows) {
      assert.ok(Math.abs(row[5] - -42 * (1 - row[1])) <= 0.5, "strip follows dock");
      assert.ok(Math.abs(row[6] - (6 + 36 * row[1])) <= 0.5, "card follows dock");
      assert.ok(Math.abs(row[7] - (20.75 - Math.round(42 * (1 - row[1]) * 2) / 2)) <= 0.01, "buttons follow dock");
    }
  }
  const phases = reversal ? [rows.slice(startIndex, turnIndex), rows.slice(turnIndex)] : [rows.slice(startIndex)];
  let worst = 0;
  for (const [index, phase] of phases.entries()) {
    const origin = phase[0];
    const movingSamples = phase.slice(1).filter((row) => row[9] === 1 && row[1] !== origin[1]).length;
    const minimum = reversal ? 3 : fps / 3 - 2;
    assert.ok(movingSamples >= minimum, `phase ${index} has ${movingSamples} intermediate moving samples; expected at least ${minimum}`);
    if (index === 1) {
      assert.ok(Math.abs(origin[1] - rows[turnIndex - 1][1]) <= 0.01, "reversal keeps the preceding position");
    }
    const retargetsOnPreviousFrameClock = !native && index === 1;
    const clock = retargetsOnPreviousFrameClock ? rows[turnIndex - 1][0] : origin[0];
    for (const row of retargetsOnPreviousFrameClock ? phase.slice(1) : phase) {
      const model = dockSpring(origin[1], origin[3], origin[2], (row[0] - clock) / 1000);
      worst = Math.max(worst, Math.abs(row[1] - model.position));
    }
  }
  assert.ok(worst <= 0.05, `frame-by-frame spring error ${worst} exceeds 0.05`);
  const settled = rows.findIndex((r, i) => i > startIndex && r[1] === target && r[9] === 0);
  assert.ok(settled > startIndex, "settle is observed after motion");
  if (!reversal) {
    const endpoint = rows.find((r, i) => i > startIndex && r[1] === target);
    const frames = (endpoint[0] - start[0]) * fps / 1000;
    assert.ok(Math.abs(frames - fps / 3) <= 1, `settles in ${frames.toFixed(2)} frames at ${fps} Hz; expected ${fps / 3}±1`);
  } else {
    const turn = rows[turnIndex], prior = rows[turnIndex - 1];
    assert.ok(Math.abs((turn[0] - start[0]) * fps / 1000 - 6) <= 2, "reverses about six display frames into hide");
    assert.ok(Math.abs(turn[2]) > 0.01, "reversal inherits a nonzero velocity");
    assert.ok(Math.abs(turn[2] - prior[2]) <= 0.01, "reversal keeps the preceding velocity");
    const moving = rows.slice(turnIndex + 1).find((r) => Math.abs(r[1] - turn[1]) > 0.001);
    assert.ok(moving, "reversal moves");
    const clock = native ? turn[0] : prior[0];
    const after = rows.slice(turnIndex + 1);
    const misfit = (velocity) => Math.max(...after.map((r) => Math.abs(r[1] - dockSpring(turn[1], 1, velocity, (r[0] - clock) / 1000).position)));
    assert.ok(misfit(turn[2]) < misfit(0), `the reversal fits a retained velocity (${misfit(turn[2])}) better than a restart from rest (${misfit(0)})`);
    assert.ok(rows.every((r) => r[8] === 0), "interrupted hide never admits peek");
  }
  if (target === 0) {
    const away = rows.findIndex((r) => r[4] === 1);
    const enabled = rows.findIndex((r) => r[8] === 1);
    assert.ok(away >= settled, "away waits for settle");
    assert.ok(enabled >= away, "peek waits for away");
    assert.ok(rows.slice(startIndex, settled).every((r) => r[8] === 0), "peek stays disabled during hide");
    if (native) {
      assert.equal(away, settled, "native away changes on settle sample");
      assert.equal(enabled, settled, "native peek enables on settle sample");
    } else {
      assert.ok(enabled >= 0 && rows[enabled][0] - rows[away][0] <= 1000 / fps + 2, "RN peek mounts within one frame of away");
    }
  } else {
    assert.equal(end[4], 0, "shown dock is not away");
    assert.equal(end[8], 0, "shown dock disables peek");
  }
  return { fps, worst, samples: rows.length };
}
