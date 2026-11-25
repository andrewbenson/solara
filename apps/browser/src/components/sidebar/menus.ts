import { nativeWorkspaceCommand } from "@solara/settings";
import { showMenu, type MenuItem } from "@solara/shell";
import { closeGroup, closeTab, closeTabs, moveTabToProfile, moveTabToWindow, switchToTab, toggleMute } from "../../lib/actions";
import { moveGroupToBookmarksBar } from "../../lib/bookmarkGroups";
import { reportBookmarkFailure } from "../../lib/bookmarkWriter";
import { menuShortcut } from "../../lib/commandShortcuts";
import { folderChildren } from "../../store/bookmarks";
import { useBrowser } from "../../store/browser";
import { bookmarkProfileId, inPinnedContainer, plural, tabLabel, viewTabIds } from "../../store/model";
import { canUndoClear, cleanedTabsFor, keptDeletedGroups, selectedTabIds, type ClearedTabs } from "../../store/organize";
import type { GroupColor, Tab } from "../../store/types";
import {
  allMuted,
  bookmarkTabs,
  editPinnedPage,
  muteAll,
  newGroupWithSelection,
  openIconPicker,
  startRename,
  tabTitle,
} from "./actions";
import { isCalendarUrl } from "../../live/meetings";
import { bookmarkTab } from "../bookmarks/actions";
import { hideKeyedToast, showToast, useToasts } from "../layout/splitActions";
import { calendarMenuItem, newLiveFolderMenuItem, runCalendarMenu, runNewLiveFolder } from "./liveMenus";
import { openSyncedTab, syncedDevicesMenuItem } from "../../sync/menu";
import { setSidebarUi } from "./state";
import { hasOwnGroupIcon } from "./TabIcon";
import { newFolderWithTab, removeFromFolder } from "./tileFolderUi";
import { toggleNewTabBar } from "../omnibox/newTabBar";
import { togglePageEngine } from "../../lib/engines";
import { GROUP_COLORS, NEUTRAL_GROUP_SWATCH, nearestGroupColor, type GroupTint } from "./tokens";

import { multiTabMenuItems, tabMenuItems } from "./tabMenuPlan";

import { setSidebarPosition, sidebarPositionOf, sidebarPositionSupported } from "../../store/sidebarRail";

const store = () => useBrowser.getState();
const sep = { separator: true } as const;

function bookmarkFolderItems(windowId: string, prefix: string): MenuItem[] {
  const s = store();
  const roots = s.bookmarks.roots[bookmarkProfileId(s, s.windows[windowId])];
  const folders = roots
    ? [...folderChildren(s.bookmarks, roots.bar), ...folderChildren(s.bookmarks, roots.other)].filter((n) => n.kind === "folder")
    : [];
  return [
    { id: `${prefix}bar`, title: "Bookmarks Bar", symbol: "menubar.rectangle" },
    ...(roots ? [{ id: `${prefix}${roots.other}`, title: "Other Bookmarks", symbol: "folder" }] : []),
    ...folders.map((f) => ({ id: `${prefix}${f.id}`, title: f.title, symbol: "folder" })),
    sep,
    { id: `${prefix}new`, title: "New Folder…", symbol: "folder.badge.plus" },
  ];
}

export async function openTabMenu(windowId: string, tab: Tab) {
  const s = store();
  const selected = selectedTabIds(s, windowId);
  if (selected.length > 1 && selected.includes(tab.id)) return openMultiMenu(windowId, selected);
  if (s.selection[windowId]?.length) s.setSelection(windowId, []);

  const shortcuts = Object.fromEntries(["copyUrl", "returnToPinnedUrl", "bookmarkPage", "newGroupWithTabs", "closeTab"].map((command) => [command, menuShortcut(command)]));
  const items = tabMenuItems(s, windowId, tab.id, { calendarItem: tab.pinned && isCalendarUrl(tab.pinnedUrl ?? tab.url) ? calendarMenuItem() : undefined, shortcuts });
  if (!items) return;
  const choice = await showMenu(items);
  if (choice) runTabMenuChoice(windowId, tab.id, choice);
}

