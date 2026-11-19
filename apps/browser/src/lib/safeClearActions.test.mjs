import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { test } from "node:test";
import { declaration, runNative, source } from "../test-native/safe-host/run.mjs";

const ts = createRequire(import.meta.url)("typescript");

function compile(path, modules) {
  const exports = {};
  const { outputText } = ts.transpileModule(source(path), {
    fileName: path,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX },
  });
  new Function("require", "exports", outputText)((name) => modules[name] ?? {}, exports);
  return exports;
}

function fixture(mode) {
  const effects = [];
  const state = {
    history: { work: [{ url: "https://example.test", lastVisit: 42 }] },
    clearHistory(profile, since) { this.history[profile] = []; effects.push(["history", profile, since]); },
  };
  const nativeStore = { nativeSafeMode: () => mode !== null, nativeSafeModeAfterFailedLaunches: () => mode === "failedLaunches" };
  const modules = {
    "@solara/solaracore": {
      clearBrowsingData: async (...args) => { effects.push(["browsing", ...args]); },
      clearSiteData: async (...args) => { effects.push(["site", ...args]); return { cookies: 2, storage: true }; },
    },
    zustand: { create: () => () => ({}) },
    react: { memo: (value) => value },
    "react-native": { StyleSheet: { hairlineWidth: 1 } },
    "react/jsx-runtime": {},
    "../../store/browser": { useBrowser: { getState: () => state } },
    "../../../store/browser": { useBrowser: { getState: () => state } },
    "../../store/model": { engineProfile: (id) => id, isIncognitoProfile: (id) => id.startsWith("incognito:") },
    "../../lib/favicons": { pruneProfileFavicons: (id) => effects.push(["favicons", id]) },
    "../../../lib/favicons": { pruneProfileFavicons: (id) => effects.push(["favicons", id]) },
    "../../store/nativeStore": nativeStore,
    "../../../store/nativeStore": nativeStore,
    "../../store/safeLibraryEdits": { refuseSafeHistoryDeletion: () => false },
    "../../../store/safeLibraryEdits": { refuseSafeHistoryDeletion: () => false },
  };
  return { effects, state, modules, nativeStore };
}

for (const mode of ["option", "failedLaunches", null]) {
  test(`Clear Browsing Data dialog reaches history and engine effects in mode ${mode}`, async () => {
    const f = fixture(mode);
    const { clearDataFor } = compile("apps/browser/src/components/pages/ClearDataDialog.tsx", f.modules);
    await clearDataFor("work", "all", true, true);
    assert.deepEqual(f.state.history.work, []);
    assert.deepEqual(f.effects, [
      ["history", "work", undefined],
      ["favicons", "work"],
      ["browsing", "work", ["history", "siteData", "cache"], undefined],
    ]);
    f.effects.length = 0;
    const before = Date.now();
    await clearDataFor("work", "hour", false, true);
    assert.equal(f.effects.length, 1);
    assert.deepEqual(f.effects[0].slice(0, 3), ["browsing", "work", ["siteData", "cache"]]);
    assert.ok(f.effects[0][3] >= before - 3_600_000 && f.effects[0][3] <= Date.now() - 3_600_000);
  });

  test(`settings profiles and privacy clear handlers reach effects in mode ${mode}`, async () => {
    const f = fixture(mode);
    const { profilesHandlers } = compile("apps/browser/src/components/settings/native/profiles.ts", f.modules);
    const { privacyHandlers } = compile("apps/browser/src/components/settings/native/privacy.ts", f.modules);
    profilesHandlers["profiles.clearHistory"]("work", null);
    await profilesHandlers["profiles.clearBrowsingData"]("work", ["history", "siteData", "cache"], null);
    const result = await privacyHandlers["privacy.clearSiteData"]("work", "https://example.test");
    assert.deepEqual(f.state.history.work, []);
    assert.deepEqual(result, { cookies: 2, storage: true });
    assert.deepEqual(f.effects, [
      ["history", "work", undefined],
      ["browsing", "work", ["history", "siteData", "cache"], undefined],
      ["site", "work", "https://example.test"],
    ]);
  });

  test(`developer Clear Cookies and Refresh reaches site data effect in mode ${mode}`, async () => {
    const f = fixture(mode);
    const page = { clearSiteData: async () => { f.effects.push("clear"); }, reload: () => f.effects.push("reload") };
    f.modules["../../lib/webviews"] = { webviews: new Map([["tab", page]]) };
    f.modules["../../lib/livePage"] = { withLivePage: async (id, run) => run(page) };
    const { runDeveloperReloadChoice } = compile("apps/browser/src/components/site/DeveloperButtons.tsx", f.modules);
    await runDeveloperReloadChoice("tab", "clearCookies");
    assert.deepEqual(f.effects, ["clear", "reload"]);
  });

  test(`native site panel bridge reaches its selected page clear and reload effects in mode ${mode}`, async () => {
    const f = fixture(mode);
    const effects = [];
    const page = { clearSiteData: async () => { effects.push("clear"); return { cookies: 2, storage: true }; }, reload: () => effects.push("reload") };
    let handlers;
    f.modules["../../lib/webviews"] = { webviews: new Map([["tab", page]]) };
    f.modules["../settings/nativeSettings"] = { addNativeSettingsHandlers: (value) => { handlers = value; } };
    compile("apps/browser/src/components/site/NativeSiteControls.tsx", f.modules);
    assert.deepEqual(await handlers["site.page"]("tab", "clearSiteData", []), { cookies: 2, storage: true });
    handlers["site.page"]("tab", "reload", []);
    assert.deepEqual(effects, ["clear", "reload"]);
    assert.equal(handlers["site.page"]("gone", "clearSiteData", []), undefined);
    assert.deepEqual(effects, ["clear", "reload"]);
  });
}


