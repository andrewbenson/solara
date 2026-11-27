import "../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";
import { registerHooks } from "node:module";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier === "./tour/state" && context.parentURL?.endsWith("/onboarding/state.ts")) return { url: "data:text/javascript,export const endToolTour = () => {}; export const startToolTour = () => {};", shortCircuit: true };
    if (context.parentURL?.endsWith("/pages/devDrivers.ts") && !["../../store/browser", "../../store/nativeStore", "../../store/tileFolders", "@solara/store"].includes(specifier)) return { url: `data:text/javascript,${encodeURIComponent("export const importModule = null, openImport = null, openSettings = null, useBookmarkDialog = null, useBookmarkEditor = null, useMeetingAlert = null, useCalendar = null, useEngineOffers = null, measureRow = null, setSidebarUi = null, useFolderPanel = null, useClearDataRequest = null, openInternalPage = null;")}`, shortCircuit: true };
    return next(specifier, context);
  },
});

const sent = [];
let result;
globalThis.__DEV__ = true;
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: true }),
    dispatch: (json, rev) => {
      const commands = [JSON.parse(json)].flat();
      sent.push(...commands);
      return JSON.stringify({ rev, patches: [], result });
    },
    catchUp: (rev) => JSON.stringify({ rev, patches: [] }),
    addListener: () => ({ remove() {} }),
  },
};

const { useBrowser } = await import("./browser.ts");
const { attachReplica, nativeForwardedWrites, startNativeStore, withApplier } = await import("./nativeStore.ts");
const { setWindowLayout } = await import("../components/onboarding/state.ts");
const { pagesDrivers } = await import("../components/pages/devDrivers.ts");
const S = () => useBrowser.getState();
S().hydrate({});
const windowId = S().createWindow({ url: "https://home.example/" });
const first = S().newTab(windowId, { index: S().windows[windowId].tabIds.length, url: "https://one.example/" });
const second = S().newTab(windowId, { index: S().windows[windowId].tabIds.length, url: "https://two.example/" });
const baseline = S();
startNativeStore();
attachReplica(useBrowser);
const actions = S();
beforeEach(() => {
  withApplier(() => useBrowser.setState({ ...baseline, ...Object.fromEntries(Object.entries(actions).filter(([, value]) => typeof value === "function")) }));
  sent.length = 0;
  result = undefined;
});
afterEach(() => {
  assert.equal(nativeForwardedWrites(), 0);
  assert.equal(globalThis.__nativeStoreForwards?.length ?? 0, 0);
});

test("onboarding sets only the requested window layout through a command", () => {
  const settings = S().settings;
  setWindowLayout(windowId, "top");
  assert.deepEqual(sent, [{ name: "setWindowLayout", args: [windowId, "top"] }]);
  assert.equal(S().settings, settings);
});

test("the tile folder dev driver sends the native command without a replica write", () => {
  result = "folder-native";
  const before = S();
  assert.equal(pagesDrivers.tileFolders.make([first, second]), "folder-native");
  assert.deepEqual(sent, [{ name: "newTileFolder", args: [[first, second]] }]);
  assert.equal(S(), before);
});
