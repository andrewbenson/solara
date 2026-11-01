import assert from "node:assert/strict";
import { test } from "node:test";
import { declaration, runNative, source } from "../test-native/safe-host/run.mjs";

let results;
function documents() {
  if (results) return results;
  const module = source("packages/shell/ios/ShellModule.swift");
  const store = declaration(module, "public enum DocumentStore {")
    .replace(declaration(module, "public static var safeMode: Bool"), "public static var safeMode = false");
  results = runNative("Documents.swift", [source("packages/shell/ios/Core/SafeLaunchDocuments.swift"),
    source("packages/shell/ios/Core/DocumentListing.swift"), source("packages/shell/ios/Core/DurableDocument.swift"),
    source("packages/shell/ios/Core/DocumentWriteStore.swift"), store].join("\n"), [], true);
  return results;
}

test("safe-mode Live and calendar save reports success only after live.json reaches the next normal launch", () => {
  for (const row of documents().filter(({ name }) => ["live.json", "onboarding.json", "release-notes.json", "solara-cli.json"].includes(name))) {
    assert.equal(row.failure, "");
    assert.equal(row.threw, false);
    assert.equal(row.callbacks, 1);
    assert.equal(row.flushed, true);
    assert.equal(row.saved, `changed ${row.name}`);
    assert.equal(row.nextLaunch, `changed ${row.name}`);
  }
});

test("safe-mode automatic document writes fail explicitly and preserve the file; normal writes and removals run", () => {
  for (const row of documents().filter(({ name }) => !["live.json", "onboarding.json", "release-notes.json", "solara-cli.json"].includes(name))) {
    if (row.safe) {
      assert.match(row.failure, /safe mode/i);
      assert.equal(row.threw, true);
      assert.equal(row.callbacks, 0);
      assert.equal(row.saved, `existing ${row.name}`);
      assert.equal(row.nextLaunch, `existing ${row.name}`);
      assert.equal(row.removalRefused, true);
      assert.equal(row.existsAfterRemoval, true);
    } else {
      assert.equal(row.failure, "");
      assert.equal(row.callbacks, 1);
      assert.equal(row.saved, `changed ${row.name}`);
      assert.equal(row.nextLaunch, `changed ${row.name}`);
      assert.equal(row.removalRefused, false);
      assert.equal(row.existsAfterRemoval, false);
    }
  }
});