export function runTabMenuChoice(windowId: string, tabId: string, choice: string) {
  if (choice === "copy") return void nativeWorkspaceCommand("copyUrl", JSON.stringify({ tabId }), windowId);
  if (choice.startsWith("share:via:")) return void nativeWorkspaceCommand("share", JSON.stringify({ tabId, via: choice.slice(10) }), windowId);
  const s = store();
  const tab = s.tabs[tabId];
  if (!tab) return;
  const list = viewTabIds(s, windowId).filter((id) => !inPinnedContainer(s, id));
  const housed = inPinnedContainer(s, tab.id);
  const index = list.indexOf(tab.id);
  const above = housed ? [] : list.slice(0, index);
  const below = housed ? [] : list.slice(index + 1);
  const others = list.filter((id) => id !== tab.id);
  if (!choice) return;
  const t = { kind: "tab" as const, id: tab.id };
  if (runCalendarMenu(choice)) return;
  if (choice === "backToPin") s.returnToPinnedUrl(tab.id);
  else if (choice === "replacePin") s.setPinnedUrl(tab.id);
  else if (choice === "editPin") void editPinnedPage(windowId, tab.id);
  else if (choice === "rename") void startRename(windowId, t);
  else if (choice === "resetName") s.updateTab(tab.id, { customTitle: null });
  else if (choice === "icon") void openIconPicker(windowId, t);
  else if (choice === "resetIcon") s.updateTab(tab.id, { customIcon: null });
  else if (choice === "pin") s.togglePin(tab.id);
  else if (choice === "unpinMember") s.placeTabs([tab.id], { pinned: false, groupId: null });
  else if (choice === "pinTile") s.pinTabs([tab.id], true, false);
  else if (choice === "pinRow") s.pinTabs([tab.id], true, true);
  else if (choice === "newFolder") void newFolderWithTab(windowId, tab.id);
  else if (choice === "leaveFolder") void removeFromFolder(tab.id);
  else if (choice === "duplicate") s.duplicateTab(tab.id);
  else if (choice === "ungroupTab") s.removeTabsFromGroup([tab.id]);
  else if (choice === "newGroup") newGroupWithSelection(windowId, [tab.id]);
  else if (choice.startsWith("group:")) s.placeTabs([tab.id], { pinned: false, groupId: choice.slice(6) });
  else if (choice === "unsplit") s.removeTabFromSplit(tab.id);
  else if (choice === "mute") toggleMute(tab.id);
  else if (choice === "engine") void togglePageEngine(tab.id);
  else if (choice === "bookmark") void bookmarkTab(windowId, tab.id);
  else if (choice.startsWith("profile:")) void moveTabToProfile(tab.id, choice.slice(8));
  else if (choice.startsWith("window:")) moveTabToWindow(tab.id, choice.slice(7));
  else if (choice === "close") void closeTab(tab.id);
  else if (choice === "closeOthers") s.closeTabs(others);
  else if (choice === "closeAbove") s.closeTabs(above);
  else if (choice === "closeBelow") s.closeTabs(below);
}

async function openMultiMenu(windowId: string, ids: string[]) {
  const shortcuts = Object.fromEntries(["copyUrl", "copyUrlAsMarkdown", "newGroupWithTabs", "closeTab"].map((command) => [command, menuShortcut(command)]));
  const choice = await showMenu(multiTabMenuItems(store(), windowId, ids, { folders: bookmarkFolderItems(windowId, "folder:"), shortcuts }));
  if (choice) runTabMenuSelectionChoice(windowId, ids, choice);
}

export function runTabMenuSelectionChoice(windowId: string, ids: string[], choice: string) {
  if (choice === "copy" || choice === "copyMd") return void nativeWorkspaceCommand(choice === "copy" ? "copyUrl" : "copyUrlAsMarkdown", JSON.stringify({ ids }), windowId);
  const s = store();
  if (!choice || !ids.length || ids.some((id) => !s.tabs[id] || s.tabs[id]!.windowId !== windowId)) return;
  const tabs = ids.map((id) => s.tabs[id]!);
  const allPinned = tabs.every((t) => t.pinned);
  if (choice === "pin") s.pinTabs(ids, !allPinned);
  else if (choice === "pinRows") s.pinTabs(ids, true, true);
  else if (choice === "duplicate") ids.forEach((id) => store().duplicateTab(id));
  else if (choice === "newGroup") newGroupWithSelection(windowId, ids);
  else if (choice.startsWith("group:")) s.placeTabs(ids, { pinned: false, groupId: choice.slice(6) });
  else if (choice === "ungroup") s.removeTabsFromGroup(ids);
  else if (choice === "bar") void bookmarkTabs(windowId, ids, "bar");
  else if (choice.startsWith("folder:")) void bookmarkTabs(windowId, ids, choice.slice(7));
  else if (choice.startsWith("window:")) {
    const target = store().moveTabsToWindow(ids, choice === "window:new" ? null : choice.slice(7));
    if (target) switchToTab(store().windows[target]?.activeTabIds[tabs[0]!.profileId] ?? ids[0]!);
  } else if (choice === "close") return void closeTabs(windowId, ids);
  if (choice !== "copy" && choice !== "copyMd") store().setSelection(windowId, []);
}

