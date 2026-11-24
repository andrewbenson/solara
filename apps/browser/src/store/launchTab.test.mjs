import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.__DEV__ = false;
const { useBrowser } = await import("./browser.ts");
const { launchTab } = await import("./launchTab.ts");

const S = () => useBrowser.getState();
const tab = (id, windowId, url, profileId = "default") => ({
  id, windowId, profileId, url, title: "", favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null,
  pinnedUrl: null, navigation: null, openerId: null, createdAt: 0, lastActiveAt: 0,
});
const win = (id, tabIds, active, extra = {}) => ({
  id, profileId: "default", incognito: false, tabIds, activeTabIds: { default: active }, sidebarOpen: true, frame: null, createdAt: 0, ...extra,
});
const PROFILES = {
  default: { id: "default", name: "Personal", color: "plum", icon: null, createdAt: 0 },
  work: { id: "work", name: "Work", color: "blue", icon: null, createdAt: 0 },
};
const hydrate = (windows, tabs, extra = {}) =>
  S().hydrate({ profiles: PROFILES, windows: Object.fromEntries(windows.map((w) => [w.id, w])), tabs: Object.fromEntries(tabs.map((t) => [t.id, t])), ...extra });

test("the focused window's active web page, under its engine profile", () => {
  hydrate([win("w1", ["a", "b"], "b"), win("w2", ["c"], "c")], [tab("a", "w1", "https://a.com/"), tab("b", "w1", "https://b.com/x"), tab("c", "w2", "http://c.com/")], { focusedWindowId: "w1" });
  assert.deepEqual(launchTab(S(), S().ui.focusedWindowId), { id: "b", url: "https://b.com/x", profile: "" });
  assert.deepEqual(launchTab(S(), "w2"), { id: "c", url: "http://c.com/", profile: "" });
  assert.equal(S().tabs.b.navigation?.url, "https://b.com/x");
});

test("another profile's tab names that profile's engine profile", () => {
  hydrate([win("w1", ["a"], null, { profileId: "work", activeTabIds: { work: "a" } })], [tab("a", "w1", "https://a.com/", "work")], { focusedWindowId: "w1" });
  assert.deepEqual(launchTab(S(), "w1"), { id: "a", url: "https://a.com/", profile: "work" });
});

test("nothing for a page the engine doesn't load at launch", () => {
  for (const url of ["", "about:blank", "solara://history", "chrome://settings", "file:///tmp/x.html", "javascript:alert(1)"]) {
    hydrate([win("w1", ["a"], "a")], [tab("a", "w1", url)], { focusedWindowId: "w1" });
    assert.equal(launchTab(S(), "w1"), null, url);
  }
  hydrate([win("w1", ["a"], "a")], [tab("a", "w1", "https://a.com/")], { focusedWindowId: "w1" });
  assert.equal(launchTab(S(), null), null, "no focused window");
  assert.equal(launchTab(S(), "gone"), null);
  assert.equal(launchTab({ ...S(), settings: { ...S().settings, restoreSession: false } }, "w1"), null, "a session the user doesn't restore");
  assert.equal(launchTab({ ...S(), windows: { w1: { ...S().windows.w1, incognito: true } } }, "w1"), null, "private");
  assert.equal(launchTab({ ...S(), windows: { w1: { ...S().windows.w1, kind: "small" } } }, "w1"), null, "Little Solara");
});

test("a reopened tab wakes with its back/forward list before becoming a launch hint", () => {
  const waking = (id, wakeAdoptId, profileId) => ({ ...tab(id, "w1", `https://${id}.com/`, profileId), wakeAdoptId });
  hydrate(
    [win("w1", ["a", "b", "c", "p"], "a")],
    [tab("a", "w1", "https://a.com/"), waking("b", "restore:old-b"), waking("c", "tab:42"), waking("p", "restore:old-p", "incognito:w9@default")],
    { focusedWindowId: "w1" },
  );
  S().activate("b");
  assert.equal(S().tabs.b.adoptId, "restore:old-b", "shown, it wakes with its list");
  S().setFocusedWindow("w1");
  assert.deepEqual(launchTab(S(), "w1"), { id: "b", url: "https://b.com/", profile: "" }, "woken, the next launch loads it by its address");
  S().updateTab("b", { adoptId: undefined, wakeAdoptId: "restore:old-b" });
  assert.equal(launchTab(S(), "w1"), null, "not woken yet: it keeps its list");
});

test("a tab the engine made retains its adoption token", () => {
  hydrate([win("w1", ["a"], "a")], [tab("a", "w1", "https://a.com/")], { focusedWindowId: "w1" });
  const id = S().newTab("w1", { url: "https://made.example/page", adoptId: "tab:7" });
  assert.equal(S().tabs[id].adoptId, "tab:7");
});
