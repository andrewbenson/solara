import type { BrowserCommand } from "@solara/shell";
import type { BrowserState } from "../../store/browser";
import { activeTabId, pinSection, pinnedSectionTitle, plural } from "../../store/model";
import { selectedTabIds } from "../../store/organize";
import { tidyPins } from "./tidyPinsUi";

export function runSidebarCommand(command: BrowserCommand, _arg: string | null, windowId: string): boolean {
  if (command !== "tidyPins") return false;
  tidyPins(windowId);
  return true;
}

export function sidebarMenuState(s: BrowserState, windowId: string | undefined) {
  const disabled: string[] = [];
  const titles: Record<string, string> = {};
  const tab = windowId ? s.tabs[activeTabId(s, windowId) ?? ""] : undefined;
  if (windowId) {
    titles.togglePinnedRow = tab?.pinned ? "Move out of Pinned" : `Move to ${pinnedSectionTitle(s, tab)}`;
    const selected = selectedTabIds(s, windowId).filter((id) => pinSection(s.tabs[id]) !== "tile");
    if (!selected.length) disabled.push("newGroupWithTabs");
    if (selected.length > 1) titles.newGroupWithTabs = `New Group with ${plural(selected.length, "Tab")}`;
  }
  return { disabled, titles };
}
