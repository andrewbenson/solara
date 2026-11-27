import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { after, beforeEach, test } from "node:test";

const f = globalThis.memoryTrimTest = { env: {}, idle: 2, quitting: false, engine: 0, gc: 0, heap: 100, replies: [], listeners: [] };
const settingsURL = new URL("../../../../packages/settings/src/index.ts", import.meta.url).href;
const registrationURL = new URL("../components/settings/nativeSettings.ts", import.meta.url).href;
const fake = (source) => ({ url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true });
const store = `export const useBrowser = { getState: () => ({ tabs: {}, ui: { focusedWindowId: null }, windows: {}, profileOrder: [] }), subscribe: (listener) => { globalThis.memoryTrimTest.listeners.push(listener); return () => {}; } };`;
const unrelated = {
  "../../lib/actions": ["openUrls"], "../../lib/cliControl": ["installCliInBackground", "useCli"],
  "../../store/model": ["engineProfile"],
  "../pages/urls": ["openInternalPage"], "./windows": ["openImport", "openSettings"],
  "./native/autofill": ["autofillHandlers"],
  "./native/replica": ["replicaHandlers"], "./native/live": ["liveHandlers"],
  "./native/onboarding": ["onboardingHandlers", "publishOnboarding"], "./native/passwords": ["passwordsHandlers", "publishPasswords"],
  "./native/privacy": ["privacyHandlers", "publishPrivacy"], "./native/profiles": ["profilesHandlers", "publishProfiles"],
  "./native/shortcuts": ["shortcutsHandlers"], "./native/sync": ["syncHandlers", "publishSync"],
};
registerHooks({
  resolve(specifier, context, next) {
    if (context.parentURL === settingsURL && specifier === "expo-modules-core") return fake(`export const requireOptionalNativeModule = () => ({ available: () => true, addListener: (name, listener) => { globalThis.memoryTrimTest.call = listener; return { remove() {} }; }, publish: async () => {}, reply: async (id, result, error) => { globalThis.memoryTrimTest.replies.push({ id, result, error }); } });`);
    if (context.parentURL?.endsWith("/lib/memoryTrim.ts")) {
      if (specifier === "@solara/solaracore") return fake(`export const inputIdleSeconds = () => globalThis.memoryTrimTest.idle; export const trimEngineMemory = async () => { globalThis.memoryTrimTest.engine++; };`);
      if (specifier === "@solara/shell") return fake(`export const killSwitchEnvironment = (name) => globalThis.memoryTrimTest.env[name] ?? null;`);
      if (specifier === "./native") return fake(`export const isQuitting = () => globalThis.memoryTrimTest.quitting;`);
      if (specifier === "../store/browser") return fake(store);
    }
    if (context.parentURL !== registrationURL) return next(specifier, context);
    if (specifier === "@solara/settings") return { url: settingsURL, shortCircuit: true };
    if (specifier === "../../store/browser") return fake(store);
    if (specifier in unrelated) return fake(unrelated[specifier].map((name) => `export const ${name} = ${name === "useCli" ? "{ getState: () => ({}), subscribe: () => () => {} }" : name.endsWith("Handlers") ? "{}" : "() => null"};`).join("\n"));
    return next(specifier, context);
  },
  load(url, context, next) {
    if (url === settingsURL) return { format: "module-typescript", source: readFileSync(new URL(url), "utf8").replace(/^export \* from .*;$/gm, ""), shortCircuit: true };
    return next(url, context);
  },
});
const original = { setTimeout, clearTimeout, now: Date.now, gc: globalThis.gc, HermesInternal: globalThis.HermesInternal };
let now = 100000;
let serial = 0;
const timers = new Map();
globalThis.setTimeout = (run, ms) => { const id = ++serial; timers.set(id, { run, due: now + ms, ms }); return id; };
globalThis.clearTimeout = (id) => timers.delete(id);
Date.now = () => now;
globalThis.HermesInternal = { getInstrumentedStats: () => ({ js_heapSize: f.heap }) };
globalThis.gc = () => { f.gc++; f.heap -= 10; };
const registration = await import("../components/settings/nativeSettings.ts");
assert.equal(registration.startNativeSettings(), true);
assert.equal(timers.size, 0);
assert.equal(f.gc, 0);
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
async function request() { const id = ++serial; f.call({ id, name: "memory.compact", args: "[]" }); await flush(); return id; }
async function next(late = 0) {
  assert.equal(timers.size, 1, "one pending compaction step");
  const [id, timer] = timers.entries().next().value;
  timers.delete(id);
  now = timer.due + late;
  timer.run();
  await flush();
}
async function drain() { for (let i = 0; timers.size && i < 100; i++) await next(); assert.equal(timers.size, 0); }
function replied(id, error = null) { assert.deepEqual(f.replies, [{ id, result: null, error }]); }
beforeEach(() => {
  assert.equal(timers.size, 0);
  Object.assign(f, { env: {}, idle: 2, quitting: false, engine: 0, gc: 0, heap: 100, replies: [] });
  globalThis.HermesInternal = { getInstrumentedStats: () => ({ js_heapSize: f.heap }) };
  globalThis.gc = () => { f.gc++; f.heap -= 10; };
});
after(() => { globalThis.setTimeout = original.setTimeout; globalThis.clearTimeout = original.clearTimeout; Date.now = original.now; globalThis.gc = original.gc; globalThis.HermesInternal = original.HermesInternal; delete globalThis.memoryTrimTest; });

