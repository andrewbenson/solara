import type { MenuItem } from "@solara/shell";
import type { BrowserState } from "../../store/browser";
import { inPinnedContainer, isIncognitoProfile, isPinnedRow, pinnedSectionTitle, pinSection, togglePinTitle, viewTabIds, windowTitle } from "../../store/model";
import { awayFromPin, groupLabel, groupOf, selectedTabIds } from "../../store/organize";
import { groupPath } from "../../store/groups";
import { splitOf, splitRowPanes } from "../../store/splits";
import { isCalendarUrl } from "../../live/meetings";
import { canSwitchEngine, ENGINE_SYMBOLS, openPageInTitle, otherEngine, tabEngine } from "../../store/engines";
import { moveToProfileItems } from "./moveToProfileItems";

const sep = { separator: true } as const;

type Shortcut = Pick<Extract<MenuItem, { id: string }>, "key" | "modifiers">;
export type TabMenuContext = { calendarItem?: MenuItem; shortcuts?: Record<string, Shortcut> };

export function tabMenuWindowItems(s: BrowserState, windowId: string): MenuItem[] {
  const others = s.windowOrder.filter((id) => id !== windowId && !s.windows[id]!.incognito && s.windows[id]!.kind !== "small");
  return [
    ...others.map((id) => ({ id: `window:${id}`, title: windowTitle(s, id) })),
    ...(others.length ? [sep] : []),
    { id: "window:new", title: "New Window" },
  ];
}

export function tabMenuGroupItems(s: BrowserState, windowId: string, exclude: string | undefined): MenuItem[] {
  const w = s.windows[windowId];
  const groups = Object.values(s.groups).filter((g) => g.windowId === windowId && g.profileId === w?.profileId && g.id !== exclude);
  return groups
    .map((g) => ({ id: `group:${g.id}`, title: groupPath(s.groups, g.id).map((id) => groupLabel(s, s.groups[id]!)).join(" › "), symbol: g.pinned ? "pin" : "square.on.square" }))
    .sort((a, z) => (a.title < z.title ? -1 : a.title > z.title ? 1 : 0));
}

