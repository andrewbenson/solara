import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const adapter = readFileSync(new URL("../../../../../../packages/settings/ios/Adapters/ImportAdapter.swift", import.meta.url), "utf8");

test("until D1 moves runs to Swift, the import window's cancel and dispose still go through JS", () => {
  assert.match(adapter, /func cancel\(\) \{ SettingsJS\.shared\.fire\("import\.cancel"\) \}/);
  assert.match(adapter, /func dispose\(\) \{ SettingsJS\.shared\.fire\("import\.dispose"\) \}/);
  assert.doesNotMatch(adapter, /session\.forget\(/);
  assert.doesNotMatch(adapter, /forgetSession\(/);
});
