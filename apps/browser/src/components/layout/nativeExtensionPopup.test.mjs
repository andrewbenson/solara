import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";

test("popup opened during listener registration keeps the toolbar shown", () => {
  const require = createRequire(import.meta.url);
  const ts = require("typescript");
  const source = readFileSync(new URL("../../../../../packages/settings/src/toolbar.tsx", import.meta.url), "utf8");
  const { outputText } = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX },
  });
  let windowId = null;
  let listener;
  let shown;
  let effect;
  const native = {
    extensionPopupWindow: () => windowId,
    addListener: (name, notify) => {
      assert.equal(name, "onExtensionPopupChanged");
      windowId = "w";
      listener = notify;
      return { remove: () => { listener = undefined; } };
    },
  };
  const modules = {
    react: {
      useState: (read) => [read(), (next) => { shown = next; }],
      useEffect: (run) => { effect = run; },
    },
    "expo-modules-core": { requireOptionalNativeModule: (name) => name === "SolaraToolbar" ? native : null },
  };
  const exports = {};
  new Function("require", "exports", outputText)((name) => modules[name], exports);
  assert.equal(exports.useNativeExtensionPopupShown("w"), false);
  const unmount = effect();
  assert.equal(shown, true);
  windowId = null;
  listener();
  assert.equal(shown, false);
  unmount();
  assert.equal(listener, undefined);
});
