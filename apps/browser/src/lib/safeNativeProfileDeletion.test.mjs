import assert from "node:assert/strict";
import { declaration, runNative, source } from "../test-native/safe-host/run.mjs";
import { test } from "node:test";

const sent = [];
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: true, scope: "everything", safeMode: "option" }),
    dispatch: (json) => { sent.push(...[JSON.parse(json)].flat()); return JSON.stringify({ rev: 0 }); },
    addListener: () => ({ remove() {} }),
  },
};
const { shellNativeModules } = await import("../test-native/shell.ts");
const notices = [];
shellNativeModules.SolaraShell.confirm = async (options) => { notices.push(options); return { confirmed: false, suppressed: false }; };
const { useBrowser } = await import("../store/browser.ts");
const { startNativeStore, attachReplica } = await import("../store/nativeStore.ts");

test("native workspace action wrapping keeps the safe profile-deletion explanation", () => {
  startNativeStore();
  attachReplica(useBrowser);
  useBrowser.getState().deleteProfile("default");
  assert.equal(notices.length, 1);
  assert.equal(notices[0].title, "Safe Mode");
  assert.match(notices[0].message, /can't be deleted in safe mode/);
  assert.equal(sent.some((c) => c.name === "deleteProfile"), false);
  assert.ok(useBrowser.getState().profiles.default);
  assert.deepEqual(useBrowser.getState().orphanedProfileData, []);
});

test("SolaraCoreHost refuses loaded and unloaded profile deletion with a reason before engine or disk access", () => {
  const host = source("packages/solaracore/ios/SolaraCoreHost.mm");
  const helpers = ["NSMutableSet<NSString *> *ScheduledProfileDeletions()", "NSDictionary *DeletionLocation(NSString *profile)"].map((signature) => declaration(host, signature));
  const method = declaration(host, "+ (void)deleteProfileData:");
  const results = runNative("Profile.mm", [...helpers, "@implementation SolaraCoreHost", method, "@end"].join("\n"));
  assert.equal(results.length, 6);
  for (const result of results.slice(4)) {
    assert.equal(result.callbacks, 1);
    assert.deepEqual(result.remaining, ["live profile filesystem identity"]);
    assert.equal(result.sentinelKept, true);
  }
  for (const result of results.slice(0, 4)) {
    assert.equal(result.callbacks, 1);
    if (result.safe) {
      assert.deepEqual(result.remaining, ["safe mode"]);
      assert.equal(result.engineLookups, 0);
      assert.equal(result.profileLookups, 0);
      assert.equal(result.engineCalls, 0);
      assert.equal(result.deletedProfiles, 0);
      assert.equal(result.directoryExists, true);
      assert.equal(result.bookmarksKept, true);
      assert.equal(result.historyKept, true);
    } else {
      assert.deepEqual(result.remaining, result.loaded ? ["Chromium deletion pending restart"] : []);
      assert.equal(result.engineLookups, 1);
      assert.equal(result.profileLookups, 2);
      assert.equal(result.fenceCalls, 1);
      assert.equal(result.engineCalls, result.loaded ? 1 : 0);
      assert.equal(result.deletedProfiles, result.loaded ? 1 : 0);
      assert.equal(result.directoryExists, result.loaded);
      assert.equal(result.bookmarksKept, result.loaded);
      assert.equal(result.historyKept, result.loaded);
    }
  }
});

test("SolaraCoreProfileData refuses default-profile deletion with a reason before calling services", () => {
  const results = runNative("Profile.swift", [source("packages/solaracore/ios/ChromiumProfileData.swift"), declaration(source("packages/solaracore/ios/SolaraCoreProfileData.swift"), "enum SolaraCoreProfileData")].join("\n"), [], true);
  assert.deepEqual(results[0], { safe: true, remaining: ["safe mode"], callbacks: 1, calls: [] });
  assert.equal(results[1].safe, false);
  assert.deepEqual(results[1].remaining, []);
  assert.equal(results[1].callbacks, 1);
  assert.deepEqual(results[1].calls, [
    "clearBrowsingData", "ac_browsing_data_clear", "listPasswords", "listPasswords", "neverSaveOrigins", "neverSaveOrigins",
    "addresses", "addresses", "cards", "cards", "listExtensions", "listExtensions", "siteSettingsOrigins", "siteSettingsOrigins", "zoomLevels", "zoomLevels",
  ]);
});

test("WebKit deletion preserves exact live identities beside Unicode and case aliases", () => {
  const webkit = source("packages/solaracore/ios/WebKitHub.swift");
  const fields = ["persistentStores", "deletedProfileStores", "resumeHosts", "rememberedPermissions", "zoomByHost", "externalAllowances"].map((name) => {
    const line = webkit.split("\n").find((line) => line.includes(`private var ${name}:`));
    assert.ok(line, name);
    return line.replace("ExternalGrant", "Bool");
  });
  const hubMethods = ["static func isPrivate(", "static func privateSession(", "static func storeIdentifier(", "static func establishedProfileDirectory(", "func dataStore(for", "func resumeHost(for", "func deleteProfileData("].map((signature) => declaration(webkit.replace("= { true }, completion:", "= alwaysAllowDeletion, completion:"), signature));
  const program = [
    source("packages/solaracore/ios/ChromiumProfileData.swift"), "final class WebKitHub {", ...fields, "let downloads = WebKitDownloads()", "static let profileDataRemovalDeadline: TimeInterval = 0.5", ...hubMethods, "}",
    "final class WebKitDownloads { var items: [String: Item] = [:]", declaration(webkit, "func cancelAll(profile:"), "}",
  ].join("\n");
  const results = runNative("WebKitProfile.swift", program, [], true);
  assert.equal(results.length, 12);
  for (const result of results.slice(10)) {
    assert.equal(result.unknownLayoutRefused, true);
    assert.equal(result.storeKept, true);
    assert.equal(result.dataKept, true);
    assert.equal(result.removalNotCalled, true);
  }
  for (const result of results.slice(8, 10)) {
    assert.equal(result.refused, true);
    assert.equal(result.storeKept, true);
    assert.equal(result.initialClearRefused, true);
  }
  for (const result of results.slice(0, 8)) {
    assert.equal(result.completed, true, JSON.stringify(result));
    assert.equal(result.liveKept, true, JSON.stringify(result));
    assert.equal(result.deleted, true, JSON.stringify(result));
    assert.equal(result.downloadsExact, true, JSON.stringify(result));
    assert.equal(result.metadataExact, true, JSON.stringify(result));
  }
});

test("filesystem identity refuses case aliases and cross-engine live directories", () => {
  const results = runNative("DirectoryIdentity.swift", source("packages/solaracore/ios/ChromiumProfileData.swift"), [], true);
  assert.equal(results.length, 7);
  for (const result of results) {
    for (const [name, passed] of Object.entries(result)) assert.equal(passed, true, name);
  }
});
