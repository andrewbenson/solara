import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";

const require = createRequire(import.meta.url);
const react = require("react");
const ts = require("typescript");

function fixture() {
  const listeners = new Set();
  const cleaned = [];
  let candidates = 12;
  let sweeps = 0;
  let timers = 0;
  let state = {
    settings: { suggestTabCleanUp: true, cleanUpInactiveTabsAfterHours: null },
    windows: { a: { tabIds: [], profileId: "p" }, b: { tabIds: [], profileId: "p" } },
    updateSettings(patch) {
      state = { ...state, settings: { ...state.settings, ...patch } };
      for (const listener of [...listeners]) listener();
    },
    cleanUpTabs(id) { cleaned.push(id); },
  };
  const useBrowser = (select) => react.useSyncExternalStore((listener) => { listeners.add(listener); return () => listeners.delete(listener); }, () => select(state));
  useBrowser.getState = () => state;
  const modules = {
    react,
    "../../store/browser": { useBrowser },
    "../../store/model": { activeTabId: () => null },
    "../../store/organize": { cleanUpCandidates: () => { sweeps++; return Array(candidates); } },
    "../../lib/slowTimers": { everySlowly: () => { timers++; return () => { timers--; }; } },
  };
  const exports = {};
  const source = readFileSync(new URL("./cleanUpUpsell.ts", import.meta.url), "utf8");
  const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  new Function("require", "exports", code)((name) => modules[name], exports);
  const renderer = {};
  const native = {
    UIManager: { createView() {}, setChildren() {}, manageChildren() {}, updateView() {} },
    ReactNativeViewConfigRegistry: { get: () => ({ uiViewClassName: "RCTView", validAttributes: {} }) },
    RCTEventEmitter: { register() {} },
    ReactFiberErrorDialog: { showErrorDialog: () => false },
    deepFreezeAndThrowOnMutationInDev: (value) => value,
    createPublicInstance: (tag) => ({ tag }),
  };
  const rendererSource = readFileSync(require.resolve("react-native/Libraries/Renderer/implementations/ReactNativeRenderer-dev"), "utf8");
  new Function("require", "exports", "__DEV__", rendererSource)((name) => {
    if (name.endsWith("ReactNativePrivateInitializeCore")) return {};
    if (name.endsWith("ReactNativePrivateInterface")) return native;
    return require(name);
  }, renderer, true);
  const counts = {};
  const errors = [];
  function Probe({ id }) { counts[id] = exports.useCleanUpUpsellCount(id, true); return null; }
  const settle = () => new Promise((resolve) => setImmediate(resolve));
  return {
    ...exports, counts, cleaned, settle,
    update: (patch) => state.updateSettings(patch),
    settings: () => state.settings,
    sweeps: () => sweeps,
    timers: () => timers,
    mount: (count = 12) => {
      candidates = count;
      renderer.render(react.createElement(react.Fragment, null, ...["a", "b"].map((id) => react.createElement(Probe, { id, key: id }))), 1, null, { onUncaughtError: (error) => errors.push(error) });
    },
    close: () => { renderer.unmountComponentAtNode(1); assert.deepEqual(errors, []); },
  };
}

test("the preference suppresses suggestions and candidate polling in every window", async () => {
  const f = fixture();
  f.update({ suggestTabCleanUp: false });
  f.mount();
  try {
    await f.settle();
    assert.deepEqual(f.counts, { a: 0, b: 0 });
    assert.equal(f.sweeps(), 0);
    f.update({ suggestTabCleanUp: true });
    await f.settle();
    assert.deepEqual(f.counts, { a: 12, b: 12 });
    f.cleanUpUpsellChoice("a", "dontAskAgain");
    await f.settle();
    assert.equal(f.settings().suggestTabCleanUp, false);
    assert.deepEqual(f.counts, { a: 0, b: 0 });
    assert.deepEqual(f.cleaned, []);
    assert.equal(f.timers(), 0);
    f.update({ suggestTabCleanUp: true });
    await f.settle();
    assert.deepEqual(f.counts, { a: 12, b: 12 });
  } finally { f.close(); }
});

test("Not Now stays session-only and daily cleanup still suppresses suggestions", async () => {
  const f = fixture();
  f.mount();
  try {
    await f.settle();
    f.update({ cleanUpInactiveTabsAfterHours: 24 });
    await f.settle();
    assert.deepEqual(f.counts, { a: 0, b: 0 });
    f.update({ cleanUpInactiveTabsAfterHours: null });
    await f.settle();
    assert.deepEqual(f.counts, { a: 12, b: 12 });
    f.cleanUpUpsellChoice("a", "dismiss");
    await f.settle();
    assert.equal(f.settings().suggestTabCleanUp, true);
    assert.deepEqual(f.counts, { a: 0, b: 0 });
  } finally { f.close(); }
});

test("fewer than ten candidates never produces a suggestion", async () => {
  const f = fixture();
  f.mount(9);
  try { await f.settle(); assert.deepEqual(f.counts, { a: 0, b: 0 }); }
  finally { f.close(); }
});
