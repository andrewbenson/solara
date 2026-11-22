import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const adapter = readFileSync(new URL("../../../../../../packages/settings/ios/Adapters/ImportAdapter.swift", import.meta.url), "utf8");

test("the import window's cancel and dispose reach the Swift run and still fire the JS path", () => {
  assert.match(adapter, /func cancel\(\) \{\n    guard direct else \{ return scriptCancel\(\) \}\n    ImportRuns\.shared\.cancel\(engine: ImportRunEngine\.shared, script: self\)\n  \}/);
  assert.match(adapter, /func dispose\(\) \{\n    guard direct else \{ return scriptDispose\(\) \}\n    ImportRuns\.shared\.dispose\(engine: ImportRunEngine\.shared, script: self\)\n  \}/);
  assert.match(adapter, /func scriptCancel\(\) \{ SettingsJS\.shared\.fire\("import\.cancel"\) \}/);
  assert.match(adapter, /func scriptDispose\(\) \{ SettingsJS\.shared\.fire\("import\.dispose"\) \}/);
  assert.doesNotMatch(adapter, /session\.forget\(/);
  assert.doesNotMatch(adapter, /forgetSession\(/);
});
