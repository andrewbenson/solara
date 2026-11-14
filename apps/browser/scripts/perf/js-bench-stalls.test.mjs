import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import test from 'node:test';
import vm from 'node:vm';
import { measureStalls } from './stall-watchdog.mjs';

const source = readFileSync(new URL('./js-bench.mjs', import.meta.url), 'utf8');
const runSource = source.slice(source.indexOf('async function run() {'), source.indexOf('\nconst HOST ='));

test('JS benchmark launches Debug against its selected Metro port', async () => {
  let args;
  const start = source.indexOf('export async function launch(');
  const end = source.indexOf('\nconst UBO_ID', start);
  const context = vm.createContext({
    binaryOf: () => '/bench/Solara.app/Contents/MacOS/Solara', realpathSync: (path) => path,
    writeSwitches() {}, pidsOf: () => args ? [42] : [],
    process: { env: { METRO_PORT: '8189' } },
    uiGateLaunching: async () => {}, uiGateWatch() {},
    execFileSync: (_command, argv) => { args = argv; }, sleep: async () => {},
  });
  await vm.runInContext(`${source.slice(start, end).replaceAll('export ', '')}\nlaunch('/bench/Solara.app', '/scratch/data', 9222)`, context);
  assert.ok(args.includes('SOLARA_JS_LOCATION=localhost:8189'));
});

test('JS startup and launch retain complete stalls when a checkpoint spans more than three seconds', async () => {
  let report;
  let injected;
  let quitCount = 0;
  let checkpoint = 0;
  const snapshots = [
    { count: 1, totalMs: 20 }, { count: 2, totalMs: 3700 },
    { count: 2, totalMs: 3700 }, { count: 3, totalMs: 3720 },
    { count: 3, totalMs: 3720 }, { count: 4, totalMs: 3740 },
  ];
  const context = vm.createContext({
    flags: { app: '/candidate/Solara.app', bundle: '/candidate/main.jsbundle', label: 'candidate', runs: '1', scenarios: 'startup,launch,idle' },
    defaultOut: '/scratch', dirname, join, ALL: [], BENCH_REVISION: 7,
    rmSync() {}, mkdirSync() {}, execFileSync: () => '0.3.3', cpSync() {},
    resignForBench: (_app, _clone, options) => assert.ok(options.extra.includes('com.apple.security.cs.allow-dyld-environment-variables')),
    stallLibrary: () => '/scratch/tools/main-thread-stalls.dylib',
    startServer: async () => ({ close() {} }),
    readFileSync: () => 'return 1;', here: '/scripts', writeSeed() {}, smallSession() {},
    writeFileSync: (_path, text) => { report = JSON.parse(text); },
    launch: async (_app, _data, _port, env) => { injected = env; return { pid: 42, launchedAt: 50 }; },
    evaluate: async (_data, _pid, body) => body.startsWith('return acBench.run') ? { stats: { commits: 2 } } : 3,
    screenLocked: () => false, alive: () => true,
    stallCheckpoint: async (_data, _pid, { timeoutMs = 3000 }) => {
      const snapshot = { schema: 1, ready: true, ioError: false, session: 'one', pid: 42, dropped: 0, startedMs: 60, updatedMs: 100 + checkpoint, completedThroughMs: 100 + checkpoint, ...snapshots[checkpoint++] };
      if ((checkpoint === 2 || checkpoint === 4) && timeoutMs < 3634) throw Error('watchdog checkpoint missing');
      if (checkpoint > 4) assert.equal(timeoutMs, 3000);
      return snapshot;
    },
    measureStalls, blockerState: async () => null,
    quit: async () => { quitCount++; },
    statSync: () => ({ size: 1 }), existsSync: () => false,
    runRevision: () => 3, summarize: () => ({}), printSummary() {},
    process: { stderr: { write() {} } }, console: { log() {} }, Date, JSON,
  });
  await vm.runInContext(`${runSource}\nrun()`, context);
  assert.equal(injected.DYLD_INSERT_LIBRARIES, '/scratch/tools/main-thread-stalls.dylib');
  assert.equal(report.results[0].startup.stats.commits, 2);
  assert.equal(report.results[0].stalls.startup.count, 2);
  assert.equal(report.results[0].stalls.startup.fromMs, 60);
  assert.equal(report.results[0].stalls.startup.status, 'ok');
  assert.equal(report.results[0].stalls.startup.totalMs, 3700);
  assert.equal(report.results[0].stalls.launch.status, 'ok');
  assert.equal(report.results[0].stalls.launch.count, 3);
  assert.equal(report.results[0].stalls.launch.fromMs, 60);
  assert.equal(report.results[0].stalls.idle.count, 1);
  assert.equal(report.results[0].stalls.idle.totalMs, 20);
  assert.equal(report.stallRevision, 1);
  assert.equal(quitCount, 1);
});
