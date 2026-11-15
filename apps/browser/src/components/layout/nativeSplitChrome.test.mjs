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
const { publishNativeDrop, useNativePageTops, useNativeSplitChrome, feedSplitToolbar, dropSplitToolbar } = await import("./nativeSplitChrome.ts");
const frame = { shown: true, grown: true, px: 10, target: { tabId: "a", side: "right" }, panes: [["a", { x: 0, y: 0, width: 800, height: 600 }]] };

test("native layout refuses a late legacy drag geometry publication", () => {
  publishNativeDrop("native", frame);
  assert.deepEqual(published, []);
});

test("legacy layout still publishes its drag target and pane bounds", () => {
  published.length = 0;
  publishNativeDrop("legacy", frame);
  assert.deepEqual(published, [["split.drag", { v: 1, windowId: "legacy", shown: true, grown: true, px: 10, target: ["a", "right"], panes: [["a", 0, 0, 800, 600]] }]]);
});

test("headless native theme updates omit JavaScript presentation policy", async () => {
  published.length = 0;
  useNativeSplitChrome("native", true, { dark: true }, "a", false, true, false);
  useNativePageTops("native", true, { a: 105 });
  useNativeSplitChrome("legacy", true, { dark: false }, null, false, true, false);
  useNativePageTops("legacy", true, { a: 38 });
  await Promise.resolve();
  const value = published.findLast(([topic]) => topic === "split.theme")?.[1];
  for (const key of ["fullscreenTab", "covered", "toolbar", "small", "pageTops"]) assert.equal(Object.hasOwn(value.windows.native, key), false);
  assert.equal(value.windows.native.theme.dark, true);
  assert.deepEqual(value.windows.legacy.pageTops, { a: 38 });
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
