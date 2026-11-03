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

const S = () => useBrowser.getState();

test("the rail is off by default and the sidebar is its saved width", () => {
  S().hydrate({});
  assert.equal(S().settings.sidebarIconsOnly, false);
  assert.equal(rail.sidebarWidthOf(S().settings, true), 190);
  S().updateSettings({ sidebarWidth: 240 });
  assert.equal(rail.sidebarWidthOf(S().settings, true), 240);
});

test("the rail is as wide as the traffic lights need and never overwrites the full width", () => {
  S().hydrate({});
  S().updateSettings({ sidebarWidth: 240 });
  rail.setSidebarIconsOnly(true);
  assert.equal(rail.sidebarWidthOf(S().settings, true), rail.SIDEBAR_RAIL_WIDTH);
  assert.equal(S().settings.sidebarWidth, 240);
  rail.toggleSidebarIconsOnly();
  assert.equal(S().settings.sidebarIconsOnly, false);
  assert.equal(rail.sidebarWidthOf(S().settings, true), 240);
});

test("the rail width holds the three lights plus Dia's 6 pt after them", () => {
  assert.ok(rail.SIDEBAR_RAIL_WIDTH >= 70.75 + 7 + 6);
  assert.ok(rail.SIDEBAR_RAIL_WIDTH < 160);
});

test("committing a full width from the rail leaves the rail", () => {
  S().hydrate({});
  rail.setSidebarIconsOnly(true);
  rail.commitSidebarWidth(220);
  assert.equal(S().settings.sidebarIconsOnly, false);
  assert.equal(S().settings.sidebarWidth, 220);
});

test("the address bar leaves a sidebar shown as the rail", () => {
  S().hydrate({});
  const w = S().createWindow({ url: "a.com" });
  S().updateSettings({ addressBar: "sidebar", tabLayout: "sidebar" });
  assert.equal(addressBarInSidebar(S(), w), true);
  rail.setSidebarIconsOnly(true);
  assert.equal(addressBarInSidebar(S(), w), false);
  assert.equal(S().settings.addressBar, "sidebar");
  rail.setSidebarIconsOnly(false);
  assert.equal(addressBarInSidebar(S(), w), true);
});

test("the rail survives a relaunch with the full width beside it", () => {
  stub.docs.clear();
  S().hydrate({});
  const stop = startPersistence();
  S().createWindow({ url: "a.com" });
  S().updateSettings({ sidebarWidth: 260 });
  rail.setSidebarIconsOnly(true);
  flushPersistence();
  S().hydrate({});
  assert.equal(S().settings.sidebarIconsOnly, false);
  S().hydrate(loadSession());
  assert.equal(S().settings.sidebarIconsOnly, true);
  assert.equal(S().settings.sidebarWidth, 260);
  assert.equal(rail.sidebarWidthOf(S().settings, true), rail.SIDEBAR_RAIL_WIDTH);
  stop();
  stub.docs.clear();
});

const railSettings = { sidebarWidth: 240, sidebarIconsOnly: true };

test("an unsupported native build keeps the full width", () => {
  assert.equal(rail.sidebarWidthOf(railSettings, true, false), 240);
  assert.equal(railSettings.sidebarIconsOnly, true);
});

test("the React Native fallback keeps the full width even on a supported build", () => {
  assert.equal(rail.sidebarWidthOf(railSettings, false, true), 240);
  assert.equal(railSettings.sidebarIconsOnly, true);
});

test("the supported native shell uses the rail", () => {
  assert.equal(rail.sidebarWidthOf(railSettings, true, true), 84);
});

test("fallback resize preserves the rail preference and full saved width", () => {
  S().hydrate({});
  S().updateSettings({ sidebarWidth: 240, sidebarIconsOnly: true });
  const start = rail.sidebarWidthOf(S().settings, false);
  assert.equal(start, 240);
  rail.commitSidebarWidth(start, false);
  assert.equal(S().settings.sidebarWidth, 240);
  assert.equal(S().settings.sidebarIconsOnly, true);
});