export function tabMenuItems(s: BrowserState, windowId: string, tabId: string, context: TabMenuContext = {}): MenuItem[] | null {
  const tab = s.tabs[tabId];
  if (!tab || !s.windows[windowId]) return null;
  const selected = selectedTabIds(s, windowId);
  if (selected.length > 1 && selected.includes(tabId)) return null;
  if (tab.pinned && isCalendarUrl(tab.pinnedUrl ?? tab.url) && !context.calendarItem) return null;
  const shortcut = (command: string): Shortcut => context.shortcuts?.[command] ?? {};
  const view = viewTabIds(s, windowId);
  const list = view.filter((id) => !inPinnedContainer(s, id));
  const housed = inPinnedContainer(s, tab.id);
  const memberPin = housed && !tab.pinned;
  const index = list.indexOf(tab.id);
  const above = housed ? [] : list.slice(0, index);
  const below = housed ? [] : list.slice(index + 1);
  const others = list.filter((id) => id !== tab.id);
  const group = groupOf(s, tab.id);
  const split = splitOf(s, tab.id);
  const splitRow = splitRowPanes(s, split).includes(tab.id);
  const incognito = isIncognitoProfile(tab.profileId);
  const across = (s.windows[windowId]?.tabLayout ?? s.settings.tabLayout) === "top";
  const away = awayFromPin(tab);
  const groups = tabMenuGroupItems(s, windowId, group?.id);

  return [
    { id: "copy", title: "Copy Link", symbol: "link", enabled: !!tab.url, ...shortcut("copyUrl") },
    { id: "share", title: "Share", symbol: "square.and.arrow.up", enabled: /^https?:/i.test(tab.url), share: true },
    sep,
    { id: "rename", title: "Rename…", symbol: "character.cursor.ibeam" },
    ...(tab.customTitle ? [{ id: "resetName", title: "Reset Name", symbol: "arrow.counterclockwise" }] : []),
    { id: "icon", title: "Change Icon…", symbol: "face.smiling" },
    ...(tab.customIcon ? [{ id: "resetIcon", title: "Reset Icon", symbol: "arrow.counterclockwise" }] : []),
    { id: "mute", title: tab.muted ? "Unmute Site" : "Mute Site", symbol: tab.muted ? "speaker.wave.2" : "speaker.slash", enabled: !!tab.url },
    ...(housed
      ? [
          {
            id: "pinnedPage",
            title: "Edit Pinned Page",
            symbol: "pin",
            children: [
              { id: "backToPin", title: "Back to Pinned URL", symbol: "arrow.uturn.backward", enabled: away, ...shortcut("returnToPinnedUrl") },
              { id: "replacePin", title: "Replace Pin with Current Page", symbol: "pin", enabled: away },
              sep,
              { id: "editPin", title: "Edit…", symbol: "pencil" },
            ],
          },
        ]
      : []),
    ...(tab.pinned && isCalendarUrl(tab.pinnedUrl ?? tab.url) ? [context.calendarItem!] : []),
    sep,
    { id: "duplicate", title: "Duplicate", symbol: "plus.square.on.square" },
    { id: "bookmark", title: "Add to Bookmarks…", symbol: "bookmark", enabled: !!tab.url, ...shortcut("bookmarkPage") },
    ...(canSwitchEngine(tab.url) ? [{ id: "engine", title: openPageInTitle(otherEngine(tabEngine(s, tab.id))), symbol: ENGINE_SYMBOLS[otherEngine(tabEngine(s, tab.id))] }] : []),
    ...(split ? [{ id: "unsplit", title: "Remove from Split View", symbol: "rectangle.split.2x1.slash" }] : []),
    {
      id: "moveTo",
      title: "Move to",
      symbol: "arrow.right.square",
      children: [
        ...(splitRow || pinSection(tab) === "tile" ? [] : [{ id: "pinTile", title: "Top Apps", symbol: "app" }]),
        ...(splitRow || isPinnedRow(tab) ? [] : [{ id: "pinRow", title: pinnedSectionTitle(s, tab), symbol: "list.bullet" }]),
        ...(pinSection(tab) !== "tile"
          ? []
          : tab.tileFolder
            ? [{ id: "leaveFolder", title: "Out of Folder", symbol: "folder.badge.minus" }]
            : [{ id: "newFolder", title: "New Folder…", symbol: "folder.badge.plus" }]),
        ...(pinSection(tab) === "tile"
          ? []
          : [
              { id: "newGroup", title: "New Group", symbol: "plus.rectangle.on.rectangle", ...shortcut("newGroupWithTabs") },
              ...(groups.length ? [{ id: "moveToGroup", title: "Group", symbol: "rectangle.stack", children: groups }] : []),
              ...(group && !memberPin ? [{ id: "ungroupTab", title: "Out of Group", symbol: "folder.badge.minus" }] : []),
            ]),
        sep,
        ...moveToProfileItems(s, tab, incognito),
        { id: "moveToWindow", title: "Window", symbol: "macwindow", enabled: !incognito, children: tabMenuWindowItems(s, windowId) },
      ],
    },
    sep,
    memberPin ? { id: "unpinMember", title: "Unpin", symbol: "pin.slash" } : { id: "pin", title: togglePinTitle(tab), symbol: tab.pinned ? "pin.slash" : "pin" },
    ...(housed
      ? []
      : [
          { id: "close", title: "Close Tab", symbol: "xmark", ...shortcut("closeTab") },
          {
            id: "closeMore",
            title: "Close Tabs",
            enabled: others.length > 0,
            children: [
              { id: "closeOthers", title: "Other Tabs", enabled: others.length > 0 },
              { id: "closeAbove", title: across ? "Tabs to the Left" : "Tabs Above", enabled: above.length > 0 },
              { id: "closeBelow", title: across ? "Tabs to the Right" : "Tabs Below", enabled: below.length > 0 },
            ],
          },
        ]),
  ];
}

