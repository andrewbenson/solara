import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import test from "node:test";
import vm from "node:vm";

const require = createRequire(import.meta.url);
const RNPromise = require("promise/setimmediate/es6-extensions");
require("promise/setimmediate/finally");
const source = readFileSync(new URL("./bench-app.js", import.meta.url), "utf8");

function probe() {
  let stats;
  const reset = () => (stats = { timers: {} });
  reset();
  const counted = (label, callback) => (...args) => {
    try {
      return callback(...args);
    } finally {
      stats.timers[label] = (stats.timers[label] ?? 0) + 1;
    }
  };
  return {
    acPerf: { reset, read: () => ({ ...stats }), now: () => performance.now(), batch: (fn) => fn(), marks: {} },
    setTimeout: (callback, ms, ...rest) => setTimeout(counted("setTimeout:anonymous", callback), ms, ...rest),
    countImmediates: () => {
      const original = globalThis.setImmediate;
      globalThis.setImmediate = (callback, ...rest) => original(counted("setImmediate:anonymous", callback), ...rest);
      return () => (globalThis.setImmediate = original);
    },
  };
}

function benchWithApp(onPointer = () => {}) {
  const p = probe();
  const rows = Array.from({ length: 6 }, (_, i) => ({ kind: "row", key: `t:${i}`, h: 30, y: 40 + i * 30 }));
  const state = {
    ui: { focusedWindowId: "w" },
    windows: { w: { frame: [0, 0, 1200, 800], profileId: "p", activeTabIds: { p: "a" } } },
    live: { a: { isLoading: false } },
  };
  const context = vm.createContext({
    Promise: RNPromise,
    setTimeout: p.setTimeout,
    clearTimeout,
    performance,
    acPerf: p.acPerf,
    ac: { store: { getState: () => state }, shell: { devSetPointer: (w, point) => (onPointer(point, p.setTimeout), RNPromise.resolve(true)) } },
    expo: {
      modules: {
        SolaraSidebarDrag: { scrollTo: () => RNPromise.resolve(true), probe: () => JSON.stringify({ viewport: { y: 0, h: 800 }, scrollY: 0, items: rows }) },
        SolaraHosted: { sidebarRowFrame: (w, key) => RNPromise.resolve({ x: 0, y: rows.find((r) => r.key === key).y, width: 240, height: 30 }) },
      },
    },
  });
  context.globalThis = context;
  vm.runInContext(`(function () {\n${source}\n})();`, context);
  return { bench: context.acBench, countImmediates: p.countImmediates };
}

test("the hover scenario counts none of its own timers or promise steps when the app does nothing", async () => {
  const { bench, countImmediates } = benchWithApp();
  const restore = countImmediates();
  try {
    const { steps, stats } = await bench.run("hover", { rows: 4, from: 0, gapMs: 5 });
    assert.equal(steps.length, 5);
    assert.equal(JSON.stringify(stats.timers ?? {}), "{}");
  } finally {
    restore();
  }
});

test("the app's own timers and promise steps after each pointer move are still counted", async () => {
  const { bench, countImmediates } = benchWithApp((point, appTimeout) => {
    if (!point) return;
    appTimeout(() => {}, 0);
    RNPromise.resolve().then(() => {});
  });
  const restore = countImmediates();
  try {
    const { stats } = await bench.run("hover", { rows: 4, from: 0, gapMs: 5 });
    assert.deepStrictEqual({ ...stats.timers }, { "setTimeout:anonymous": 5, "setImmediate:anonymous": 5 });
  } finally {
    restore();
  }
});
