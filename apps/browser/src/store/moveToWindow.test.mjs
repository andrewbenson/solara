import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("./browser.ts");

const S = () => useBrowser.getState();
const urls = (w) => S().windows[w].tabIds.map((id) => S().tabs[id].url);

function windows(position) {
  S().hydrate({});
  S().updateSettings({ newTabPosition: position });
  const a = S().createWindow({ url: "https://moving.com" });
  const [moving] = S().windows[a].tabIds;
  S().newTab(a, { url: "https://stays.com" });
  const b = S().createWindow({ url: "https://b1.com" });
  const [b1] = S().windows[b].tabIds;
  const b2 = S().newTab(b, { url: "https://b2.com" });
  const b3 = S().newTab(b, { url: "https://b3.com" });
  return { a, b, moving, b1, b2, b3 };
}

test("with new tabs at the bottom, a moved tab lands at the bottom", () => {
  const { b, moving } = windows("bottom");
  S().moveTabsToWindow([moving], b);
  assert.deepEqual(urls(b), ["https://b1.com", "https://b2.com", "https://b3.com", "https://moving.com"]);
  assert.equal(S().windows[b].activeTabIds.default, moving);
});

test("with new tabs at the top, a moved tab lands at the top of the list", () => {
  const { b, moving } = windows("top");
  S().moveTabsToWindow([moving], b);
  assert.equal(urls(b)[0], "https://moving.com");
  assert.equal(S().windows[b].activeTabIds.default, moving);
});

test("with new tabs next to the current one, a moved tab lands after the window's current tab", () => {
  const { b, moving, b1 } = windows("nextToCurrent");
  S().activate(b1);
  S().moveTabsToWindow([moving], b);
  assert.deepEqual(urls(b).slice(0, 2), ["https://b1.com", "https://moving.com"]);
  assert.equal(S().windows[b].activeTabIds.default, moving);
});

test("with new tabs next to the current one, a tab moved beside a grouped current tab joins its group, as a new tab does", () => {
  const { b, moving, b1, b2 } = windows("nextToCurrent");
  const groupId = S().groupTabs([b1, b2], { pinned: false });
  S().activate(b1);
  const fresh = S().newTab(b, { url: "https://fresh.com", newTabCommand: true });
  const group = () => Object.values(S().groups).find((g) => g.tabIds.includes(b1));
  assert.ok(group()?.tabIds.includes(fresh), "a new tab joins the group");
  S().closeTab(fresh);
  S().activate(b1);
  S().moveTabsToWindow([moving], b);
  assert.deepEqual(group()?.tabIds, [b1, moving, b2]);
  assert.deepEqual(urls(b).slice(0, 3), ["https://b1.com", "https://moving.com", "https://b2.com"]);
  assert.ok(groupId !== undefined);
});

test("several moved tabs keep their order where a new tab would open", () => {
  S().hydrate({});
  S().updateSettings({ newTabPosition: "top" });
  const a = S().createWindow({ url: "https://m1.com" });
  const [m1] = S().windows[a].tabIds;
  const m2 = S().newTab(a, { url: "https://m2.com" });
  S().newTab(a, { url: "https://stays.com" });
  const b = S().createWindow({ url: "https://b1.com" });
  S().moveTabsToWindow([m1, m2], b);
  assert.deepEqual(urls(b), ["https://m1.com", "https://m2.com", "https://b1.com"]);
});

test("merging all windows still appends the other windows' tabs after the window's own", () => {
  const { a, b } = windows("top");
  const own = urls(b);
  const others = urls(a);
  S().mergeAllWindows(b);
  assert.deepEqual(urls(b), [...own, ...others]);
});
