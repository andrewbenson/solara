import assert from "node:assert/strict";
import { test } from "node:test";
import { declaration, runNative, source } from "../test-native/safe-host/run.mjs";

function downloadBridge() {
  const bridge = source("packages/solaracore/ios/SolaraCoreEngineBridge.mm")
    .replace('#import "SolaraCoreEngineBridge.h"', "")
    .replace('#import "SolaraCoreBookmarkURL.h"', "static NSString *SolaraCanonicalBookmarkURL(NSString *url, NSError **error) { return nil; }")
    .replace('#import "SolaraCoreInternal.h"', "")
    .replace('#include "../../../engine/chromium/src/chrome/browser/solara/public/ac_engine.h"', "");
  const services = source("packages/solaracore/ios/SolaraCoreServices.mm");
  const helpers = ["NSDictionary *Parse(", "NSString *JSON(NSDictionary *"]
    .map((signature) => declaration(services, signature)).join("\n");
  const methods = ["+ (void)call:(NSString *)name profile:(NSString *)profile args:(NSDictionary *)args completion:", "+ (void)downloadCommand:"]
    .map((signature) => declaration(services, signature)).join("\n");
  return runNative("Downloads.mm", [
    source("engine/chromium/src/chrome/browser/solara/public/ac_engine.h"),
    source("packages/solaracore/ios/SolaraCoreEngineBridge.h"), bridge, helpers,
    "@implementation SolaraCoreServices", methods, "@end",
  ].join("\n"));
}

test("explicit engine download remove and cancel reach the engine in safe mode", () => {
  const results = downloadBridge();
  assert.equal(results.length, 4);
  for (const result of results) {
    assert.equal(result.engineCalls, 1);
    assert.equal(result.profileCalls, 1);
    assert.deepEqual(result.symbols, [`ac_downloads_${result.command}`]);
    assert.deepEqual(result.received, [{ profile: "fixture-profile", args: { id: "download-42" } }]);
  }
  assert.deepEqual(results.map(({ safe, command }) => [safe, command]), [[true, "remove"], [true, "cancel"], [false, "remove"], [false, "cancel"]]);
});

test("explicit Move to Trash reaches trashItem in safe mode and reports its result", () => {
  const production = declaration(source("packages/shell/ios/System.swift"), 'AsyncFunction("moveToTrash")');
  const results = runNative("DownloadTrash.swift", production, [], true);
  assert.equal(results.length, 6);
  for (const result of results) {
    assert.equal(result.result, result.outcome === "success");
    assert.deepEqual(result.trashed, result.outcome === "missing" ? [] : ["/fixture/download.txt"]);
  }
  assert.deepEqual(results.map(({ safe, outcome }) => [safe, outcome]), [
    [true, "success"], [true, "missing"], [true, "failure"],
    [false, "success"], [false, "missing"], [false, "failure"],
  ]);
});