export async function openGroupMenu(windowId: string, groupId: string) {
  const s = store();
  const g = s.groups[groupId];
  if (!g) return;
  const colors: GroupTint[] = ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"];
  const siteColor = g.tabIds.map((id) => s.live[id]?.themeColor).find(Boolean);
  const matched = siteColor ? nearestGroupColor(siteColor) : null;
  const choice = await showMenu([
    { id: "rename", title: "Rename…", symbol: "character.cursor.ibeam" },
    { id: "icon", title: hasOwnGroupIcon(g.icon) ? "Change Icon…" : "Add Icon…", symbol: "face.smiling" },
    {
      id: "color",
      title: "Color",
      symbol: "paintpalette",
      children: [
        { id: "color:none", title: "None", swatch: "#00000000", checked: g.color === "none" },
        { id: "color:", title: "Neutral", swatch: NEUTRAL_GROUP_SWATCH.light, swatchDark: NEUTRAL_GROUP_SWATCH.dark, checked: !g.color },
        { id: `color:${matched ?? ""}`, title: "Match Site Color", enabled: !!matched, swatch: matched ? GROUP_COLORS[matched].hex : undefined },
        sep,
        ...colors.map((c) => ({ id: `color:${c}`, title: GROUP_COLORS[c].name, swatch: GROUP_COLORS[c].hex, checked: g.color === c })),
      ],
    },
    sep,
    { id: "newTab", title: "New Tab in Group", symbol: "plus", ...menuShortcut("newTabInGroup") },
    { id: "nest", title: "New Nested Group", symbol: "plus.rectangle.on.rectangle" },
    ...(g.parentId ? [] : [{ id: "pin", title: g.pinned ? "Unpin Group" : "Pin Group", symbol: g.pinned ? "pin.slash" : "pin" }]),
    { id: "duplicate", title: "Duplicate Group", symbol: "plus.square.on.square" },
    { id: "collapse", title: g.collapsed ? "Expand Group" : "Collapse Group", symbol: g.collapsed ? "chevron.down" : "chevron.up" },
    sep,
    { id: "copy", title: "Copy All Links", symbol: "link" },
    { id: "copyMd", title: "Copy All Links as Markdown", symbol: "text.badge.checkmark" },
    sep,
    { id: "ungroup", title: "Ungroup", symbol: "folder.badge.minus" },
    { id: "bookmarkBar", title: "Move to Bookmark Bar", symbol: "bookmark" },
    { id: "close", title: "Close Group", symbol: "xmark" },
    { id: "delete", title: "Delete Group", symbol: "trash" },
  ]);
  if (choice) runGroupMenuChoice(windowId, groupId, choice);
}

