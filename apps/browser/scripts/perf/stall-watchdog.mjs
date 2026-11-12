import { randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const here = dirname(fileURLToPath(import.meta.url));

export function stallLibrary(toolDir) {
  mkdirSync(toolDir, { recursive: true });
  const source = join(here, '../../../../packages/shell/ios/MainThreadStallWatchdog.m');
  const lib = join(toolDir, 'main-thread-stalls.dylib');
  const compile = ['-dynamiclib', '-std=c11', '-O2', '-fobjc-arc', '-DSOLARA_STALL_BENCH=1', '-framework', 'AppKit', '-arch', 'arm64', '-arch', 'x86_64'];
  const fingerprint = JSON.stringify({ source: readFileSync(source, 'utf8'), compile });
  if (!existsSync(lib) || !existsSync(`${lib}.src`) || readFileSync(`${lib}.src`, 'utf8') !== fingerprint) {
    execFileSync('clang', [...compile, source, '-o', lib], { stdio: 'inherit' });
    execFileSync('codesign', ['--force', '--sign', '-', lib]);
    writeFileSync(`${lib}.src`, fingerprint);
  }
  return lib;
}

export function readStallState(dataDir, pid, read = readFileSync) {
  const state = JSON.parse(read(join(dataDir, 'main-thread-stalls-state.json'), 'utf8'));
  if (state.schema !== 1 || state.pid !== pid) throw Error('watchdog schema or pid mismatch');
  if (state.ready !== true || typeof state.ioError !== 'boolean' || !state.session) throw Error('watchdog is not ready');
  for (const key of ['count', 'totalMs', 'dropped', 'updatedMs', 'completedThroughMs']) {
    if (!Number.isFinite(state[key]) || state[key] < 0) throw Error(`invalid watchdog ${key}`);
  }
  if (!Number.isSafeInteger(state.count) || !Number.isSafeInteger(state.dropped)) throw Error('invalid watchdog counters');
  return state;
}

export async function stallCheckpoint(dataDir, pid, { timeoutMs = 3000, alive = () => true } = {}) {
  const asked = performance.now();
  const id = randomUUID();
  const request = join(dataDir, 'main-thread-stalls-request.json');
  const temporary = `${request}.${id}.tmp`;
  writeFileSync(temporary, JSON.stringify({ id, pid }));
  renameSync(temporary, request);
  let reason = 'watchdog checkpoint missing';
  while (performance.now() - asked < timeoutMs) {
    if (!alive()) throw Error('instance exited while reading watchdog');
    try {
      const response = JSON.parse(readFileSync(join(dataDir, 'main-thread-stalls-response.json'), 'utf8'));
      if (response.id === id) {
        const state = readStallState(dataDir, pid, () => JSON.stringify(response));
        if (state.ioError) throw Error('watchdog IO failure');
        return state;
      }
    } catch (error) {
      reason = error.message;
    }
    await sleep(10);
  }
  throw Error(reason);
}

export function stallDelta(before, after, { locked = false } = {}) {
  const valid = (x) => x?.schema === 1 && x.ready && x.session && ['count', 'totalMs', 'dropped', 'updatedMs', 'completedThroughMs'].every((k) => Number.isFinite(x[k]) && x[k] >= 0) && Number.isSafeInteger(x.count) && Number.isSafeInteger(x.dropped);
  if (!valid(before) || !valid(after)) return { status: 'pending', reason: 'invalid watchdog snapshot' };
  if (before.pid !== after.pid || before.session !== after.session) return { status: 'pending', reason: 'watchdog session restarted' };
  if (before.ioError || after.ioError) return { status: 'pending', reason: 'watchdog IO failure' };
  if (before.dropped || after.dropped) return { status: 'pending', reason: 'watchdog records dropped' };
  if (after.count < before.count || after.totalMs < before.totalMs || after.completedThroughMs < before.completedThroughMs) return { status: 'pending', reason: 'watchdog counters regressed' };
  const totals = { count: after.count - before.count, totalMs: after.totalMs - before.totalMs, fromMs: before.completedThroughMs, toMs: after.completedThroughMs };
  return locked ? { status: 'pending', reason: 'screen locked or display asleep', ...totals } : { status: 'ok', ...totals };
}

export async function measureStalls({ checkpoint, locked = () => false, cumulative = false }, run) {
  let before;
  let failure;
  const lockedBefore = locked();
  try { before = await checkpoint(); } catch (error) { failure = error.message; }
  const value = await run();
  const lockedAfter = locked();
  let after;
  try { after = await checkpoint(); } catch (error) { failure = error.message; }
  if (failure) return { value, stalls: { status: 'pending', reason: failure } };
  if (cumulative) {
    if (!Number.isFinite(after.startedMs)) return { value, stalls: { status: 'pending', reason: 'watchdog installation boundary missing' } };
    before = { ...before, count: 0, totalMs: 0, completedThroughMs: after.startedMs };
  }
  return { value, stalls: stallDelta(before, after, { locked: lockedBefore || lockedAfter }) };
}
