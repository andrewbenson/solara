import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";
import { registerHooks } from "node:module";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier === "./tour/state" && context.parentURL?.endsWith("/onboarding/state.ts")) return { url: "data:text/javascript,export const endToolTour = () => {}; export const startToolTour = () => {};", shortCircuit: true };
    if (context.parentURL?.endsWith("/pages/devDrivers.ts") && !["../import/apply", "../../store/browser", "../../store/nativeStore", "../../store/tileFolders", "@solara/store"].includes(specifier)) return { url: `data:text/javascript,${encodeURIComponent("export const importModule = null, openImport = null, openSettings = null, useBookmarkDialog = null, useBookmarkEditor = null, useMeetingAlert = null, useCalendar = null, useEngineOffers = null, measureRow = null, setSidebarUi = null, useFolderPanel = null, useClearDataRequest = null, openInternalPage = null;")}`, shortCircuit: true };
    return next(specifier, context);
  },
});

const sent = [];
let result;
let onDispatch;
globalThis.__DEV__ = true;
globalThis.acTestNativeModules = {
  SolaraStoreAdapter: {
    status: () => ({ active: true, scope: "everything" }),
    dispatch: (json, rev) => {
      const commands = [JSON.parse(json)].flat();
      sent.push(...commands);
      commands.forEach((command) => onDispatch?.(command));
      return JSON.stringify({ rev, patches: [], result: commands.some((command) => command.name === "openDraftGroups") ? { made: [], skipped: 0 } : result });
    },
    catchUp: (rev) => JSON.stringify({ rev, patches: [] }),
    addListener: () => ({ remove() {} }),
  },
};

const { useBrowser } = await import("./browser.ts");
const { attachReplica, nativeForwardedWrites, startNativeStore, withApplier } = await import("./nativeStore.ts");
const { applyResult, importArcSpace, importDiaProfile, importTabs } = await import("../components/import/apply.ts");
const { moveGroupToBookmarksBar } = await import("../lib/bookmarkGroups.ts");
const { setWindowLayout } = await import("../components/onboarding/state.ts");
const { pagesDrivers } = await import("../components/pages/devDrivers.ts");
const S = () => useBrowser.getState();
S().hydrate({});
const windowId = S().createWindow({ url: "https://home.example/" });
const first = S().newTab(windowId, { url: "https://one.example/" });
const second = S().newTab(windowId, { url: "https://two.example/" });
const groupId = S().createGroup([first, second], { name: "Saved" });
const baseline = S();
startNativeStore();
attachReplica(useBrowser);
const actions = S();
beforeEach(() => {
  withApplier(() => useBrowser.setState({ ...baseline, ...Object.fromEntries(Object.entries(actions).filter(([, value]) => typeof value === "function")) }));
  sent.length = 0;
  result = undefined;
  onDispatch = undefined;
});
afterEach(() => {
  assert.equal(nativeForwardedWrites(), 0);
  assert.equal(globalThis.__nativeStoreForwards?.length ?? 0, 0);
});

test("filing a group creates bookmarks before sending its close command", async () => {
  let filed;
  onDispatch = ({ name }) => {
    if (name === "closeGroup") filed = Object.values(S().bookmarks.nodes).filter((node) => node.kind === "url").map((node) => node.url);
  };
  await moveGroupToBookmarksBar(groupId);
  assert.deepEqual(sent.map((command) => command.name), ["closeGroup"]);
  assert.deepEqual(filed, ["https://one.example/", "https://two.example/"]);
});

test("import sends one workspace draft with pin and group metadata and uses the accepted count", () => {
  result = { tabs: 2 };
  const tabs = [
    { url: "https://pin.example/", title: "Pin", pinned: true, row: true, customTitle: "Mine" },
    { url: "https://open.example/", title: "Open", pinned: false },
    { url: "https://open.example/#", title: "Duplicate", pinned: false },
  ];
  const before = S();
  assert.equal(importTabs("default", tabs, "Imported", "tiles"), 2);
  assert.deepEqual(sent, [{ name: "importWorkspace", args: [{ profileId: "default", pinnedAgainst: "tiles", windows: [{ tabs, group: "Imported" }] }] }]);
  assert.equal(S(), before);
});

