import "../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import('../../store/browser.ts');
const { currentBarActions } = await import('./actions.ts');

const S = () => useBrowser.getState();

function setup() {
  S().hydrate({});
  const w = S().createWindow({ url: "https://start.example/" });
  const work = S().createProfile({ name: "Work" });
  return { w, work };
}

test("the bar's actions follow the store: bookmark, mute, pin, profile name", () => {
  const { w, work } = setup();
  const titles = () => currentBarActions(w).map((a) => a.title);
  const tab = S().windows[w].tabIds[0];
  assert.ok(titles().includes("Bookmark This Page"));
  S().toggleBookmark("default", { url: "https://start.example/", title: "Start", favicon: null });
  assert.ok(titles().includes("Remove Bookmark"), "bookmarked");
  S().toggleBookmark("default", { url: "https://start.example/", title: "Start", favicon: null });
  assert.ok(titles().includes("Bookmark This Page"), "unbookmarked");
  S().updateTab(tab, { muted: true });
  assert.ok(titles().includes("Unmute Site"), "muted");
  S().togglePin(tab);
  assert.ok(titles().includes("Unpin from Top Apps"), "pinned");
  S().updateProfile(work, { name: "Office" });
  assert.ok(titles().includes("Switch to Office"), "a renamed profile");

});
