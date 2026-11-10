import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
const { useBrowser } = await import("../store/browser.ts");
const { bookmarkWriter } = await import("./bookmarkWriter.ts");
const { bookmarksAdapter } = await import("../sync/adapters.ts");
const { bookmarkWriterState } = await import("@solara/settings");
const { startBookmarks } = await import("./bookmarks.ts");
const { docs, documentWrites } = await import("../test-native/shell.ts");
afterEach(() => { delete globalThis.acTestBookmarkWriter; delete globalThis.acTestEngineCall; });

for (const state of ["legacy", "starting", "read-only-unavailable", "stopped"]) {
  test(`${state} has no executable JS writer fallback`, async () => {
    globalThis.acTestBookmarkWriter = { state: () => ({ state }) };
    const before = useBrowser.getState().bookmarks;
    let notifications = 0;
    const unsubscribe = useBrowser.subscribe(() => notifications++);
    try {
      await assert.rejects(bookmarkWriter.addBookmark({ profileId: "default", title: "Refused", url: "https://refused.test/" }), /native|unavailable|paused/i);
      assert.throws(() => useBrowser.getState().addBookmark({ profileId: "default", title: "Refused", url: "https://refused.test/" }), /native|owned/i);
      assert.throws(() => useBrowser.setState({ bookmarks: { nodes: {}, roots: {} } }), /native|owned/i);
      const adapter = bookmarksAdapter("default");
      assert.equal(adapter.extract(() => undefined), null);
      assert.equal(await adapter.apply(new Map(), new Set(), () => undefined, {}), false);
      assert.equal(useBrowser.getState().bookmarks, before);
      assert.equal(notifications, 0);
    } finally { unsubscribe(); }
  });
}

test("legacy selection with native journal fails closed without reading or migrating JS data", async () => {
  globalThis.acTestBookmarkWriter = { state: () => ({ state: "legacy" }) };
  const calls = [];
  globalThis.acTestEngineCall = (name) => { calls.push(name); return {}; };
  docs.clear(); documentWrites.length = 0;
  docs.set("bookmarks-pending-native-v1.json", "native-journal-evidence");
  docs.set("bookmarks.json", '{"bookmarks":{"nodes":{},"roots":{}}}');
  const stop = startBookmarks();
  try {
    for (let n = 0; n < 30; n++) await Promise.resolve();
    assert.deepEqual(calls, []);
    assert.deepEqual(documentWrites, []);
    assert.equal(docs.get("bookmarks-pending-native-v1.json"), "native-journal-evidence");
    assert.equal(docs.get("bookmarks.json"), '{"bookmarks":{"nodes":{},"roots":{}}}');
    assert.equal(bookmarkWriterState().state, "read-only-unavailable");
  } finally { stop(); }
});