export function runGroupMenuChoice(windowId: string, groupId: string, choice: string) {
  if (choice === "copy" || choice === "copyMd") return void nativeWorkspaceCommand(choice === "copy" ? "copyUrl" : "copyUrlAsMarkdown", JSON.stringify({ groupId }), windowId);
  const target = { kind: "group" as const, id: groupId };
  if (choice === "rename") return void startRename(windowId, target);
  const s = store();
  const g = s.groups[groupId];
  if (!g) return;
  if (choice === "icon") void openIconPicker(windowId, target);
  else if (choice.startsWith("color:")) s.updateGroup(groupId, { color: (choice.slice(6) || null) as GroupColor | null });
  else if (choice === "newTab") {
    if (toggleNewTabBar(windowId, { kind: "group", groupId })) return;
    const id = s.newTabInGroup(groupId);
    if (id) store().activate(id);
  }
  else if (choice === "nest") {
    const child = s.newNestedGroup(groupId);
    const tabId = store().groups[child]?.tabIds[0];
    if (tabId) store().activate(tabId);
    if (child) void startRename(windowId, { kind: "group", id: child });
  } else if (choice === "pin") s.moveGroup(groupId, { pinned: !g.pinned });
  else if (choice === "duplicate") s.duplicateGroup(groupId);
  else if (choice === "collapse") s.updateGroup(groupId, { collapsed: !g.collapsed });
  else if (choice === "ungroup") s.ungroup(groupId);
  else if (choice === "bookmarkBar") void moveGroupToBookmarksBar(groupId).catch(reportBookmarkFailure);
  else if (choice === "close") void closeGroup(groupId);
  else if (choice === "delete") s.deleteGroup(groupId);
}

export async function openSidebarMenu(windowId: string) {
  const s = store();
  const muted = allMuted(windowId);
  const choice = await showMenu([
    { id: "newTab", title: "New Tab", symbol: "plus", ...menuShortcut("newTab") },
    { id: "search", title: "Search Tabs…", symbol: "magnifyingglass", ...menuShortcut("searchTabs") },
    sep,
    { id: "clean", title: "Clean Up Tabs", symbol: "wand.and.stars", ...menuShortcut("cleanUpTabs") },
    { id: "mute", title: muted ? "Unmute All Tabs" : "Mute All Tabs", symbol: muted ? "speaker.wave.2" : "speaker.slash" },
    { id: "closeAll", title: "Close All Tabs", symbol: "xmark", ...menuShortcut("closeAllTabs") },
    sep,
    ...(sidebarPositionSupported(windowId) ? [{
      id: "sidebarPosition",
      title: "Sidebar Position",
      children: ["left", "right"].map((position) => ({ id: `sidebarPosition:${position}`, title: position === "left" ? "Left" : "Right", checked: sidebarPositionOf(s.windows[windowId], s.settings) === position, enabled: !s.settings.fileOwn?.covered.includes("sidebarPosition") })),
    }] : []),
    newLiveFolderMenuItem(),
  ]);
  if (choice === "sidebarPosition:left" || choice === "sidebarPosition:right") return setSidebarPosition(windowId, choice === "sidebarPosition:right" ? "right" : "left");
  if (choice && runNewLiveFolder(windowId, choice)) return;
  if (choice === "newTab") {
    if (!toggleNewTabBar(windowId)) s.newTab(windowId, { newTabCommand: true });
  }
  else if (choice === "search") setSidebarUi({ searchTabs: windowId });
  else if (choice === "clean") s.cleanUpTabs(windowId);
  else if (choice === "mute") muteAll(windowId, !muted);
  else if (choice === "closeAll") closeAllTabs(windowId);
}

let undoToasts = 0;

export function showUndoToast(cleared: ClearedTabs, title: string, icon: string) {
  const { windowId } = cleared;
  const key = `undo-clear-${++undoToasts}`;
  showToast(windowId, title, undefined, { icon, key, action: { title: "Undo", run: () => store().undoClearTabs(cleared) } });
  let seen: unknown[] = [];
  const stop = () => {
    stopWatchingStore();
    stopWatchingToast();
  };
  const stopWatchingStore = useBrowser.subscribe((s) => {
    const now = [s.windows[windowId], s.tabs, s.groups, s.splits, s.closedTabs];
    if (now.every((x, i) => x === seen[i])) return;
    seen = now;
    if (canUndoClear(s, cleared)) return;
    hideKeyedToast(windowId, key);
    stop();
  });
  const stopWatchingToast = useToasts.subscribe((t) => {
    if (t.toasts[windowId]?.key !== key) stop();
  });
}

export function closeAllTabs(windowId: string) {
  const cleared = store().clearUnpinnedTabs(windowId);
  if (cleared?.entries.length) showUndoToast(cleared, `Cleared ${plural(cleared.entries.length, "Tab")}`, "arrow.down");
}

export function middleClickTab(tabId: string) {
  const removed = store().removeClosedPin(tabId);
  if (!removed) return void closeTab(tabId);
  if (removed.entries.length) showUndoToast(removed, "Removed Pinned Tab", "pin.slash");
}

