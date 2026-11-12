import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { basename, join } from "node:path";
import { measureStalls } from "./stall-watchdog.mjs";
import test from "node:test";
import vm from "node:vm";

const source = readFileSync(process.env.NATIVE_BENCH_SOURCE ?? new URL("./native-bench.mjs", import.meta.url), "utf8");
const between = (text, start, end) => {
  const from = text.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = text.indexOf(end, from);
  assert.ok(to > from, `missing ${end}`);
  return text.slice(from, to);
};
const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
};
const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };

function driver({ pendingLaunch, pendingQuit, bootError, quitError, stallError = false, locked = false, stallStep = 0 } = {}) {
  const handlers = new Map();
  const registry = new Map();
  const exits = [];
  const launches = [];
  const quits = [];
  let running = false;
  let serverClosed = 0;
  let stallReads = 0;
  const context = vm.createContext({
    FatalError: class FatalError extends Error {},
    opt: { port: undefined, env: [], hold: "0" },
    base: () => "http://127.0.0.1:1234",
    Cdp: class { close() {} },
    join,
    basename,
    measureStalls,
    stallLibrary: () => "/tools/main-thread-stalls.dylib",
    stallCheckpoint: async () => {
      if (stallError) throw Error("watchdog unavailable");
      return { schema: 1, ready: true, pid: 62068, session: "session", count: 2 + stallReads++ * stallStep, totalMs: 100 + (stallReads - 1) * stallStep * 20, dropped: 0, updatedMs: 1200, completedThroughMs: 1200, startedMs: 1000 };
    },
    displayState: () => ({ locked, asleep: false }),
    realpathSync: (path) => path,
    execFileSync: (command) => { if (command === "open") running = true; return "Solara\n"; },
    spawnSync: () => ({ status: running ? 0 : 1, stdout: running ? "62068\n" : "" }),
    freePort: async () => 9222,
    listenerPids: () => [],
    uiGateLaunching: async () => {},
    uiGateWatch: () => {},
    writeSwitches: () => {},
    markerLibrary: () => "/tools/acmark.dylib",
    framesLibrary: () => "/tools/acframes.dylib",
    toolDir: "/tools",
    here: "/bench",
    acperf: () => ({ code: 0, out: "1050" }),
    readFileSync: () => JSON.stringify({ jsStart: 1020 }),
    sleep: async () => {},
    log: () => {},
    server: { close: () => { serverClosed++; } },
    process: {
      env: {},
      on: (name, handler) => { handlers.set(name, handler); },
      exit: (code) => { exits.push(code); },
      kill: (_pid, signal) => { if (!running) throw new Error("gone"); if (signal !== 0) running = false; },
    },
    launchInstance: async (app, options) => {
      launches.push({ app, options });
      if (pendingLaunch) await pendingLaunch.promise;
      running = true;
      const record = {
        pid: 62068, port: 9222, launchedAt: 1000, data: options.data,
        get alive() { return running; },
        quit: async (options) => {
          quits.push(options);
          if (pendingQuit) await pendingQuit.promise;
          if (quitError) throw quitError;
          running = false;
          return { how: "SIGTERM" };
        },
      };
      registry.set(options.data, record);
      return record;
    },
  });
  const lifecycleStart = source.includes("let cleanupPromise;") ? "let cleanupPromise;" : "const cleanup = async";
  vm.runInContext([
    between(source, "const live = new Set();", "const base ="),
    between(source, lifecycleStart, "try {\n  server = await startServer();"),
    "globalThis.bench = { Instance, cleanup, live };",
  ].join("\n"), context);
  const app = new context.bench.Instance({ app: "/bench/Solara.app", env: [], label: "control" }, "/bench/control/data/journeys-0");
  app.waitFile = async () => { if (bootError) throw bootError; return { jsStart: 1020 }; };
  const runMain = ({ fails = false } = {}) => {
    const side = { app: "/bench/Solara.app", src: "/bench/Solara.app", env: [], label: "control", results: { meta: {} } };
    Object.assign(context, {
      startServer: async () => ({ close: () => { serverClosed++; } }),
      sides: [side], candidate: side, only: new Set(["prepare-fixture"]),
      checkPrepared: () => ({}),
      makeTemplate: async () => { await app.launch(); if (fails) throw new Error("phase failed"); },
      prepareFixture: async () => {},
    });
    context.opt.prepared = true;
    const main = source.slice(source.indexOf("try {\n  server = await startServer();"));
    return vm.runInContext(`(async () => { ${main} })()`, context);
  };
  return { ...context.bench, app, registry, exits, handlers, launches, quits, runMain, serverClosed: () => serverClosed };
}

