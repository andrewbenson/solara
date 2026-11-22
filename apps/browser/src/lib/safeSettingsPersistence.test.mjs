import assert from "node:assert/strict";
import { test } from "node:test";

const win = { id: "w1", profileId: "default", incognito: false, tabIds: [], activeTabIds: {}, sidebarOpen: true, frame: null, createdAt: 1 };
const workspace = {
  profiles: { default: { id: "default", name: "Personal", color: "plum", icon: null, createdAt: 0 } }, profileOrder: ["default"],
  windows: { w1: win }, windowOrder: ["w1"], tabs: {}, groups: {}, splits: {}, peeks: {}, closedTabs: [], closedWindows: [], closedGroups: [],
  deletedGroups: [], cleanedTabs: [], parkedPins: {}, pinChoices: {}, pinSync: {},
  settings: { searchEngine: "duckduckgo", chosen: [], inferred: [] },
  downloads: [{ id: "kept", state: "complete", url: "https://download.example", profile: "" }],
  ui: { focusedWindowId: "w1", focusOrder: ["w1"], lastProfileId: null },
};
let rev = 0;
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: true, safeMode: "failedLaunches" }),
    snapshot: () => JSON.stringify({ rev, data: workspace }),
    dispatch: () => JSON.stringify({ rev, patches: [] }),
    catchUp: () => JSON.stringify({ rev }),
    flush: () => true,
    addListener: () => ({ remove() {} }),
  },
};
const { docs, unreadableDocs } = await import("../test-native/index.ts");
const { shellNativeModules } = await import("../test-native/shell.ts");
const reads = [];
const read = shellNativeModules.SolaraShell.readDocumentResult;
shellNativeModules.SolaraShell.readDocumentResult = (name) => { reads.push(name); return read(name); };
const { useBrowser } = await import("../store/browser.ts");
const { startPersistence, flushPersistence } = await import("./persist.ts");
const { persistenceRefused } = await import("./persistLatch.ts");
const { useToasts } = await import("../components/layout/toasts.ts");

test("safe startup on the native store leaves an unreadable saved session unread and untouched, hydrates from Swift and shows its notice", () => {
  docs.set("session.json", "untouched bytes");
  unreadableDocs.set("session.json", "permission denied");
  const stop = startPersistence();
  assert.equal(persistenceRefused(), false);
  assert.equal(reads.includes("session.json"), false);
  assert.equal(useBrowser.getState().settings.searchEngine, "duckduckgo");
  assert.deepEqual(useBrowser.getState().downloads.map((d) => d.id), ["kept"]);
  assert.equal(useToasts.getState().toasts.w1?.title, "Solara started in safe mode");
  flushPersistence({ final: true });
  stop();
  assert.equal(docs.get("session.json"), "untouched bytes");
});
