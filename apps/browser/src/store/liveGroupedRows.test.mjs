import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("./browser.ts");
const { sidebarEntries, numberedTabs } = await import("../components/sidebar/entries.ts");

const S = () => useBrowser.getState();

test("a Live Folder tab moved into a group is a group row, even as its only member", () => {
  S().hydrate({});
  const w = S().createWindow({ url: "https://first.com/" });
  const live = S().newTab(w, { index: 1, url: "https://doc.com/", background: true });
  S().updateTab(live, { liveItem: { folderId: "f1", itemId: "gone" } });
  assert.deepEqual(numberedTabs(S(), w).includes(live), false, "ungrouped, it belongs to the folder");
  const g = S().groupTabs([live], { pinned: false, name: "Group" });
  assert.equal(sidebarEntries(S(), w).list.includes(`g:${g}`), true);
  assert.equal(numberedTabs(S(), w).includes(live), true);
});
