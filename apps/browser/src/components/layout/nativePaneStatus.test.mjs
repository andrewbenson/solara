import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { test } from "node:test";

const admission = { windowId: "source", generation: 8 };
globalThis.nativePaneStatusTest = admission;
const url = new URL("./nativePaneStatus.ts", import.meta.url).href;
registerHooks({
  resolve(specifier, context, next) {
    if (context.parentURL === url && specifier === "../../store/browser") return {
      url: "data:text/javascript,export const useBrowser = { getState: () => ({ tabs: { a: { windowId: globalThis.nativePaneStatusTest.windowId } } }) };", shortCircuit: true,
    };
    if (context.parentURL === url && specifier === "@solara/settings") return {
      url: "data:text/javascript,export const windowNativeLayoutGeneration = () => globalThis.nativePaneStatusTest.generation;", shortCircuit: true,
    };
    return next(specifier, context);
  },
});
const { publishNativePaneStatus } = await import("./nativePaneStatus.ts");
const { paneStatusStyle, dropPaneStatusStyle } = await import("./paneFeed.ts");

test("a moved pane rejects a stale source motion update and cleanup", () => {
  const source = {}, target = {};
  const before = { transform: [{ translateY: {} }] };
  const after = { transform: [{ translateY: {} }] };
  publishNativePaneStatus("source", 8, "a", source, before);
  assert.equal(paneStatusStyle("a"), before);
  admission.windowId = "target";
  publishNativePaneStatus("target", 8, "a", target, after);
  publishNativePaneStatus("source", 8, "a", source, before);
  dropPaneStatusStyle("a", source);
  assert.equal(paneStatusStyle("a"), after);
  admission.generation = 9;
  publishNativePaneStatus("target", 8, "a", target, before);
  assert.equal(paneStatusStyle("a"), after);
  dropPaneStatusStyle("a", target);
});
