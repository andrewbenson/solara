import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";
import { runInNewContext } from "node:vm";

const { transpileModule } = createRequire(import.meta.url)("typescript");
const native = readFileSync(new URL("./native.ts", import.meta.url), "utf8");
const harness = readFileSync(new URL("./devHarness.ts", import.meta.url), "utf8");

for (const dev of [false, true]) test(`quit handler counters and lazy persistence access with dev ${dev}`, async () => {
  let listener;
  let flushes = 0;
  let resumes = 0;
  const source = native.slice(native.indexOf("let quitting ="), native.indexOf("export const shellWindowPort"))
    + native.slice(native.indexOf("  onAppEvent((e) =>"), native.indexOf("  const nativeWindows ="));
  const api = runInNewContext(transpileModule(source.replace(/^export /gm, "") + "\n({devQuitHandlerCounts,isQuitting})", { compilerOptions: { target: 9 } }).outputText, {
    __DEV__: dev, store: { getState: () => ({}) }, onAppEvent: (fn) => { listener = fn; },
    finishAnimatedCloses() {}, flushPersistence: () => { flushes++; }, resumePersistence: () => { resumes++; },
    flushBookmarkJournal: async () => true, cancelBookmarkQuit() {}, replyToTerminate() {},
  });
  if (dev) assert.equal(api.devQuitHandlerCounts().willQuit, 0);
  else assert.equal(api.devQuitHandlerCounts(), null);
  listener({ type: "willQuit" });
  listener({ type: "quitCancelled" });
  await Promise.resolve();
  assert.equal(flushes, 1);
  assert.equal(resumes, 1);
  assert.equal(api.isQuitting(), false);
  if (dev) {
    assert.equal(api.devQuitHandlerCounts().willQuit, 1);
    assert.equal(api.devQuitHandlerCounts().quitCancelled, 1);
  }
  const required = [];
  const ac = {};
  const property = harness.slice(harness.indexOf('  if (__DEV__) Object.defineProperty(ac, "persistence"'), harness.indexOf("  (globalThis as"));
  runInNewContext(transpileModule(property, { compilerOptions: { target: 9 } }).outputText, {
    __DEV__: dev, ac, require: (name) => { required.push(name); return {}; },
  });
  assert.deepEqual(required, []);
  assert.equal(Object.hasOwn(ac, "persistence"), dev);
  if (dev) {
    void ac.persistence;
    assert.deepEqual(required, ["./persist", "./persistLatch", "./devRefusalChecks", "../store/nativeStore", "../components/onboarding/state", "../sync/engine", "./native"]);
  }
});
