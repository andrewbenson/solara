import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { test } from "node:test";

const restoreUnderNativeStore = `
  import assert from "node:assert/strict";
  globalThis.__DEV__ = false;
  const tab = { id: "t1", windowId: "w1", profileId: "default", url: "https://a.example/", title: "A", favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, pinnedUrl: null, openerId: null, createdAt: 1, lastActiveAt: 1 };
  const win = { id: "w1", profileId: "default", incognito: false, tabIds: ["t1"], activeTabIds: { default: "t1" }, sidebarOpen: true, frame: null, createdAt: 1 };
  const data = { live: { t1: { isLoading: false, canGoBack: false, canGoForward: false, playingAudio: false, themeColor: null, discarded: false } }, profiles: { default: { id: "default", name: "Personal", color: "plum", icon: null, createdAt: 0 } }, profileOrder: ["default"], windows: { w1: win }, windowOrder: ["w1"], tabs: { t1: tab }, groups: {}, splits: {}, peeks: {}, closedTabs: [], closedWindows: [], closedGroups: [], deletedGroups: [], cleanedTabs: [], parkedPins: {}, pinChoices: {}, pinSync: {}, downloads: [], settings: { chosen: [], inferred: [] }, ui: { focusedWindowId: "w1", focusOrder: ["w1"], lastProfileId: null } };
  let carried = [];
  const drafts = [];
  globalThis.acTestNativeModules = { SolaraStoreAdapter: {
    status: () => ({ active: true, scope: "everything" }),
    snapshot: () => JSON.stringify({ rev: 1, data }),
    dispatch: (json, since) => {
      const draft = [JSON.parse(json)].flat().find((command) => command.name === "openDraftGroups");
      if (draft) drafts.push(draft);
      return JSON.stringify({ rev: Math.max(1, since), patches: [], ...(draft ? { result: { made: ["g-native"], carried, skipped: 0 } } : {}) });
    },
    catchUp: () => JSON.stringify({ rev: 1, snapshot: data }),
    flush: () => "saved",
    addListener: () => ({ remove() {} }),
  } };
  const { useBrowser } = await import("./src/store/browser.ts");
  const { startNativeStore, attachReplica, nativeOwnsWorkspace } = await import("./src/store/nativeStore.ts");
  startNativeStore();
  attachReplica(useBrowser);
  const { restoreArcFolders } = await import("./src/lib/bookmarkGroups.ts");
  const S = () => useBrowser.getState();
  assert.equal(nativeOwnsWorkspace(), true);
  S().addBookmark({ profileId: "default", url: "https://seed.example/", title: "seed" });
  const holder = S().addBookmarkFolder({ profileId: "default", title: "Space (Arc)", parentId: S().bookmarks.roots.default.bar });
  const folder = S().addBookmarkFolder({ profileId: "default", title: "Work", parentId: holder });
  const link = S().addBookmark({ profileId: "default", url: "https://docs.example.com/plan", title: "Plan", parentId: folder });
  carried = [link];
  assert.deepEqual(restoreArcFolders(holder, "w1"), ["g-native"]);
  assert.equal(drafts.length, 1);
  assert.equal(S().bookmarks.nodes[link], undefined, "the carried link leaves the bookmarks");
  assert.equal(S().bookmarks.nodes[folder], undefined, "the folder that became a group leaves the bookmarks");
  assert.equal(S().bookmarks.nodes[holder], undefined, "the emptied Arc holder goes too");
`;

test("restoring Arc folders while the native store owns the workspace removes the carried bookmarks", () => {
  const result = spawnSync(process.execPath, ["--no-warnings", "--import", "./src/test-loader.mjs", "--input-type=module", "-e", restoreUnderNativeStore], {
    cwd: new URL("../..", import.meta.url), encoding: "utf8", timeout: 20000,
  });
  assert.equal(result.status, 0, result.stderr || result.error?.message);
});
