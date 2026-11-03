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
const { sidebarWidthOf } = await import("./sidebarRail.ts");
const { nativeSidebarShell } = await import("../components/sidebar/sidebarShell.ts");
const { setPeekShown, peekShown, overPeek, PEEK_ORIGIN } = await import("../components/layout/dockMotion.ts");

const S = () => useBrowser.getState();

function hiddenRail() {
  S().hydrate({});
  const windowId = S().createWindow({ url: "https://example.com/" });
  S().updateSettings({ sidebarWidth: 260, sidebarIconsOnly: true });
  S().toggleSidebar(windowId);
  return windowId;
}

test("a hidden native rail gives the edge peek an 84 pt width", () => {
  const windowId = hiddenRail();
  assert.equal(S().windows[windowId].sidebarOpen, false);
  const width = sidebarWidthOf(S().settings, nativeSidebarShell(windowId));
  assert.equal(width, 84);
  setPeekShown(windowId, true, PEEK_ORIGIN[0] + width);
  assert.equal(peekShown(windowId), true);
  assert.equal(overPeek(windowId, PEEK_ORIGIN[0] + 83), true);
  assert.equal(overPeek(windowId, PEEK_ORIGIN[0] + 84), false);
  setPeekShown(windowId, false);
});

test("docking an edge peek keeps the rail and the saved full width", () => {
  const windowId = hiddenRail();
  setPeekShown(windowId, true, PEEK_ORIGIN[0] + sidebarWidthOf(S().settings, nativeSidebarShell(windowId)));
  S().toggleSidebar(windowId);
  assert.equal(S().windows[windowId].sidebarOpen, true);
  assert.equal(S().settings.sidebarIconsOnly, true);
  assert.equal(S().settings.sidebarWidth, 260);
  assert.equal(sidebarWidthOf(S().settings, nativeSidebarShell(windowId)), 84);
  setPeekShown(windowId, false);
});