export async function openOverflowMenu(windowId: string) {
  const s = store();
  const w = s.windows[windowId];
  if (!w) return;
  const muted = allMuted(windowId);
  const open = viewTabIds(s, windowId).map((id) => s.tabs[id]!);
  const closed = [
    ...s.closedTabs
      .filter((c) => c.tab.profileId === w.profileId)
      .map((c) => ({ id: `restore:${c.id}`, title: c.tab.customTitle || c.tab.title || tabLabel(c.tab), symbol: "clock.arrow.circlepath", at: c.closedAt })),
    ...s.closedGroups.map((c) => ({ id: `restore:${c.id}`, title: `${c.group.name} (${plural(c.tabs.length, "Tab")})`, symbol: "rectangle.stack", at: c.closedAt })),
  ]
    .sort((a, b) => b.at - a.at)
    .slice(0, 15)
    .map(({ at: _, ...item }) => item);
  const allCleaned = cleanedTabsFor(s, windowId);
  const cleaned = [...allCleaned].reverse().slice(0, 20);
  const deleted = keptDeletedGroups(s.deletedGroups)
    .reverse()
    .map((c) => ({ id: `restore:${c.id}`, title: `${c.group.name} (${plural(c.tabs.length, "Tab")})`, symbol: "trash" }));
  const daily = s.settings.cleanUpInactiveTabsAfterHours !== null;
  const synced = syncedDevicesMenuItem(w.profileId);
  const choice = await showMenu([
    { id: "search", title: "Search Tabs…", symbol: "magnifyingglass", ...menuShortcut("searchTabs") },
    sep,
    {
      id: "open",
      title: "Open Tabs",
      symbol: "square.stack",
      enabled: open.length > 0,
      children: open.map((t) => ({ id: `tab:${t.id}`, title: tabTitle(t), checked: w.activeTabIds[w.profileId] === t.id })),
    },
    ...(synced ? [synced] : []),
    { id: "closed", title: "Recently Closed", symbol: "clock.arrow.circlepath", enabled: closed.length > 0, children: closed.length ? closed : [{ id: "none", title: "Empty", enabled: false }] },
    {
      id: "cleaned",
      title: "Recently Cleaned",
      symbol: "wand.and.stars",
      enabled: cleaned.length > 0,
      children: cleaned.length
        ? [
            ...cleaned.map((c) => ({ id: `cleaned:${c.id}`, title: c.tab.customTitle || c.tab.title || tabLabel(c.tab) })),
            sep,
            { id: "restoreAll", title: `Restore ${plural(allCleaned.length, "Tab")}` },
          ]
        : [{ id: "none", title: "Empty", enabled: false }],
    },
    ...(deleted.length ? [{ id: "deleted", title: "Recently Deleted Groups", symbol: "trash", children: deleted }] : []),
    sep,
    { id: "clean", title: "Clean Up Tabs", symbol: "wand.and.stars", ...menuShortcut("cleanUpTabs") },
    { id: "daily", title: "Clean Up Daily", checked: daily },
    sep,
    { id: "mute", title: muted ? "Unmute All Tabs" : "Mute All Tabs", symbol: muted ? "speaker.wave.2" : "speaker.slash" },
    { id: "closeAll", title: "Close All Tabs", symbol: "xmark", ...menuShortcut("closeAllTabs") },
  ]);
  if (!choice) return;
  if (choice === "search") setSidebarUi({ searchTabs: windowId });
  else if (choice.startsWith("tab:")) switchToTab(choice.slice(4));
  else if (openSyncedTab(choice, windowId, w.profileId)) return;
  else if (choice.startsWith("restore:")) s.restoreClosed(choice.slice(8), windowId);
  else if (choice.startsWith("cleaned:")) s.restoreCleaned(choice.slice(8), windowId);
  else if (choice === "restoreAll") s.restoreCleaned(undefined, windowId);
  else if (choice === "clean") s.cleanUpTabs(windowId);
  else if (choice === "daily") s.updateSettings({ cleanUpInactiveTabsAfterHours: daily ? null : 24 });
  else if (choice === "mute") muteAll(windowId, !muted);
  else if (choice === "closeAll") closeAllTabs(windowId);
}
