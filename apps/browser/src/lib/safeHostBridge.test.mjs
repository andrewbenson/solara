import assert from "node:assert/strict";
import { test } from "node:test";
import { declaration, runNative, source } from "../test-native/safe-host/run.mjs";

function bridge(name) {
  const header = source("packages/solaracore/ios/SolaraCoreEngineBridge.h");
  const abi = source("engine/chromium/src/chrome/browser/solara/public/ac_engine.h");
  const implementation = source("packages/solaracore/ios/SolaraCoreEngineBridge.mm")
    .replace('#import "SolaraCoreEngineBridge.h"', "")
    .replace('#import "SolaraCoreBookmarkURL.h"', "static NSString *SolaraCanonicalBookmarkURL(NSString *url, NSError **error) { return nil; }")
    .replace('#import "SolaraCoreInternal.h"', "")
    .replace('#include "../../../engine/chromium/src/chrome/browser/solara/public/ac_engine.h"', "");
  return runNative("Engine.mm", `${abi}\n${header}\n${implementation}`, [name]);
}

function assertRefusalAndDispatch(results, name) {
  assert.equal(results.length, 4);
  for (const result of results) {
    assert.equal(result.callbacks, 1);
    if (result.safe) {
      assert.deepEqual(result.reply, { error: "disabled in safe mode" });
      assert.equal(result.symbolCalls, 0);
      assert.deepEqual(result.symbols, []);
      assert.equal(result.profileCalls, 0);
      assert.equal(result.engineCalls, 0);
      assert.deepEqual(result.received, []);
    } else {
      assert.deepEqual(result.reply, { ok: true });
      assert.equal(result.symbolCalls, 1);
      assert.deepEqual(result.symbols, [name]);
      assert.equal(result.profileCalls, 1);
      assert.equal(result.engineCalls, 1);
      assert.deepEqual(result.received, [{ profile: "fixture-profile", args: '{"marker":42}' }]);
    }
    if (result.secret) assert.equal(result.wiped, true);
  }
}

test("extension sync bridge refuses state and apply with errors before engine lookup in safe mode", () => {
  for (const name of ["ac_extensions_sync_state", "ac_extensions_sync_apply"]) assertRefusalAndDispatch(bridge(name), name);
});

test("favicons_set bridge refuses with an error before engine lookup in safe mode", () => {
  assertRefusalAndDispatch(bridge("ac_favicons_set"), "ac_favicons_set");
});

test("SyncModule refuses vault access with a reason before reading keys or reaching disk in safe mode", () => {
  const method = declaration(source("packages/sync/ios/SyncModule.swift"), "private func vault(");
  const results = runNative("Sync.swift", method, [], true);
  assert.deepEqual(results, [
    { safe: true, error: "safe mode", keyReads: 0, vaultCalls: 0, marker: "preserved" },
    { safe: false, error: "", keyReads: 1, vaultCalls: 1, marker: "vault opened" },
  ]);
});

test("SolaraCoreFavicons returns an in-memory image without creating profile files in safe mode", () => {
  const text = source("packages/solaracore/ios/SolaraCoreFavicons.mm");
  const production = ["NSString *FaviconDirectory(", "bool SafeName(", "NSDictionary *Store("].map((signature) => declaration(text, signature)).join("\n");
  const [safe, normal] = runNative("Favicon.mm", production);
  assert.equal(safe.safe, true);
  assert.deepEqual(safe.files, []);
  assert.equal(safe.stored, "");
  assert.equal(safe.result.uri, "data:image/png;base64,cG5nIGZpeHR1cmU=");
  assert.equal(safe.result.width, 32);
  assert.equal(safe.result.height, 32);
  assert.equal(normal.safe, false);
  assert.deepEqual(normal.files.sort(), ["Solara Favicons", "Solara Favicons/icon.png"]);
  assert.equal(normal.stored, "png fixture");
  assert.match(normal.result.uri, /^file:.*icon\.png\?v=/);
});