test("J2 uses the shared registered instance and retains benchmark data", async () => {
  const bench = driver();
  await bench.app.launch();
  assert.equal(bench.registry.get(bench.app.dataDir)?.pid, bench.app.pid);
  const { app, options } = bench.launches[0];
  assert.equal(app, "/bench/Solara.app");
  assert.equal(options.data, "/bench/control/data/journeys-0");
  assert.equal(options.js, "none");
  assert.equal(options.ready, false);
  assert.equal(options.keepData, true);
  assert.equal(options.scratchMarker, false);
  assert.deepEqual(Array.from(options.args), ["--mute-audio", "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1, EXCLUDE localhost", "-NSAppSleepDisabled", "YES"]);
  assert.equal(options.env.SOLARA_DRAW_WINDOWS, "1");
  assert.equal(options.env.DYLD_INSERT_LIBRARIES, "/tools/acmark.dylib:/tools/main-thread-stalls.dylib");
  assert.equal(bench.app.t0, 1000);
  assert.equal(bench.app.cdp.port, 9222);
  await bench.cleanup();
  assert.equal(bench.quits.length, 1);
  assert.equal(bench.live.size, 0);
});

for (const [signal, code] of [["SIGINT", 130], ["SIGTERM", 143]]) test(`${signal} waits for a pending launch and quits it before exiting`, async () => {
  const pendingLaunch = deferred();
  const bench = driver({ pendingLaunch });
  const launched = bench.app.launch();
  const rejected = assert.rejects(launched, /stopping/);
  assert.equal(bench.live.size, 1);
  assert.ok(bench.handlers.has(signal));
  bench.handlers.get(signal)();
  await settle();
  assert.deepEqual(bench.exits, []);
  pendingLaunch.resolve();
  await rejected;
  await settle();
  assert.equal(bench.quits.length, 1);
  assert.equal(bench.quits[0].graceful, false);
  assert.deepEqual(bench.exits, [code]);
  assert.equal(bench.live.size, 0);
  await assert.rejects(bench.app.launch(), /stopping/);
});

test("repeated signals share cleanup while a normal quit is pending", async () => {
  const pendingQuit = deferred();
  const bench = driver({ pendingQuit });
  await bench.app.launch();
  const quitting = bench.app.quit();
  await settle();
  assert.equal(bench.live.size, 1);
  bench.handlers.get("SIGINT")();
  bench.handlers.get("SIGINT")();
  bench.handlers.get("SIGTERM")();
  await settle();
  assert.deepEqual(bench.exits, []);
  assert.equal(bench.quits.length, 1);
  pendingQuit.resolve();
  await quitting;
  await bench.cleanup();
  await settle();
  assert.deepEqual(bench.exits, [130]);
  assert.equal(bench.live.size, 0);
  assert.equal(bench.serverClosed(), 1);
});

test("the main normal and exceptional finally paths quit the registered instance once", async () => {
  for (const fails of [false, true]) {
    const bench = driver();
    if (fails) await assert.rejects(bench.runMain({ fails }), /phase failed/);
    else await bench.runMain();
    assert.equal(bench.quits.length, 1);
    assert.equal(bench.live.size, 0);
    assert.equal(bench.serverClosed(), 1);
  }
});

test("boot failure quits an acquired registered instance", async () => {
  const bench = driver({ bootError: new Error("boot failed") });
  await assert.rejects(bench.app.launch(), /boot failed/);
  await bench.cleanup();
  assert.equal(bench.registry.size, 1);
  assert.equal(bench.quits.length, 1);
  assert.equal(bench.live.size, 0);
});

