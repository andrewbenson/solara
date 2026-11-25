import type { BrowserCommand, MenuEntry } from "@solara/shell";
import { useBrowser, type BrowserState } from "../../store/browser";
import { activeTabId, pinSection, plural } from "../../store/model";
import { awayFromPin, groupOf, selectedTabIds } from "../../store/organize";
import { newGroupWithSelection, openIconPicker, startRename } from "./actions";
import { closeAllTabs } from "./menus";
import { toggleNewTabBar } from "../omnibox/newTabBar";
import { movePinnedTitle, togglePinnedRows } from "./movePinned";
import { tidyPins } from "./tidyPinsUi";

export function runSidebarCommand(command: BrowserCommand, arg: string | null, windowId: string): boolean {
  const s = useBrowser.getState();
  const tabId = activeTabId(s, windowId);
  switch (command) {
    case "newTabInGroup": {
      const group = groupOf(s, tabId);
      if (toggleNewTabBar(windowId, group ? { kind: "group", groupId: group.id } : undefined)) return true;
      const id = group ? s.newTabInGroup(group.id) : s.newTab(windowId, { newTabCommand: true });
      if (id) useBrowser.getState().activate(id);
      return true;
    }
    case "newGroupWithTabs":
      newGroupWithSelection(windowId);
      return true;
    case "cleanUpTabs":
      s.cleanUpTabs(windowId);
      return true;
    case "closeAllTabs":
      closeAllTabs(windowId);
      return true;
    case "tidyPins":
      tidyPins(windowId);
      return true;
    case "renameTab":
      if (tabId) void startRename(windowId, { kind: "tab", id: tabId });
      return true;
    case "changeTabIcon":
      if (tabId) void openIconPicker(windowId, { kind: "tab", id: tabId });
      return true;
    case "togglePinnedRow":
      togglePinnedRows(windowId);
      return true;
    case "returnToPinnedUrl":
      if (tabId) s.returnToPinnedUrl(tabId);
      return true;
  }
  return false;
}

export function sidebarMenuState(s: BrowserState, windowId: string | undefined) {
  const disabled: string[] = [];
  const titles: Record<string, string> = {};
  const tab = windowId ? s.tabs[activeTabId(s, windowId) ?? ""] : undefined;
  if (windowId) {
    if (!tab || !awayFromPin(tab)) disabled.push("returnToPinnedUrl");
    titles.togglePinnedRow = movePinnedTitle(s, tab);
    const selected = selectedTabIds(s, windowId).filter((id) => pinSection(s.tabs[id]) !== "tile");
    if (!selected.length) disabled.push("newGroupWithTabs");
    if (selected.length > 1) titles.newGroupWithTabs = `New Group with ${plural(selected.length, "Tab")}`;
  }
  const recentlyClosedGroups: MenuEntry[] = [...s.closedGroups]
    .reverse()
    .slice(0, 10)
    .map((c) => ({ id: c.id, title: `${c.group.name} (${plural(c.tabs.length, "Tab")})` }));
  return { disabled, titles, recentlyClosedGroups };
}