test("native settings models reach clear services in safe and normal mode", () => {
  const profiles = source("native/SolaraKit/Sources/SolaraUI/Settings/Panes/ProfilesPane.swift");
  const privacy = source("native/SolaraKit/Sources/SolaraUI/Settings/Panes/PrivacySheets.swift");
  const production = [
    declaration(profiles, "public enum BrowsingDataKind:"),
    declaration(source("native/SolaraKit/Sources/SolaraUI/Settings/Panes/ProfileSheets.swift"), "enum ClearDataRange:"),
    declaration(source("native/SolaraKit/Sources/SolaraUI/Settings/Panes/PrivacyPane.swift"), "public struct ClearSiteDataResult:"),
    "final class Profiles { let services: Services; let store = Store(); let safeMode: Bool; init(services: Services, safeMode: Bool) { self.services = services; self.safeMode = safeMode }",
    declaration(profiles, "func clearData(profileId:"),
    "}",
    'final class Privacy { let services: Services; let profile = "work"; let origin = "https://example.test"; var status = ""; init(services: Services) { self.services = services }',
    declaration(privacy, "static func clearedText("),
    declaration(privacy, "func clearData() async"),
    "}",
  ].join("\n");
  const results = runNative("ClearActions.swift", production, [], true);
  assert.equal(results.length, 2);
  for (const result of results) {
    assert.deepEqual(result.calls, [
      ["history", "work", "all"],
      ["favicons", "work"],
      ["browsing", "work", "history", "siteData", "cache"],
      ["browsing", "", "siteData", "cache"],
      ["site", "work", "https://example.test"],
    ]);
    assert.equal(result.status, "Cleared 2 cookies and site data.");
  }
  assert.deepEqual(results.map((result) => result.safe), [true, false]);
});

test("native settings clear adapter takes the guarded JS handler in safe mode and clears the engines directly otherwise", () => {
  const adapter = source("packages/settings/ios/Adapters/ProfilesAdapter.swift");
  const production = [
    declaration(source("native/SolaraKit/Sources/SolaraUI/Settings/Panes/ProfilesPane.swift"), "public enum BrowsingDataKind:"),
    "final class Adapter {",
    declaration(adapter, "func clearBrowsingData(engineProfile:"),
    declaration(adapter, "static func millis("),
    "}",
  ].join("\n");
  const results = runNative("LibraryClear.swift", production, [], true);
  assert.deepEqual(results, [
    { safe: true, calls: [["profiles.clearBrowsingData", "engine-work", ["history", "siteData"], 123000]], effects: 0 },
    {
      safe: false,
      calls: [
        ["engine", "engine-work", ["history", "siteData"], 123000],
        ["webKit", "engine-work", ["history", "siteData"], 123000],
      ],
      effects: 2,
    },
  ]);
});

for (const path of ["apps/browser/src/components/pages/ClearDataDialog.tsx", "apps/browser/src/components/settings/native/profiles.ts"]) {
  test(`${path} refuses a legacy history clear before state, favicon and engine effects`, async () => {
    for (const refused of [true, false]) {
      const f = fixture("option");
      const refusals = [];
      const guards = { refuseSafeHistoryDeletion: (...args) => { refusals.push(args); return refused; } };
      f.modules["../../store/safeLibraryEdits"] = guards;
      f.modules["../../../store/safeLibraryEdits"] = guards;
      const api = compile(path, f.modules);
      const clear = api.clearDataFor ? () => api.clearDataFor("work", "all", true, true)
        : async () => api.profilesHandlers["profiles.clearBrowsingData"]("work", ["history", "siteData", "cache"], null);
      if (refused) {
        await assert.rejects(clear, /legacy file has migrated/);
        assert.deepEqual(f.effects, []);
        assert.equal(f.state.history.work.length, 1);
      } else {
        await clear();
        assert.equal(f.effects.some((row) => row[0] === "browsing"), true);
      }
      assert.deepEqual(refusals, [["work", undefined, undefined]]);
    }
  });
}