test("shared quit keeps benchmark artifacts and retains default cleanup for ordinary launches", async () => {
  const library = readFileSync(new URL("../../../../scripts/lib/instance.mjs", import.meta.url), "utf8");
  for (const keepData of [false, true]) {
    let running = true;
    const quitData = new Set();
    const context = vm.createContext({
      reportSuppressedSecureInput: () => {}, uiGateKey: () => null, existsSync: () => false,
      process: { env: {} }, quitData, launched: new Map(), join,
      isAlive: () => running,
      keepCrashReports: () => [], tmpdir: () => "/scratch",
      spawnSync: () => { running = false; },
      quitEnded: ({ how }) => how === "quit",
      sleep: async () => {},
    });
    vm.runInContext(between(library, "class Instance {", "export function bundledJsRefusal(") + "globalThis.SharedInstance = Instance;", context);
    const instance = new context.SharedInstance({ pid: 62068, data: "/bench/data", keepData });
    instance.stillOwned = () => running;
    instance.jsErrors = () => "";
    await instance.quit();
    assert.equal(quitData.has(instance.data), !keepData);
  }
});

for (const event of ["uncaughtException", "unhandledRejection"]) test(`${event} quits before failure exit`, async () => {
  const bench = driver();
  await bench.app.launch();
  bench.handlers.get(event)(new Error("callback failed"));
  await settle();
  assert.equal(bench.quits.length, 1);
  assert.equal(bench.quits[0].graceful, false);
  assert.deepEqual(bench.exits, [1]);
  assert.equal(bench.live.size, 0);
});

function sharedDriver({ failRegistry = false } = {}) {
  const library = readFileSync(new URL("../../../../scripts/lib/instance.mjs", import.meta.url), "utf8");
  const registry = new Map();
  const commands = [];
  let running = false;
  const data = "/bench/control/data/journeys-0";
  const binary = "/bench/Solara.app/Contents/MacOS/Solara";
  const context = vm.createContext({
    resolve: (path) => path,
    realPath: (path) => path,
    holdUiGate: async () => ({ state: "/fake/gate", key: null }),
    uiGateKey: () => null,
    quitData: new Set(),
    existsSync: (path) => path === data || registry.has(path),
    mkdirSync: () => {},
    realpathSync: { native: (path) => path },
    readFileSync: (path) => { if (!registry.has(path)) throw new Error("missing"); return registry.get(path); },
    rmSync: (path) => { registry.delete(path); },
    writeFileSync: (path, text) => {
      if (failRegistry && path.endsWith("/instance.json")) throw new Error("registry full");
      registry.set(path, text);
    },
    join,
    basename: (path) => path.split("/").at(-1),
    binaryOf: () => binary,
    parsePort: Number,
    freePort: async () => 9222,
    listenerPids: () => running ? [62068] : [],
    process: { env: {}, kill: () => { running = false; } },
    gateNote: () => {},
    frontApp: () => null,
    binaryPids: () => new Set(),
    execFileSync: (command) => { commands.push(command); if (command === "open") running = true; },
    ownedCandidate: (listeners, _before, commandOf) => {
      if (!listeners.length) return null;
      commandOf(listeners[0]);
      return listeners[0];
    },
    processInfo: () => running ? { started: "a fixed start", command: binary } : null,
    holdNote: () => ({}),
    launched: new Map(),
    isAlive: () => running,
    commandIsBinary: (command, expected) => command === expected,
    reportSuppressedSecureInput: () => {},
    keepCrashReports: () => [], tmpdir: () => "/scratch",
    spawnSync: () => { running = false; },
    quitEnded: ({ how }) => ["quit", "SIGTERM", "SIGKILL"].includes(how),
    sleep: async () => {},
    dirname: (path) => path.slice(0, path.lastIndexOf("/")),
  });
  vm.runInContext([
    between(library, "class Instance {", "export async function launch(").replaceAll("export ", ""),
    between(library, "export async function launch(", "export function reporter(").replaceAll("export ", ""),
    "globalThis.shared = { launch, attach };",
  ].join("\n"), context);
  return { ...context.shared, registry, commands, running: () => running, data };
}