test("the registered memory.compact bridge waits for eight shrinking heap collections", async () => {
  const id = await request();
  assert.deepEqual(f.replies, [], "native completion waits for compaction");
  assert.equal(f.gc, 1);
  assert.equal(timers.values().next().value.ms, 250);
  await drain();
  assert.equal(f.gc, 8);
  assert.equal(f.engine, 0);
  replied(id);
});
test("compaction stops when the heap no longer shrinks", async () => {
  globalThis.gc = () => { f.gc++; if (f.gc === 1) f.heap -= 10; };
  const id = await request();
  await next();
  assert.equal(f.gc, 2);
  assert.equal(timers.size, 0);
  assert.equal(f.engine, 0);
  replied(id);
});
test("each step waits for two seconds of input idle", async () => {
  f.idle = 1.999;
  const id = await request();
  assert.equal(f.gc, 0);
  assert.equal(timers.values().next().value.ms, 1000);
  f.idle = 2;
  await next();
  assert.equal(f.gc, 1);
  f.idle = 0;
  await next();
  assert.equal(f.gc, 1);
  assert.equal(timers.values().next().value.ms, 1000);
  f.idle = 2;
  await drain();
  assert.equal(f.gc, 8);
  replied(id);
});
test("50 ms timer lateness postpones and 49 ms allows a collection", async () => {
  const id = await request();
  await next(50);
  assert.equal(f.gc, 1);
  assert.equal(timers.values().next().value.ms, 1000);
  await next(49);
  assert.equal(f.gc, 2);
  await drain();
  replied(id);
});
test("thirty busy postponements across all steps exhaust and resolve the request", async () => {
  f.idle = 0;
  const id = await request();
  for (let i = 0; i < 15; i++) await next();
  f.idle = 2;
  await next();
  assert.equal(f.gc, 1);
  f.idle = 0;
  for (let i = 0; i < 15; i++) await next();
  assert.equal(timers.size, 0);
  assert.equal(f.gc, 1);
  replied(id);
});
test("quitting completes before or between collections", async () => {
  f.quitting = true;
  let id = await request();
  assert.equal(f.gc, 0);
  assert.equal(timers.size, 0);
  replied(id);
  f.replies = [];
  f.quitting = false;
  id = await request();
  f.quitting = true;
  await next();
  assert.equal(f.gc, 1);
  assert.equal(timers.size, 0);
  assert.equal(f.engine, 0);
  replied(id);
});
test("only exact heap off spellings disable compaction", async () => {
  for (const value of ["off", "0", "false", "OFF", "False", " off", "false ", "on", undefined]) {
    f.env = { SOLARA_MEMORY_TRIM_HEAP: value, SOLARA_MEMORY_TRIM: "off", SOLARA_MEMORY_TRIM_ENGINE: "off" };
    f.gc = 0;
    f.replies = [];
    const id = await request();
    await drain();
    assert.equal(f.gc, ["off", "0", "false"].includes(value) ? 0 : 8, String(value));
    assert.equal(f.engine, 0);
    replied(id);
  }
});
test("missing gc or heap stats resolves as a no-op", async () => {
  for (const support of ["gc", "stats", "heap"]) {
    globalThis.gc = support === "gc" ? undefined : () => { f.gc++; };
    globalThis.HermesInternal = support === "stats" ? undefined : { getInstrumentedStats: () => support === "heap" ? {} : { js_heapSize: 100 } };
    f.replies = [];
    const id = await request();
    assert.equal(f.gc, 0);
    assert.equal(timers.size, 0);
    replied(id);
  }
});
test("unavailable idle input retains the existing idle fallback", async () => {
  f.idle = null;
  const id = await request();
  await drain();
  assert.equal(f.gc, 8);
  replied(id);
});
test("an asynchronous collection error rejects through the settings bridge", async () => {
  globalThis.gc = () => { f.gc++; if (f.gc === 2) throw new Error("collection failed"); f.heap -= 10; };
  const id = await request();
  await next();
  assert.equal(timers.size, 0);
  replied(id, "collection failed");
});
test("tab changes schedule no independent compaction", () => {
  const windows = {};
  for (const listener of f.listeners) listener({ tabs: { a: {}, b: {} }, windows, ui: { focusedWindowId: null } }, { tabs: {}, windows, ui: { focusedWindowId: null } });
  assert.equal(timers.size, 0);
  assert.equal(f.gc, 0);
  assert.equal(f.engine, 0);
  assert.equal(f.listeners.length, 0, "native Settings no longer mirrors the focused extension profile");
});

test("tab changes leave an in-flight compaction timer alone", async () => {
  const id = await request();
  const pending = [...timers.entries()];
  const windows = {};
  for (const listener of f.listeners) listener({ tabs: { a: {} }, windows, ui: { focusedWindowId: null } }, { tabs: {}, windows, ui: { focusedWindowId: null } });
  assert.deepEqual([...timers.entries()], pending);
  await drain();
  assert.equal(f.gc, 8);
  replied(id);
});
test("a second native request has no quiet delay or minimum gap", async () => {
  let id = await request();
  await drain();
  replied(id);
  f.replies = [];
  f.gc = 0;
  id = await request();
  assert.equal(f.gc, 1);
  assert.equal(timers.values().next().value.ms, 250);
  await drain();
  replied(id);
});
test("an immediate collection error rejects through the settings bridge", async () => {
  globalThis.gc = () => { throw new Error("initial collection failed"); };
  const id = await request();
  assert.equal(timers.size, 0);
  replied(id, "initial collection failed");
});
