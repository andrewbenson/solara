import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";
import { runInNewContext } from "node:vm";

const ts = createRequire(import.meta.url)("typescript");

function windowsModule() {
  const calls = [];
  const imports = {
    "@solara/shell": { openWindow: async (id, options) => { calls.push(["openWindow", id, options.kind]); } },
    "@solara/settings": {
      navigateNativeSettings: async () => {},
      setNativePreferredImportSource: (id) => calls.push(["setPreferred", id]),
    },
  };
  const module = { exports: {} };
  const source = readFileSync(new URL("./windows.ts", import.meta.url), "utf8");
  runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, {
    exports: module.exports,
    require: (name) => { if (name in imports) return imports[name]; throw new Error(`Unexpected import: ${name}`); },
  });
  return { windows: module.exports, calls };
}

test("openImport hands the preferred source to Swift before it opens the window", () => {
  const { windows, calls } = windowsModule();
  windows.openImport("chrome");
  assert.deepEqual(calls, [["setPreferred", "chrome"], ["openWindow", "import", "import"]]);
  assert.equal(windows.takePreferredImportSource(), "chrome");
  assert.equal(windows.takePreferredImportSource(), null);
});

test("openImport with no source clears the preferred source on both sides", () => {
  const { windows, calls } = windowsModule();
  windows.openImport("arc");
  windows.openImport();
  assert.deepEqual(calls.filter(([name]) => name === "setPreferred"), [["setPreferred", "arc"], ["setPreferred", null]]);
  assert.equal(windows.takePreferredImportSource(), null);
});
