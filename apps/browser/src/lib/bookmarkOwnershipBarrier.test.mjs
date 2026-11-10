import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";
const { useBrowser } = await import("../store/browser.ts");
const { bookmarkWriter } = await import("./bookmarkWriter.ts");

beforeEach(() => {
  useBrowser.setState({ bookmarks: { nodes: {}, roots: {} } });
  useBrowser.getState().hydrate({});
});
afterEach(() => { delete globalThis.acTestBookmarkWriter; });

for (const state of ["starting", "read-only-unavailable", "stopped", "future"]) {
  test(`${state} native authority refuses edits without running JS reducers`, async () => {
    globalThis.acTestBookmarkWriter = { state: () => ({ state }), snapshot: () => { throw new Error("unavailable"); } };
    const before = JSON.stringify(useBrowser.getState().bookmarks);
    await assert.rejects(bookmarkWriter.addBookmark({ profileId: "default", title: "Draft", url: "https://draft.test/" }));
    assert.equal(JSON.stringify(useBrowser.getState().bookmarks), before);
  });
}

const { bookmarksAdapter } = await import("../sync/adapters.ts");
for (const state of ["starting", "read-only-unavailable", "stopped", "future"]) {
  test(`${state} native authority holds legacy sync extraction and application`, async () => {
    useBrowser.setState({ bookmarksReady: { default: true } });
    globalThis.acTestBookmarkWriter = { state: () => ({ state }) };
    const before = JSON.stringify(useBrowser.getState().bookmarks);
    const adapter = bookmarksAdapter("default");
    assert.equal(adapter.extract(() => undefined), null);
    assert.equal(await adapter.apply(new Map()), false);
    assert.equal(JSON.stringify(useBrowser.getState().bookmarks), before);
  });
}

test("a legacy adapter opened before native selection stops publishing and applying", async () => {
  useBrowser.setState({ bookmarksReady: { default: true } });
  const adapter = bookmarksAdapter("default");
  assert.notEqual(adapter.extract(() => undefined), null);
  globalThis.acTestBookmarkWriter = { state: () => ({ state: "starting" }) };
  assert.equal(adapter.extract(() => undefined), null);
  assert.equal(await adapter.apply(new Map()), false);
});
