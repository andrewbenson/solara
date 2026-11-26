import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";

const require = createRequire(import.meta.url);
const ts = require("typescript");

function compile(file, modules) {
  const exports = {};
  const { outputText } = ts.transpileModule(readFileSync(new URL(file, import.meta.url), "utf8"), {
    fileName: file,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX },
  });
  new Function("require", "exports", outputText)((name) => modules[name] ?? {}, exports);
  return exports;
}

test("an extension side panel menu action keeps its logical and engine profile across the JS bridge", () => {
  const calls = [];
  const state = { windows: { w: { profileId: "personal" } } };
  let engine = "shared";
  const handlers = compile("../settings/native/extensions.ts", {
    "../../../store/browser": { useBrowser: { getState: () => state } },
    "../../extensions/state": {
      extensionProfile: () => engine,
      toggleSidePanel: (...args) => calls.push(args),
    },
  }).extensionsHandlers;
  const select = () => handlers["extensions.togglePanel"]("w", "fixture", "work", "shared");
  select();
  state.windows.w.profileId = "work";
  engine = "different";
  select();
  assert.deepEqual(calls, []);
  engine = "shared";
  select();
  assert.deepEqual(calls, [["w", "fixture"]]);
});
