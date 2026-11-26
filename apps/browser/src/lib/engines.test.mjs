import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { test } from "node:test";

globalThis.__DEV__ = false;
const toasts = new Map();
globalThis.engineTestToasts = toasts;
globalThis.engineTestRequests = [];
globalThis.engineTestResult = false;
const stubs = {
  "@solara/settings": `export const nativeEngineCommand = async (...args) => { globalThis.engineTestRequests.push(args); return globalThis.engineTestResult; };
    export const nativeAddHistoryVisits = async () => {};`,
  "../components/layout/splitActions": `export const showToast = (windowId, title, message, options) => globalThis.engineTestToasts.set(windowId, { title, ...options });
    export const hideKeyedToast = (windowId, key) => globalThis.engineTestToasts.get(windowId)?.key === key && globalThis.engineTestToasts.delete(windowId);`,
};
registerHooks({
  resolve(specifier, context, next) {
    if (!context.parentURL?.endsWith("/lib/engines.ts") || !(specifier in stubs)) return next(specifier, context);
    return { url: `data:text/javascript,${encodeURIComponent(stubs[specifier])}`, shortCircuit: true };
  },
});

const { useBrowser } = await import("../store/browser.ts");
const model = await import("../store/model.ts");
const { goBackAcrossEngines, offerWebKit, openPageIn, persistEngine, togglePageEngine, followSiteChoice } = await import("./engines.ts");

const S = () => useBrowser.getState();
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("engine back delegates the explicit tab and returns native acceptance", async () => {
  globalThis.engineTestRequests.length = 0;
  globalThis.engineTestResult = false;
  assert.equal(await goBackAcrossEngines("a"), false);
  globalThis.engineTestResult = true;
  assert.equal(await goBackAcrossEngines("b"), true);
  assert.deepEqual(globalThis.engineTestRequests, [["a", "back"], ["b", "back"]]);
});

test("engine requests forward destinations and options to native ownership", async () => {
  globalThis.engineTestRequests.length = 0;
  globalThis.engineTestResult = true;
  assert.equal(await openPageIn("a", "webkit", { rule: null, checkWork: false }), true);
  persistEngine("b", "chromium");
  assert.equal(await togglePageEngine("c"), true);
  followSiteChoice("d", "chromium", "https://film.example/", "https://search.example/");
  assert.deepEqual(globalThis.engineTestRequests, [
    ["a", "open", { engine: "webkit", rule: null, checkWork: false }],
    ["b", "persist", { engine: "chromium" }],
    ["c", "toggle"],
    ["d", "follow", { engine: "chromium", url: "https://film.example/", previousUrl: "https://search.example/" }],
  ]);
});

test("Move Back goes away once the tab leaves the moved site, and never saves a rule for another site", async () => {
  S().hydrate({});
  S().updateSettings({ protectedVideoInWebKit: true });
  const w = S().createWindow({ url: "https://www.netflix.com/watch/1" });
  const tabId = model.activeTabId(S(), w);
  S().updateTab(tabId, { engine: "chromium", url: "https://www.netflix.com/watch/1" });
  globalThis.engineTestRequests.length = 0;
  globalThis.engineTestResult = true;
  offerWebKit(tabId, { keySystem: "com.widevine.alpha" });
  await settle();
  const toast = toasts.get(w);
  assert.equal(toast?.action?.title, "Move Back");
  S().updateTab(tabId, { url: "https://other.example/" });
  assert.equal(toasts.has(w), false);
  toast.action.run();
  await settle();
  assert.deepEqual(S().settings.websiteEngines, {});
  assert.deepEqual(globalThis.engineTestRequests, [[tabId, "open", { engine: "webkit" }]]);
});
