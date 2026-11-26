import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";
import vm from "node:vm";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const compile = (name) => ts.transpileModule(readFileSync(new URL(name, import.meta.url), "utf8"), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
}).outputText;

function harness() {
  const listeners = new Set();
  const available = new Set();
  const h = { renders: 0, result: null, release: null };
  const browser = Object.assign((select) => select({}), { subscribe() {} });
  const mocks = {
    react: { useSyncExternalStore(subscribe, snapshot) {
      if (!h.release) h.release = subscribe(() => h.render());
      return snapshot();
    } },
    "@solara/settings": {
      nativeEngineBackAvailable: (id) => available.has(id),
      onEngineBackChanged: (notify) => { listeners.add(notify); return { remove: () => listeners.delete(notify) }; },
    },
    "../../store/browser": { useBrowser: browser },
    "../../store/openers": { backSelection: () => ({ pageId: "replacement", opener: undefined, canGoBack: false, canGoForward: false, hasLive: true }) },
    "./pageState": { usePage: (id, select) => select({ newTabShown: null, backToNewTab: false, historyKnown: true }) },
    "../settings/nativeSettings": { addNativeSettingsHandlers() {} },
    "zustand/react/shallow": { useShallow: (select) => select },
    zustand: { create: () => () => ({ menu: null }) },
  };
  const back = { exports: {} };
  new vm.Script(compile("./backAction.ts")).runInNewContext({ exports: back.exports, module: back });
  mocks["./backAction"] = back.exports;
  const module = { exports: {} };
  new vm.Script(compile("./history.ts")).runInNewContext({ exports: module.exports, module, require: (id) => mocks[id] ?? {} });
  h.render = () => { h.renders++; h.result = module.exports.useBackState("tab"); };
  h.register = (id) => { available.add(id); for (const notify of listeners) notify(); };
  h.retire = (id) => { available.delete(id); for (const notify of listeners) notify(); };
  return h;
}

test("replacement registration notifies Back without a browser or page state change", () => {
  const h = harness();
  h.render();
  assert.equal(h.result.action, "none");
  h.register("replacement");
  assert.equal(h.renders, 2);
  assert.equal(h.result.action, "page");
  assert.equal(h.result.engineBack, true);
  h.retire("replacement");
  assert.equal(h.result.action, "none");
  assert.equal(h.result.engineBack, false);
  h.release();
  h.register("replacement");
  assert.equal(h.renders, 3);
});
