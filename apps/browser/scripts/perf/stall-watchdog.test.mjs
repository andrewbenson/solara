import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { stallDelta, measureStalls, readStallState, stallCheckpoint } from './stall-watchdog.mjs';

const state = (extra = {}) => ({ schema: 1, pid: 42, session: 'one', startedMs: 50, ready: true, count: 0, totalMs: 0, dropped: 0, updatedMs: 100, completedThroughMs: 100, ioError: false, ...extra });

test('checkpoint deltas retain zero, count and full duration', () => {
  assert.deepEqual(stallDelta(state(), state({ count: 2, totalMs: 101, updatedMs: 200, completedThroughMs: 200 })), { status: 'ok', count: 2, totalMs: 101, fromMs: 100, toMs: 200 });
  assert.equal(stallDelta(state(), state()).count, 0);
});

for (const [name, change] of [['restart', { session: 'two' }], ['loss', { dropped: 1 }], ['IO', { ioError: true }], ['regression', { count: -1 }], ['invalid', { totalMs: NaN }]]) test(`${name} is pending`, () => {
  assert.equal(stallDelta(state(), state(change)).status, 'pending');
});

test('locked windows retain raw totals and stay pending', () => {
  const result = stallDelta(state(), state({ count: 1, totalMs: 20 }), { locked: true });
  assert.equal(result.status, 'pending');
  assert.equal(result.count, 1);
  assert.match(result.reason, /locked/);
});

test('unavailable telemetry never becomes zero while scenario still executes', async () => {
  let ran = 0;
  const result = await measureStalls({ checkpoint: async () => { throw Error('missing'); }, locked: () => false }, async () => ++ran);
  assert.equal(result.value, 1);
  assert.equal(ran, 1);
  assert.equal(result.stalls.status, 'pending');
  assert.equal(result.stalls.count, undefined);
});

test('scenario failure propagates', async () => {
  await assert.rejects(measureStalls({ checkpoint: async () => state(), locked: () => false }, async () => { throw Error('scenario failed'); }), /scenario failed/);
});

test('reader rejects another process and malformed snapshots', () => {
  assert.throws(() => readStallState('/unused', 43, () => JSON.stringify(state())), /pid/);
  assert.throws(() => readStallState('/unused', 42, () => '{'), /JSON/);
});


test('checkpoint ignores stale responses and waits for its correlated barrier', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'watchdog-'));
  let timer;
  try {
    writeFileSync(join(dir, 'main-thread-stalls-response.json'), JSON.stringify({ ...state(), id: 'stale' }));
    timer = setInterval(() => {
      try {
        const request = JSON.parse(readFileSync(join(dir, 'main-thread-stalls-request.json'), 'utf8'));
        writeFileSync(join(dir, 'main-thread-stalls-response.json'), JSON.stringify({ ...state({ count: 1, totalMs: 20 }), id: request.id }));
      } catch {}
    }, 5);
    const result = await stallCheckpoint(dir, 42, { timeoutMs: 500 });
    assert.equal(result.count, 1);
    assert.notEqual(result.id, 'stale');
  } finally {
    clearInterval(timer);
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a missing watcher has a deadline and a dead instance fails immediately', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'watchdog-'));
  try {
    await assert.rejects(stallCheckpoint(dir, 42, { timeoutMs: 20 }), /ENOENT|missing/);
    await assert.rejects(stallCheckpoint(dir, 42, { alive: () => false }), /instance exited/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('cumulative startup uses observer installation as its coverage boundary', async () => {
  const snapshots = [state({ count: 1, totalMs: 20 }), state({ count: 2, totalMs: 100, completedThroughMs: 200 })];
  const measured = await measureStalls({ checkpoint: async () => snapshots.shift(), cumulative: true }, async () => 'startup');
  assert.equal(measured.stalls.count, 2);
  assert.equal(measured.stalls.fromMs, 50);
});
