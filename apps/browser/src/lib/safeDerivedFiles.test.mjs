import "../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";

let nativeStatus = { active: false, safeMode: "option", reason: "settings-only fallback" };
globalThis.acTestNativeModules = { SolaraStoreAdapter: { status: () => nativeStatus } };
const { docs, documentWrites, deletedProfileData, bookmarkOpsSent } = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
const { startNativeStore } = await import("../store/nativeStore.ts");
const { migrateBookmarksFile, startBookmarks } = await import("./bookmarks.ts");
const { migrateHistoryFile } = await import("./history.ts");
const { startFavicons } = await import("./favicons.ts");
const { startProfileDataCleanup } = await import("./profileData.ts");
startNativeStore();

const bookmarkFile = JSON.stringify({ bookmarks: { roots: { absent: { bar: "bar", other: "other" } }, nodes: {} } });
const historyFile = JSON.stringify({ history: { absent: [{ url: "https://kept.example", lastVisit: Date.now() }] } });

test("safe fallback keeps legacy bookmarks without migrating or deleting them", async () => {
  docs.set("bookmarks.json", bookmarkFile);
  assert.equal(await migrateBookmarksFile({ keepMs: 0 }), "kept");
  assert.equal(docs.get("bookmarks.json"), bookmarkFile);
  assert.equal(bookmarkOpsSent.length, 0);
});

test("safe fallback keeps legacy history without migrating or deleting it", async () => {
  docs.set("history.json", historyFile);
  assert.equal(await migrateHistoryFile(Date.now(), { keepMs: 0 }), "kept");
  assert.equal(docs.get("history.json"), historyFile);
});

test("safe derived services preserve legacy favicons through stop", async () => {
  docs.set("favicons-default.json", "legacy favicons");
  docs.set("bookmarks-cache.json", "saved cache");
  const stopFavicons = startFavicons();
  const stopBookmarks = startBookmarks();
  for (let i = 0; i < 8; i++) await new Promise((resolve) => setImmediate(resolve));
  useBrowser.getState().addBookmark({ profileId: "default", url: "https://safe.example", title: "Safe" });
  stopBookmarks();
  stopFavicons();
  assert.equal(docs.get("favicons-default.json"), "legacy favicons");

});

test("safe derived services leave orphaned profile data queued without deletion", async () => {
  useBrowser.setState({ orphanedProfileData: ["orphan"] });
  const stop = startProfileDataCleanup();
  await new Promise((resolve) => setTimeout(resolve, 1600));
  stop();
  assert.deepEqual(deletedProfileData, []);
  assert.deepEqual(useBrowser.getState().orphanedProfileData, ["orphan"]);
});

for (const safeMode of ["option", "failedLaunches"]) {
  for (const active of [false, true]) {
    for (const existing of [false, true]) {
      test(`safe bookmarks never write the cache: ${safeMode}, active=${active}, existing=${existing}`, async (t) => {
        nativeStatus = { active, scope: "settingsAndDownloads", safeMode };
        startNativeStore();
        if (existing) docs.set("bookmarks-cache.json", "saved cache");
        else docs.delete("bookmarks-cache.json");
        documentWrites.length = 0;
        t.mock.timers.enable({ apis: ["setTimeout"] });
        const stop = startBookmarks();
        try {
          for (let i = 0; i < 8; i++) await new Promise((resolve) => setImmediate(resolve));
          useBrowser.getState().addBookmark({ profileId: "default", url: "https://safe-cache.example/timer", title: "Timer" });
          t.mock.timers.tick(2001);
          assert.equal(documentWrites.includes("bookmarks-cache.json"), false);
          useBrowser.getState().addBookmark({ profileId: "default", url: "https://safe-cache.example/stop", title: "Stop" });
        } finally {
          stop();
        }
        assert.equal(documentWrites.includes("bookmarks-cache.json"), false);
        assert.equal(docs.get("bookmarks-cache.json"), existing ? "saved cache" : undefined);
      });
    }
  }
}

test("normal bookmarks still write their derived cache", async (t) => {
  nativeStatus = { active: false, safeMode: null };
  startNativeStore();
  docs.delete("bookmarks-cache.json");
  documentWrites.length = 0;
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const stop = startBookmarks();
  try {
    for (let i = 0; i < 8; i++) await new Promise((resolve) => setImmediate(resolve));
    useBrowser.getState().addBookmark({ profileId: "default", url: "https://normal-cache.example", title: "Normal" });
    t.mock.timers.tick(2001);
  } finally {
    stop();
  }
  assert.ok(documentWrites.includes("bookmarks-cache.json"));
  assert.equal(JSON.parse(docs.get("bookmarks-cache.json")).version, 1);
});
