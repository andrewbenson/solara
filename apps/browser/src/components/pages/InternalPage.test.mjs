import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";
import vm from "node:vm";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const source = readFileSync(new URL("./InternalPage.tsx", import.meta.url), "utf8");
const urlsSource = readFileSync(new URL("./internalUrls.ts", import.meta.url), "utf8");

function harness(owned) {
  const tab = { id: "t", url: "https://previous.test/", title: "Previous website", profileId: "p", windowId: "w", navigation: { seq: 2, url: "solara://history?q=example" }, favicon: "previous-icon" };
  const live = { isLoading: true, canGoBack: true, canGoForward: true, discarded: false };
  const calls = [];
  const state = {
    tabs: { t: tab }, windows: { w: {} },
    updateTab: (id, patch) => { assert.equal(id, "t"); calls.push("updateTab"); Object.assign(tab, patch); },
    updateLive: (id, patch) => { assert.equal(id, "t"); calls.push("updateLive"); Object.assign(live, patch); },
  };
  const useBrowser = Object.assign((selector) => selector(state), { getState: () => state });
  const mocks = {
    react: { useEffect: (effect) => effect() },
    "react/jsx-runtime": { jsx: () => null, jsxs: () => null },
    "react-native": { StyleSheet: { absoluteFill: {} }, View: () => null },
    "@solara/core": { appScheme: () => "solara", isAppScheme: (scheme) => scheme === "solara" },
    "../../store/nativeStore": { nativeOwnsWorkspace: () => owned },
    "../../store/browser": { useBrowser },
    "../../store/model": { bookmarkProfileId: () => "p" },
    "../../store/pageProgress": { setPageProgress: (id, value) => calls.push(["progress", id, value]) },
  };
  const load = (contents) => {
    const module = { exports: {} };
    const code = ts.transpileModule(contents, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } }).outputText;
    new vm.Script(code).runInNewContext({ exports: module.exports, module, require: (id) => mocks[id] ?? {} });
    return module.exports;
  };
  mocks["./urls"] = { ...load(urlsSource), tabDestination: (value) => value.navigation?.url ?? value.url };
  const { InternalPage } = load(source);
  return { tab, live, calls, render: () => InternalPage({ tabId: "t" }) };
}

test("native internal pages complete URL and title without writing live facts", () => {
  const h = harness(true);
  h.render();
  assert.equal(h.tab.url, "solara://history?q=example");
  assert.equal(h.tab.title, "History");
  assert.equal(h.tab.favicon, null);
  assert.equal(h.live.isLoading, true);
  assert.equal(h.live.canGoBack, true);
  assert.equal(h.live.canGoForward, true);
  assert.equal(h.calls.includes("updateLive"), false);
  assert.deepEqual(h.calls.at(-1), ["progress", "t", 0]);
  h.render();
  assert.equal(h.calls.filter((call) => call === "updateTab").length, 1);
});

test("fallback internal pages complete metadata and reset live loading", () => {
  const h = harness(false);
  h.render();
  assert.equal(h.tab.url, "solara://history?q=example");
  assert.equal(h.tab.title, "History");
  assert.equal(h.live.isLoading, false);
  assert.equal(h.live.canGoBack, false);
  assert.equal(h.live.canGoForward, false);
});
