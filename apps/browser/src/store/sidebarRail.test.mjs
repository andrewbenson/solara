import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.__DEV__ = false;
globalThis.acTestNativeModules = {
  SolaraApp: { sidebarRail: true },
  SolaraHosted: { kinds: () => ["sidebar.shell"] },
  SolaraWindowShell: { active: () => true },
  SolaraProfilePager: { active: () => true, addListener: () => ({ remove() {} }) },
};
const { useBrowser } = await import("./browser.ts");
const rail = await import("./sidebarRail.ts");
const { addressBarInSidebar } = await import("../components/layout/windowLayout.ts");
const { flushPersistence, loadSession, startPersistence } = await import("../lib/persist.ts");
const stub = await import("../test-native/index.ts");
const { asSyncOrigin } = await import("./syncOrigin.ts");

const S = () => useBrowser.getState();

test("the rail is off by default and the sidebar is its saved width", () => {
  S().hydrate({});
  const windowId = S().createWindow({ url: "example.com" });
  assert.equal(S().settings.sidebarIconsOnly, false);
  assert.equal(rail.sidebarWidthOf(S().windows[windowId], S().settings, true), 190);
  S().updateSettings({ sidebarWidth: 240 });
  assert.equal(rail.sidebarWidthOf(S().windows[windowId], S().settings, true), 240);
});

test("the rail is as wide as the traffic lights need and never overwrites the full width", () => {
  S().hydrate({});
  const windowId = S().createWindow({ url: "example.com" });
  S().updateSettings({ sidebarWidth: 240 });
  rail.setSidebarIconsOnly(windowId, true);
  assert.equal(rail.sidebarWidthOf(S().windows[windowId], S().settings, true), rail.SIDEBAR_RAIL_WIDTH);
  assert.equal(S().settings.sidebarWidth, 240);
  rail.toggleSidebarIconsOnly(windowId);
  assert.equal(S().settings.sidebarIconsOnly, false);
  assert.equal(rail.sidebarWidthOf(S().windows[windowId], S().settings, true), 240);
});

test("the rail width holds the three lights plus Dia's 6 pt after them", () => {
  assert.ok(rail.SIDEBAR_RAIL_WIDTH >= 70.75 + 7 + 6);
  assert.ok(rail.SIDEBAR_RAIL_WIDTH < 160);
});

test("committing a full width from the rail leaves the rail", () => {
  S().hydrate({});
  const windowId = S().createWindow({ url: "example.com" });
  rail.setSidebarIconsOnly(windowId, true);
  rail.commitSidebarWidth(windowId, 220);
  assert.equal(S().settings.sidebarIconsOnly, false);
  assert.equal(S().settings.sidebarWidth, 220);
});

test("the address bar leaves a sidebar shown as the rail", () => {
  S().hydrate({});
  const windowId = S().createWindow({ url: "example.com" });
  const w = windowId;
  S().updateSettings({ addressBar: "sidebar", tabLayout: "sidebar" });
  assert.equal(addressBarInSidebar(S(), w), true);
  rail.setSidebarIconsOnly(windowId, true);
  assert.equal(addressBarInSidebar(S(), w), false);
  assert.equal(S().settings.addressBar, "sidebar");
  rail.setSidebarIconsOnly(windowId, false);
  assert.equal(addressBarInSidebar(S(), w), true);
});

test("the rail survives a relaunch with the full width beside it", () => {
  stub.docs.clear();
  S().hydrate({});
  const stop = startPersistence();
  const windowId = S().createWindow({ url: "a.com" });
  S().updateSettings({ sidebarWidth: 260 });
  rail.setSidebarIconsOnly(windowId, true);
  flushPersistence();
  S().hydrate({});
  assert.equal(S().settings.sidebarIconsOnly, false);
  S().hydrate(loadSession());
  assert.equal(S().settings.sidebarIconsOnly, true);
  assert.equal(S().settings.sidebarWidth, 260);
  assert.equal(rail.sidebarWidthOf(S().windows[windowId], S().settings, true), rail.SIDEBAR_RAIL_WIDTH);
  stop();
  stub.docs.clear();
});

const railSettings = { sidebarWidth: 240, sidebarIconsOnly: true };

test("an unsupported native build keeps the full width", () => {
  assert.equal(rail.sidebarWidthOf(undefined, railSettings, true, false), 240);
  assert.equal(railSettings.sidebarIconsOnly, true);
});

test("the React Native fallback keeps the full width even on a supported build", () => {
  assert.equal(rail.sidebarWidthOf(undefined, railSettings, false, true), 240);
  assert.equal(railSettings.sidebarIconsOnly, true);
});

test("the supported native shell uses the rail", () => {
  assert.equal(rail.sidebarWidthOf(undefined, railSettings, true, true), 84);
});

test("fallback resize preserves the rail preference and full saved width", () => {
  S().hydrate({});
  const windowId = S().createWindow({ url: "example.com" });
  S().updateSettings({ sidebarWidth: 240, sidebarIconsOnly: true });
  const start = rail.sidebarWidthOf(S().windows[windowId], S().settings, false);
  assert.equal(start, 240);
  rail.commitSidebarWidth(windowId, start, false);
  assert.equal(S().settings.sidebarWidth, 240);
  assert.equal(S().settings.sidebarIconsOnly, true);
});