test("the shared launch saves an ac-attachable ownership record with keepData", async () => {
  const shared = sharedDriver();
  const app = await shared.launch("/bench/Solara.app", {
    data: shared.data, js: "none", ready: false, scratchMarker: false, keepData: true,
  });
  const attached = shared.attach(shared.data);
  assert.equal(attached.pid, app.pid);
  assert.equal(attached.started, "a fixed start");
  assert.equal(attached.keepData, true);
  assert.equal(shared.registry.size, 1);
  assert.deepEqual(shared.commands, ["open"]);
  await attached.quit();
  assert.equal(shared.running(), false);
  assert.equal(shared.registry.size, 1);
});

test("shared launch quits its owned process if registration fails", async () => {
  const shared = sharedDriver({ failRegistry: true });
  await assert.rejects(shared.launch("/bench/Solara.app", {
    data: shared.data, js: "none", ready: false, scratchMarker: false, keepData: true,
  }), /registry full/);
  assert.deepEqual(shared.commands, ["open"]);
  assert.equal(shared.running(), false);
  assert.equal(shared.registry.size, 0);
});

test("failed pending launch settles signal cleanup without deadlock", async () => {
  const pendingLaunch = deferred();
  const bench = driver({ pendingLaunch });
  const rejected = assert.rejects(bench.app.launch(), /launch failed/);
  bench.handlers.get("SIGTERM")();
  pendingLaunch.reject(new Error("launch failed"));
  await rejected;
  await settle();
  assert.deepEqual(bench.exits, [143]);
  assert.equal(bench.quits.length, 0);
  assert.equal(bench.live.size, 0);
});

test("cleanup failure reports failure and retains the instance handle", async () => {
  const bench = driver({ quitError: new Error("quit failed") });
  await bench.app.launch();
  bench.handlers.get("SIGTERM")();
  await settle();
  assert.deepEqual(bench.exits, [1]);
  assert.equal(bench.live.size, 1);
  await assert.rejects(bench.cleanup(), /could not quit every bench instance/);
});


test("native scenarios retain per-scenario stalls and a cumulative instance record before quit", async () => {
  const bench = driver();
  bench.app.side.results = {};
  await bench.app.launch();
  const value = await bench.app.measureStalls("typing", async () => "typed");
  assert.equal(value, "typed");
  assert.equal(bench.app.stalls.startup.count, 2);
  assert.equal(bench.app.stalls.typing.status, "ok");
  assert.equal(bench.app.stalls.typing.count, 0);
  await bench.app.done();
  const record = bench.app.side.results.stalls[0];
  assert.equal(record.scenario, "journeys-0");
  assert.equal(record.metrics.instance.count, 2);
  assert.equal(record.metrics.instance.totalMs, 100);
  assert.equal(bench.quits.length, 1);
});

test("watchdog failure and locked screens preserve native scenario work and cleanup with pending counts", async () => {
  for (const options of [{ stallError: true }, { locked: true }]) {
    const bench = driver(options);
    bench.app.side.results = {};
    await bench.app.launch();
    let ran = false;
    await bench.app.measureStalls("switch", async () => { ran = true; });
    assert.equal(ran, true);
    assert.equal(bench.app.stalls.switch.status, "pending");
    await bench.app.done();
    assert.equal(bench.app.side.results.stalls[0].metrics.instance.status, "pending");
    assert.equal(bench.quits.length, 1);
  }
});

test("a failed native scenario is marked pending and retains the original error", async () => {
  const bench = driver();
  await bench.app.launch();
  await assert.rejects(bench.app.measureStalls("switch", async () => { throw Error("native action failed"); }), /native action failed/);
  assert.equal(bench.app.stalls.switch.status, "pending");
  await bench.app.done();
  assert.equal(bench.quits.length, 1);
});


test("repeated native interactions add their stall deltas without double-counting startup", async () => {
  const bench = driver({ stallStep: 1 });
  await bench.app.launch();
  await bench.app.measureStalls("newwindow", async () => {});
  await bench.app.measureStalls("newwindow", async () => {});
  assert.equal(bench.app.stalls.newwindow.count, 2);
  assert.equal(bench.app.stalls.newwindow.totalMs, 40);
  assert.equal(bench.app.stalls.newwindow.status, "ok");
  await bench.app.done();
});