export type MultiTabMenuContext = { folders: MenuItem[]; shortcuts?: Record<string, Shortcut> };

export function multiTabMenuItems(s: BrowserState, windowId: string, ids: string[], context: MultiTabMenuContext): MenuItem[] {
  const n = ids.length;
  const tabs = ids.map((id) => s.tabs[id]!);
  if (!tabs.length || tabs.some((tab) => !tab || tab.windowId !== windowId) || !s.windows[windowId]) return [];
  const allPinned = tabs.every((t) => t.pinned);
  const allTiles = tabs.every((t) => pinSection(t) === "tile");
  const incognito = tabs.some((t) => isIncognitoProfile(t.profileId));
  const groups = tabMenuGroupItems(s, windowId, undefined);
  const shortcut = (command: string): Shortcut => context.shortcuts?.[command] ?? {};
  return [
    { id: "pin", title: allPinned ? `Unpin ${n} Tabs` : `Move ${n} Tabs to Top Apps`, symbol: allPinned ? "pin.slash" : "pin" },
    ...(tabs.every(isPinnedRow) ? [] : [{ id: "pinRows", title: `Move ${n} Tabs to ${pinnedSectionTitle(s, tabs[0])}`, symbol: "list.bullet" }]),
    { id: "duplicate", title: `Duplicate ${n} Tabs`, symbol: "plus.square.on.square" },
    { id: "newGroup", title: `New Group with ${n} Tabs`, symbol: "plus.rectangle.on.rectangle", enabled: !allTiles, ...shortcut("newGroupWithTabs") },
    ...(groups.length ? [{ id: "moveToGroup", title: "Move to Group", symbol: "rectangle.stack", children: groups }] : []),
    ...(tabs.some((t) => groupOf(s, t.id)) ? [{ id: "ungroup", title: "Remove from Group", symbol: "folder.badge.minus" }] : []),
    sep,
    { id: "copy", title: `Copy ${n} URLs`, symbol: "link", ...shortcut("copyUrl") },
    { id: "copyMd", title: `Copy ${n} URLs as Markdown`, symbol: "text.badge.checkmark", ...shortcut("copyUrlAsMarkdown") },
    { id: "bar", title: `Add ${n} Tabs to Bookmarks Bar`, symbol: "bookmark" },
    { id: "bookmarkTo", title: `Add ${n} Tabs to Bookmarks Folder`, symbol: "folder", children: context.folders },
    sep,
    { id: "moveToWindow", title: "Move to Window", symbol: "macwindow", enabled: !incognito, children: tabMenuWindowItems(s, windowId) },
    sep,
    { id: "close", title: `Close ${n} Tabs`, symbol: "xmark", ...shortcut("closeTab") },
  ];
}

export function multiTabMenuCommand(choice: string, windowId: string, ids: string[], s: BrowserState): { name: string; args: unknown[] } | null {
  const tabs = ids.map((id) => s.tabs[id]);
  if (!tabs.length || !s.windows[windowId] || tabs.some((tab) => !tab || tab.windowId !== windowId)) return null;
  let handled = ["pin", "pinRows", "duplicate", "ungroup"].includes(choice);
  if (choice === "newGroup") handled = tabs.some((tab) => pinSection(tab) !== "tile");
  if (choice.startsWith("group:")) {
    const group = s.groups[choice.slice(6)];
    handled = !!group && group.windowId === windowId && group.profileId === s.windows[windowId]!.profileId;
  }
  if (choice.startsWith("window:")) {
    const target = choice.slice(7);
    handled = !tabs.some((tab) => isIncognitoProfile(tab!.profileId)) && (target === "new" || !!s.windows[target]);
  }
  return handled ? { name: "tabMenuSelection", args: [windowId, ids, choice] } : null;
}