test("window sidebar changes pin inherited peers and seed new windows", () => {
  S().hydrate({});
  S().updateSettings({ sidebarWidth: 248, extensionSidePanelWidth: 390 });
  const w1 = S().createWindow({ url: "a.com" });
  const w2 = S().createWindow({ url: "b.com" });
  rail.setWindowSidebar(w1, { sidebarWidth: 290, sidePanelWidth: 460 });
  assert.equal(S().windows[w1].sidebarWidth, 290);
  assert.equal(S().windows[w2].sidebarWidth, 248);
  assert.equal(S().windows[w2].sidePanelWidth, 390);
  assert.equal(rail.sidebarWidthOf(S().windows[w2], S().settings, true), 248);
  assert.equal(rail.sidePanelWidthOf(S().windows[w2], S().settings), 390);
  const w3 = S().createWindow({ url: "c.com" });
  assert.equal(S().windows[w3].sidebarWidth, undefined);
  assert.equal(rail.sidebarWidthOf(S().windows[w3], S().settings, true), 290);
  assert.equal(rail.sidePanelWidthOf(S().windows[w3], S().settings), 460);
});

test("window icons-only stays local while Settings resets every override", () => {
  S().hydrate({});
  const w1 = S().createWindow({ url: "a.com" });
  const w2 = S().createWindow({ url: "b.com" });
  rail.setSidebarIconsOnly(w1, true);
  assert.equal(S().windows[w1].sidebarIconsOnly, true);
  assert.equal(S().windows[w2].sidebarIconsOnly, false);
  S().updateSettings({ sidebarIconsOnly: false }, { fromSync: true });
  assert.equal(S().windows[w1].sidebarIconsOnly, true);
  assert.equal(S().windows[w2].sidebarIconsOnly, false);
  asSyncOrigin(() => S().updateSettings({ sidebarIconsOnly: true }));
  assert.equal(S().windows[w1].sidebarIconsOnly, true);
  assert.equal(S().windows[w2].sidebarIconsOnly, false);
  S().updateSettings({ sidebarIconsOnly: true });
  assert.equal(Object.hasOwn(S().windows[w1], "sidebarIconsOnly"), false);
  assert.equal(Object.hasOwn(S().windows[w2], "sidebarIconsOnly"), false);
  assert.equal(rail.sidebarIconsOnlyOf(S().windows[w2], S().settings), true);
});

test("legacy windows inherit saved widths without gaining overrides", () => {
  S().hydrate({});
  const w = S().createWindow({ url: "example.com" });
  const saved = JSON.parse(JSON.stringify({ windows: S().windows, tabs: S().tabs, windowOrder: S().windowOrder, settings: { ...S().settings, sidebarWidth: 272, extensionSidePanelWidth: 422 } }));
  S().hydrate(saved);
  assert.equal(rail.sidebarWidthOf(S().windows[w], S().settings, true), 272);
  assert.equal(rail.sidePanelWidthOf(S().windows[w], S().settings), 422);
  assert.equal(Object.hasOwn(S().windows[w], "sidebarWidth"), false);
  assert.equal(Object.hasOwn(S().windows[w], "sidebarIconsOnly"), false);
  assert.equal(Object.hasOwn(S().windows[w], "sidePanelWidth"), false);
});

test("reopening a closed window preserves layout and sidebar overrides", () => {
  S().hydrate({});
  const w = S().createWindow({ url: "example.com" });
  S().setWindowSidebar(w, { sidebarWidth: 281, sidebarIconsOnly: true, sidePanelWidth: 471 });
  useBrowser.setState((s) => ({ windows: { ...s.windows, [w]: { ...s.windows[w], tabLayout: "top", fullScreen: 123 } } }));
  S().closeWindow(w);
  const entry = JSON.parse(JSON.stringify(S().closedWindows[0]));
  assert.equal(entry.window.sidebarWidth, 281);
  S().updateSettings({ sidebarWidth: 198, sidebarIconsOnly: false, extensionSidePanelWidth: 361 });
  S().reopenClosedWindow();
  const restored = S().windows[S().windowOrder[0]];
  assert.equal(restored.sidebarWidth, 281);
  assert.equal(restored.sidebarIconsOnly, true);
  assert.equal(restored.sidePanelWidth, 471);
  assert.equal(restored.tabLayout, "top");
  assert.equal(restored.fullScreen, 123);
});

test("Little Solara is not pinned or changed by window sidebar writes", () => {
  S().hydrate({});
  const w = S().createWindow({ url: "example.com" });
  const small = S().createWindow({ small: true, url: "small.com" });
  S().setWindowSidebar(w, { sidebarWidth: 281, sidebarIconsOnly: true, sidePanelWidth: 471 });
  assert.equal(S().windows[small].sidebarWidth, undefined);
  assert.equal(S().windows[small].sidebarIconsOnly, undefined);
  assert.equal(S().windows[small].sidePanelWidth, undefined);
  S().setWindowSidebar(small, { sidebarWidth: 210 });
  assert.equal(S().settings.sidebarWidth, 281);
});
