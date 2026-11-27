import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { test } from "node:test";

globalThis.__DEV__ = false;
globalThis.engineTestRequests = [];
globalThis.engineTestResult = false;
const stubs = {
  "@solara/settings": `export const nativeEngineCommand = async (...args) => { globalThis.engineTestRequests.push(args); return globalThis.engineTestResult; };`,
};
registerHooks({
  resolve(specifier, context, next) {
    if (!context.parentURL?.endsWith("/lib/engines.ts") || !(specifier in stubs)) return next(specifier, context);
    return { url: `data:text/javascript,${encodeURIComponent(stubs[specifier])}`, shortCircuit: true };
  },
});

const { goBackAcrossEngines, openPageIn, persistEngine, togglePageEngine } = await import("./engines.ts");

test("engine back delegates the explicit tab and returns native acceptance", async () => {
  globalThis.engineTestRequests.length = 0;
  globalThis.engineTestResult = false;
  assert.equal(await goBackAcrossEngines("a"), false);
  globalThis.engineTestResult = true;
  assert.equal(await goBackAcrossEngines("b"), true);
  assert.deepEqual(globalThis.engineTestRequests, [["a", "back"], ["b", "back"]]);
});

test("engine requests forward destinations and options to native ownership", async () => {
  globalThis.engineTestRequests.length = 0;
  globalThis.engineTestResult = true;
  assert.equal(await openPageIn("a", "webkit", { rule: null, checkWork: false }), true);
  persistEngine("b", "chromium");
  assert.equal(await togglePageEngine("c"), true);
  assert.deepEqual(globalThis.engineTestRequests, [
    ["a", "open", { engine: "webkit", rule: null, checkWork: false }],
    ["b", "persist", { engine: "chromium" }],
    ["c", "toggle"],
  ]);
});
