import assert from "node:assert/strict";
import { test } from "node:test";
import { declaration, runNative, source } from "../test-native/safe-host/run.mjs";

function nativeClears() {
  const bridge = source("packages/solaracore/ios/SolaraCoreEngineBridge.mm")
    .replace('#import "SolaraCoreEngineBridge.h"', "")
    .replace('#import "SolaraCoreBookmarkURL.h"', "static NSString *SolaraCanonicalBookmarkURL(NSString *url, NSError **error) { return nil; }")
    .replace('#import "SolaraCoreInternal.h"', "")
    .replace('#include "../../../engine/chromium/src/chrome/browser/solara/public/ac_engine.h"', "");
  const services = source("packages/solaracore/ios/SolaraCoreServices.mm");
  const helpers = ["NSDictionary *Parse(", "NSString *JSON(NSDictionary *"]
    .map((signature) => declaration(services, signature)).join("\n");
  const methods = [
    "+ (void)call:(NSString *)name profile:(NSString *)profile args:(NSDictionary *)args completion:",
    "+ (void)clearBrowsingData:", "+ (void)clearSiteData:",
  ].map((signature) => declaration(services, signature)).join("\n");
  return runNative("ClearData.mm", [
    source("engine/chromium/src/chrome/browser/solara/public/ac_engine.h"),
    source("packages/solaracore/ios/SolaraCoreEngineBridge.h"), bridge, helpers,
    "@implementation SolaraCoreServices", methods, "@end",
  ].join("\n"));
}

function webKitClears() {
  const hub = source("packages/solaracore/ios/WebKitHub.swift");
  const methods = ["func clearBrowsingData(", "static func covers(", "func clearSiteData("]
    .map((signature) => declaration(hub, signature)).join("\n");
  return runNative("ClearData.swift", methods, [], true);
}

let nativeResults;
const native = () => nativeResults ??= nativeClears();
let webKitResults;
const webKit = () => webKitResults ??= webKitClears();

test("explicit browsing clear reaches the loaded engine profile in safe and normal modes", () => {
  const results = native().filter((row) => row.path === "browsing");
  assert.deepEqual(results.map(({ safe, history }) => [safe, history]), [[true, true], [true, false], [false, true], [false, false]]);
  for (const result of results) {
    assert.equal(result.callbacks, 1);
    assert.equal(result.profileCalls, 1);
    assert.equal(result.engineCalls, 1);
    assert.equal(result.pictureCalls, result.history ? 1 : 0);
    assert.deepEqual(result.received, [{ profile: "fixture-profile", types: result.history ? ["history", "siteData", "cache"] : ["cache"], since: 123 }]);
  }
});

test("explicit site clear crosses services and the real bridge in safe and normal modes", () => {
  const results = native().filter((row) => row.path === "site");
  assert.deepEqual(results.map(({ safe }) => safe), [true, false]);
  for (const result of results) {
    assert.equal(result.callbacks, 1);
    assert.equal(result.profileCalls, 1);
    assert.equal(result.engineCalls, 1);
    assert.deepEqual(result.symbols, ["ac_site_data_clear"]);
    assert.deepEqual(result.received, [{ profile: "fixture-profile", args: { origin: "https://example.test" } }]);
    assert.deepEqual(result.reply, { cookies: 2, storage: true });
  }
});

test("explicit generic browsing clear crosses the bridge in safe and normal modes", () => {
  const results = native().filter((row) => row.path === "bridge");
  assert.deepEqual(results.map(({ safe }) => safe), [true, false]);
  for (const result of results) {
    assert.equal(result.callbacks, 1);
    assert.equal(result.engineCalls, 1);
    assert.deepEqual(result.symbols, ["ac_browsing_data_clear"]);
    assert.deepEqual(result.received, [{ profile: "fixture-profile", args: { types: ["cache"] } }]);
  }
});

test("explicit WebKit browsing clear removes requested data and permissions in safe and normal modes", () => {
  const results = webKit().filter((row) => row.path === "browsing");
  assert.deepEqual(results.map(({ safe, types }) => [safe, types]), [
    [true, ["siteData"]], [true, ["cache"]], [true, ["siteData", "cache"]],
    [false, ["siteData"]], [false, ["cache"]], [false, ["siteData", "cache"]],
  ]);
  for (const result of results) {
    assert.equal(result.callbacks, 1);
    assert.equal(result.storeLookups, 1);
    assert.equal(result.removals.length, 1);
    assert.deepEqual(result.removals[0], { kinds: result.types.includes("siteData") ? (result.types.includes("cache") ? ["cookies", "disk", "fetch", "memory", "storage"] : ["cookies", "storage"]) : ["disk", "fetch", "memory"], since: 123 });
    assert.deepEqual(result.permissions, result.types.includes("siteData") ? ["other|permission"] : ["fixture|permission", "other|permission"]);
    assert.deepEqual(result.allowances, result.types.includes("siteData") ? ["other|allowance"] : ["fixture|allowance", "other|allowance"]);
  }
});

test("explicit WebKit site clear removes matching records and reports cookies in safe and normal modes", () => {
  const results = webKit().filter((row) => row.path === "site");
  assert.deepEqual(results.map(({ safe }) => safe), [true, false]);
  for (const result of results) {
    assert.equal(result.callbacks, 1);
    assert.equal(result.storeLookups, 1);
    assert.equal(result.fetches, 1);
    assert.equal(result.cookieReads, 1);
    assert.deepEqual(result.removals, [{ kinds: ["cookies", "disk", "fetch", "memory", "storage"], records: [".example.test", "example.test", "sub.example.test"] }]);
    assert.deepEqual(result.reply, { cookies: 3, storage: true });
  }
});