test("import with no window lets Swift create the window in its workspace transaction", () => {
  withApplier(() => useBrowser.setState({ windows: {}, windowOrder: [], tabs: {}, groups: {}, ui: { ...S().ui, focusOrder: [], focusedWindowId: null } }));
  result = { tabs: 1 };
  assert.equal(importTabs("default", [{ url: "https://new.example/", title: "New", pinned: false }], null), 1);
  assert.deepEqual(sent.map((command) => command.name), ["importWorkspace"]);
});

test("onboarding sets only the requested window layout through a command", () => {
  const settings = S().settings;
  setWindowLayout(windowId, "top");
  assert.deepEqual(sent, [{ name: "setWindowLayout", args: [windowId, "top"] }]);
  assert.equal(S().settings, settings);
});

test("a result imports open tabs and favorite tiles in one workspace command", async () => {
  result = { tabs: 2 };
  const data = { tabs: [{ url: "https://open.example/", title: "Open", pinned: false }], favorites: [{ url: "https://pin.example/", title: "Pin" }], spaces: [], history: [], credentials: [] };
  const counts = await applyResult("default", data, "Chrome", []);
  assert.equal(counts.tabs, 2);
  assert.deepEqual(sent.map((command) => command.name), ["importWorkspace"]);
  assert.deepEqual(sent[0].args[0].windows.map((window) => window.pinnedAgainst ?? "anyPin"), ["anyPin", "tiles"]);
});

test("an Arc space files rows, open tabs and nested folders in one workspace command", () => {
  result = { tabs: 3, skipped: 2 };
  const space = { tabs: [{ url: "https://open.example/", title: "Open" }], pinned: [{ type: "url", url: "https://row.example/", title: "Row" }, { type: "folder", title: "Work", children: [{ type: "url", url: "https://folder.example/", title: "Folder" }] }] };
  assert.deepEqual(importArcSpace("default", space), { tabs: 3, bookmarks: 0, skipped: 2 });
  assert.deepEqual(sent.map((command) => command.name), ["importWorkspace"]);
  assert.equal(sent[0].args[0].windows[0].tabs.length, 1);
  assert.equal(sent[0].args[0].windows[1].tabs.length, 1);
  assert.equal(sent[0].args[0].windows[1].drafts[0].children[0].url, "https://folder.example/");
});

test("a Dia profile imports its pins and open tabs in one workspace command", () => {
  result = { tabs: 2 };
  const profile = { pinned: [{ url: "https://pin.example/", title: "Pin", pinned: true }], tabs: [{ url: "https://open.example/", title: "Open", pinned: false }] };
  assert.equal(importDiaProfile("default", profile, { pinned: true, open: true }), 2);
  assert.deepEqual(sent.map((command) => command.name), ["importWorkspace"]);
});

test("the tile folder dev driver sends the native command without a replica write", () => {
  result = "folder-native";
  const before = S();
  assert.equal(pagesDrivers.tileFolders.make([first, second]), "folder-native");
  assert.deepEqual(sent, [{ name: "newTileFolder", args: [[first, second]] }]);
  assert.equal(S(), before);
});

test("Arc drafts put pinned rows before open tabs so native dedupe sees earlier pins", () => {
  result = { tabs: 1, skipped: 0 };
  const url = "https://both.example/";
  importArcSpace("default", { tabs: [{ url, title: "Open" }], pinned: [{ type: "url", url, title: "Pin" }] });
  assert.equal(sent.length, 1);
  assert.deepEqual(sent[0].args[0].windows.map((draft) => draft.tabs.map((tab) => tab.pinned)), [[true], [false]]);
  assert.equal(sent[0].args[0].windows[1].group, "Imported");
});

test("Dia sends raw pins then open tabs for native dedupe against authoritative open pages", () => {
  result = { tabs: 1 };
  const pin = { url: "https://one.example/", title: "Already in replica", pinned: true };
  const open = { url: "https://one.example/", title: "Open", pinned: false };
  importDiaProfile("default", { pinned: [pin], tabs: [open] }, { pinned: true, open: true });
  assert.equal(sent.length, 1);
  assert.deepEqual(sent[0].args[0].windows.map((draft) => draft.tabs), [[pin], [open]]);
  assert.deepEqual(sent[0].args[0].windows.map((draft) => draft.skipExistingOpen), [true, true]);
});
