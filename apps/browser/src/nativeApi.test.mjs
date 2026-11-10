import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";
import { runInNewContext } from "node:vm";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const { transpileModule, ModuleKind, JsxEmit } = createRequire(new URL("../package.json", import.meta.url))("typescript");
const compile = (source) => transpileModule(source, { compilerOptions: { module: ModuleKind.CommonJS, jsx: JsxEmit.ReactJSX } }).outputText;
const jsVersion = () => Number(read("./nativeApi.tsx").match(/export const NATIVE_API_VERSION = (\d+);/)?.[1]);
const nativeVersion = () => Number(read("../../../packages/shell/ios/AppModule.swift").match(/Constant\("apiVersion"\) \{ \(\) -> Int in (\d+) \}/)?.[1]);

function boot(bundleVersion, builtVersion) {
  const events = [];
  const api = { exports: {} };
  const shell = { openWindow: async (id) => events.push(id) };
  runInNewContext(compile(read("./nativeApi.tsx").replace(/NATIVE_API_VERSION = \d+/, `NATIVE_API_VERSION = ${bundleVersion}`)), {
    exports: api.exports,
    __DEV__: false,
    console: { error: () => {} },
    require: (name) => {
      if (name === "expo-modules-core") return { requireOptionalNativeModule: () => ({ apiVersion: builtVersion }), requireNativeModule: () => shell };
      if (name === "react-native") return { AppRegistry: { registerComponent: (name) => events.push(`registered:${name}`) } };
      if (name === "react/jsx-runtime") return {};
      throw new Error(`Unexpected API import: ${name}`);
    },
  });
  runInNewContext(compile(read("../index.js")), {
    exports: {},
    require: (name) => {
      if (name === "./src/lib/perfProbe") return {};
      if (name === "react-native") return { LogBox: { ignoreLogs() {}, ignoreAllLogs() {} } };
      if (name === "./src/nativeApi") return api.exports;
      if (name === "./src/main") {
        events.push("main", "legacy-js-cleanup");
        return {};
      }
      throw new Error(`Unexpected entry import: ${name}`);
    },
  });
  return { events, skew: api.exports.nativeApiSkew };
}

test("the JS bundle and the native build declare the same API version", () => {
  assert.ok(jsVersion() && nativeVersion(), "both declarations found");
  assert.equal(jsVersion(), nativeVersion());
});

test("legacy bundles and native builds are refused before main can start JS cleanup", () => {
  for (const legacyVersion of new Set([...Array.from({ length: 34 }, (_, i) => i), jsVersion() - 1])) {
    for (const [bundleVersion, builtVersion] of [[legacyVersion, nativeVersion()], [jsVersion(), legacyVersion]]) {
      const result = boot(bundleVersion, builtVersion);
      assert.match(result.skew, /Native API skew/);
      assert.deepEqual(result.events, ["registered:main", "native-api-skew"]);
    }
  }
});

test("the native bookmark projection feed requires the upgraded native bridge", () => {
  assert.equal(jsVersion(), 39);
  assert.equal(nativeVersion(), 39);
  assert.match(boot(jsVersion(), 38).skew, /Native API skew/);
  assert.deepEqual(boot(39, 39).events, ["main", "legacy-js-cleanup"]);
});

test("tab resource calls retain the API 38 historical gate", () => {
  assert.match(boot(38, 37).skew, /Native API skew/);
  assert.deepEqual(boot(38, 38).events, ["main", "legacy-js-cleanup"]);
});

test("keep-alive event stamps retain the API 37 historical gate", () => {
  assert.match(boot(37, 36).skew, /Native API skew/);
  assert.deepEqual(boot(37, 37).events, ["main", "legacy-js-cleanup"]);
});

test("a matching bundle reaches main through the same entry gate", () => {
  const result = boot(jsVersion(), nativeVersion());
  assert.equal(result.skew, null);
  assert.deepEqual(result.events, ["main", "legacy-js-cleanup"]);
});

test("derived services start JS profile cleanup only in the fallback lane", () => {
  const source = read("./lib/persist.ts");
  const derived = source.slice(source.indexOf("function startDerivedServices("), source.indexOf("function forgetClosedIncognito("));
  for (const owns of [true, false]) {
    let starts = 0;
    let stops = 0;
    const stop = runInNewContext(compile(derived + "\nstartDerivedServices({ forgetsIncognito: false });"), {
      nativeOwnsWorkspace: () => owns,
      startProfileDataCleanup: () => { starts++; return () => { stops++; }; },
      startFavicons: () => () => {},
      startHistory: () => () => {},
      startBookmarks: () => () => {},
    });
    assert.equal(starts, owns ? 0 : 1);
    stop();
    assert.equal(stops, owns ? 0 : 1);
  }
});
