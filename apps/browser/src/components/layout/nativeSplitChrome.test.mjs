import assert from "node:assert/strict";
import { test } from "node:test";
import { registerHooks } from "node:module";

registerHooks({
  resolve(specifier, context, next) {
    if (context.parentURL?.endsWith("/layout/nativeSplitChrome.ts") && specifier === "../settings/nativeSettings")
      return { url: "data:text/javascript,export const addNativeSettingsHandlers = () => {};", shortCircuit: true };
    if (context.parentURL?.endsWith("/layout/nativeSplitChrome.ts") && specifier === "react")
      return { url: "data:text/javascript,export const useEffect = (run) => run();", shortCircuit: true };
    if (context.parentURL?.endsWith("/layout/nativeSplitChrome.ts") && specifier === "./splitActions")
      return next("./toasts", context);
    return next(specifier, context);
  },
});

const published = [];
globalThis.acTestNativeModules = {
  SolaraSettings: { publish: async (topic, json) => published.push([topic, JSON.parse(json)]) },
  SolaraWindowShell: { nativeLayout: (windowId) => windowId === "native" },
};
const { useNativeSplitChrome, feedSplitToolbar, dropSplitToolbar } = await import("./nativeSplitChrome.ts");

test("headless native theme updates omit JavaScript presentation policy", async () => {
  published.length = 0;
  useNativeSplitChrome("native", true, { dark: true });
  useNativeSplitChrome("legacy", true, { dark: false });
  useNativeSplitChrome("fallback", true, { dark: false }, { fullscreenTab: "a", covered: true, toolbar: true, small: false });
  await Promise.resolve();
  const value = published.findLast(([topic]) => topic === "split.theme")?.[1];
  for (const key of ["fullscreenTab", "covered", "toolbar", "small", "pageTops"]) assert.equal(Object.hasOwn(value.windows.native, key), false);
  assert.equal(value.windows.native.theme.dark, true);
  assert.deepEqual(value.windows.legacy, { theme: { dark: false } });
  assert.equal(value.windows.fallback.fullscreenTab, "a");
  assert.equal(value.windows.fallback.covered, true);
});

test("a retired toolbar publisher cannot remove its replacement pane model", async () => {
  published.length = 0;
  const old = { current: { onClick() {}, onAnchors() {} } };
  const fresh = { current: { onClick() {}, onAnchors() {} } };
  feedSplitToolbar("native", "a", "old", old);
  feedSplitToolbar("native", "a", "fresh", fresh);
  dropSplitToolbar("native", "a", old);
  await Promise.resolve();
  const value = published.findLast(([topic]) => topic === "split.toolbar")?.[1];
  assert.equal(value.windows.native?.a, "fresh");
  dropSplitToolbar("native", "a", fresh);
});
