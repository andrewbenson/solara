import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("./browser.ts");
const model = await import("./model.ts");
const { closeNewTabBar, openFromNewTabBar, toggleNewTabBar } = await import("../components/omnibox/newTabBar.ts");

const S = () => useBrowser.getState();
const reset = (newTabOpens = "page") => {
  S().hydrate({});
  S().updateSettings({ newTabOpens, newTabPosition: "bottom", cmdClickCreatesTabGroup: false });
};
const urlOf = (id) => S().tabs[id]?.url;
const list = (w) => S().windows[w].tabIds.filter((id) => !S().tabs[id].pinned).map(urlOf);
const panel = (w) => S().windowUi[w]?.panel ?? { open: false };

function windowWith(...hosts) {
  const w = S().createWindow({ url: `https://${hosts[0]}.com/` });
  const ids = [S().windows[w].tabIds[0]];
  for (const h of hosts.slice(1)) ids.push(S().newTab(w, { url: `https://${h}.com/` }));
  S().activate(ids[0]);
  return { w, ids };
}

test("setting off: no bar, and the last tab leaves a New Tab page in its window", () => {
  reset();
  const { w, ids: [a] } = windowWith("a", "b");
  assert.equal(toggleNewTabBar(w), false);
  assert.equal(toggleNewTabBar(w, { kind: "group", groupId: S().groupTabs([a], { pinned: false }) }), false);
  assert.equal(panel(w).open, false);
  const solo = S().createWindow({ url: "https://solo.com/" });
  S().closeTab(S().windows[solo].tabIds[0]);
  assert.equal(S().windows[solo].tabIds.length, 1, "the window stays");
  assert.equal(urlOf(model.activeTabId(S(), solo)), "", "with a New Tab page");
});

test("setting on: the bar adds nothing; closing it again leaves everything as it was", () => {
  reset("commandBar");
  const { w, ids: [a] } = windowWith("a", "b");
  const before = { tabs: [...S().windows[w].tabIds], active: model.activeTabId(S(), w), closed: S().closedTabs.length };
  assert.equal(toggleNewTabBar(w), true);
  assert.deepEqual(panel(w), { open: true, initialText: "", newTab: { kind: "list" } });
  assert.deepEqual(S().windows[w].tabIds, before.tabs);
  toggleNewTabBar(w);
  assert.equal(panel(w).open, false, "⌘T again closes it");
  toggleNewTabBar(w);
  closeNewTabBar(w);
  assert.equal(panel(w).open, false, "Esc closes the bar");
  assert.deepEqual(S().windows[w].tabIds, before.tabs, "and nothing else");
  assert.equal(model.activeTabId(S(), w), a);
  assert.equal(S().closedTabs.length, before.closed);
});

for (const [newTabPosition, expected] of [
  ["bottom", ["https://b.com/", "https://c.com/", "https://picked.com/"]],
  ["top", ["https://picked.com/", "https://b.com/", "https://c.com/"]],
]) {
  test(`a pick makes one selected unpinned tab where new tabs go (${newTabPosition}), outside the selected tab's group`, () => {
    reset("commandBar");
    const { w, ids: [a, b] } = windowWith("a", "b", "c");
    S().updateSettings({ newTabPosition });
    S().pinTabs([a], true);
    S().activate(b);
    S().groupTabs([b], { pinned: false });
    toggleNewTabBar(w);
    openFromNewTabBar(w, panel(w).newTab, "https://picked.com/");
    openFromNewTabBar(w, { kind: "list" }, "https://twice.com/");
    const picked = model.activeTabId(S(), w);
    assert.equal(urlOf(picked), "https://picked.com/");
    assert.deepEqual(list(w), expected, "one tab, placed as Add new tabs says");
    assert.equal(S().tabs[picked].pinned, false);
    assert.equal(Object.values(S().groups).some((g) => g.tabIds.includes(picked)), false);
    assert.equal(panel(w).open, false);
  });
}

test("⌥⌘T in a group: the pick goes into the group", () => {
  reset("commandBar");
  const { w, ids: [a] } = windowWith("a", "b");
  const group = S().groupTabs([a], { pinned: false });
  S().activate(a);
  toggleNewTabBar(w, { kind: "group", groupId: group });
  assert.deepEqual(panel(w).newTab, { kind: "group", groupId: group });
  assert.equal(S().groups[group].tabIds.length, 1);
  openFromNewTabBar(w, panel(w).newTab, "https://in-group.com/");
  assert.deepEqual(S().groups[group].tabIds.map(urlOf), ["https://a.com/", "https://in-group.com/"]);
  assert.equal(urlOf(model.activeTabId(S(), w)), "https://in-group.com/");
});

test("closing the last tab leaves an empty window whose pick fills it; ⌘W there closes the window", () => {
  reset("commandBar");
  const { w, ids: [a] } = windowWith("a");
  S().closeTab(a);
  assert.ok(S().windows[w], "the window stays");
  const empty = model.activeTabId(S(), w);
  assert.equal(urlOf(empty), "");
  assert.equal(S().windows[w].tabIds.length, 1);
  toggleNewTabBar(w);
  assert.deepEqual(panel(w).newTab, { kind: "into", tabId: empty });
  openFromNewTabBar(w, panel(w).newTab, "https://filled.com/");
  assert.deepEqual(S().windows[w].tabIds, [empty]);
  assert.equal(urlOf(empty), "https://filled.com/");
  S().closeTab(empty);
  const again = model.activeTabId(S(), w);
  S().closeTab(again);
  assert.equal(S().windows[w], undefined);
});

test("a blank pinned tab is never the empty card a pick fills", () => {
  reset("commandBar");
  const { w, ids: [a] } = windowWith("a");
  const blank = S().newTab(w);
  S().pinTabs([blank], true);
  S().activate(blank);
  toggleNewTabBar(w);
  assert.deepEqual(panel(w).newTab, { kind: "list" });
  openFromNewTabBar(w, panel(w).newTab, "https://new.com/");
  assert.equal(S().tabs[blank].url, "");
  assert.equal(S().tabs[blank].pinned, true);
});
