import type { CommandAction } from "@solara/core";
import * as settings from "@solara/settings";
import type { BrowserCommand } from "@solara/shell";
import { bookmarkCatalog } from "../../store/bookmarkProjection";
import { isBookmarked } from "../../store/bookmarks";
import { useBrowser, type BrowserState } from "../../store/browser";
import { activeTab, bookmarkProfileId, isPinnedRow, pinnedSectionTitle } from "../../store/model";
import { canTidyPins } from "../../store/tidyPins";
import { canToggleDeveloperModeFor, tabInDeveloperMode } from "../site/developerMode";
import { commandBarTitle, commandSymbol } from "../../lib/commandCatalog";
import { menuBarRevision, shortcutHint } from "../../lib/commandShortcuts";
import type { Tab } from "../../store/types";
import { organizeActions } from "./organizeActions";

type Context = { s: BrowserState; windowId: string; tab: Tab | undefined; bookmarked: boolean };

function bookmarkedPage(s: BrowserState, windowId: string, url: string | undefined): boolean {
  if (!url) return false;
  return settings.nativeIsBookmarked?.(url, windowId)
    ?? isBookmarked(bookmarkCatalog().bookmarks, bookmarkProfileId(s, s.windows[windowId]), url);
}

type ActionDef = {
  command: BrowserCommand;
  arg?: string;
  title?: (c: Context) => string;
  icon?: string;
  keywords?: string[];
  needs?: "page" | "tab" | "profiles" | "pins" | "toggleableSite";
};

const page = "page" as const;

const DEFS: ActionDef[] = [
  { command: "newTab", keywords: ["open tab"] },
  { command: "newWindow" },
  { command: "newIncognitoWindow", keywords: ["private window", "incognito"] },
  { command: "closeTab", needs: "tab" },
  { command: "closeAllTabs", keywords: ["clear unpinned tabs", "close unpinned tabs", "clear today"] },
  { command: "reopenClosedTab", keywords: ["undo close", "restore tab"] },
  {
    command: "togglePin",
    title: ({ tab }) => (isPinnedRow(tab) ? "Unpin Tab" : tab?.pinned ? "Unpin from Top Apps" : "Move to Top Apps"),
    keywords: ["pin", "unpin", "pin tab", "unpin tab", "remove from top apps", "favorites"],
    needs: "tab",
  },
  {
    command: "togglePin",
    arg: "row",
    title: ({ s, tab }) => (isPinnedRow(tab) ? "Move to Top Apps" : `Move to ${pinnedSectionTitle(s, tab)}`),
    icon: "list.bullet",
    keywords: ["pin", "pinned tabs", "pin as row", "move to pinned", "favorites"],
    needs: "tab",
  },
  { command: "duplicateTab", needs: "tab" },
  { command: "renameTab", needs: "tab" },
  { command: "searchTabs" },
  { command: "cleanUpTabs", keywords: ["tidy tabs"] },
  { command: "tidyPins", keywords: ["tidy pinned tabs", "organize pins", "pinned folders", "remove duplicate pins"], needs: "pins" },
  { command: "newGroupWithTabs", keywords: ["tab group"], needs: "tab" },
  { command: "reload", keywords: ["refresh"], needs: page },
  { command: "forceReload", keywords: ["hard reload", "hard refresh"], needs: page },
  { command: "toggleMute", title: ({ tab }) => (tab?.muted ? "Unmute Site" : "Mute Site"), keywords: ["mute", "unmute", "silence"], needs: page },
  { command: "copyUrl", keywords: ["copy link"], needs: page },
  { command: "copyUrlAsMarkdown", keywords: ["markdown link"], needs: page },
  { command: "findInPage", needs: page },
  {
    command: "bookmarkPage",
    title: ({ bookmarked }) => bookmarked ? "Remove Bookmark" : "Bookmark This Page",
    keywords: ["add bookmark", "bookmark"],
    needs: page,
  },
  { command: "print", needs: page },
  { command: "share", keywords: ["airdrop", "share link", "send link"], needs: page },
  { command: "zoomIn", needs: page },
  { command: "zoomOut", needs: page },
  { command: "zoomReset", keywords: ["reset zoom"], needs: page },
  { command: "devTools", keywords: ["inspect", "devtools", "console"], needs: page },
  {
    command: "toggleDeveloperMode",
    title: ({ tab }) => (tabInDeveloperMode(tab?.id) ? "Turn off Developer Mode for this site" : "Turn on Developer Mode for this site"),
    icon: "hammer",
    keywords: ["developer mode", "dev mode", "localhost", "devtools"],
    needs: "toggleableSite",
  },
  { command: "toggleFullUrl", title: ({ s }) => (s.settings.showFullUrl ? "Hide Full URL" : "Show Full URL") },
  { command: "toggleSidebar", keywords: ["toggle sidebar", "hide sidebar", "show sidebar", "focus mode"] },
  { command: "toggleBookmarksBar", keywords: ["bookmarks bar"] },
  { command: "downloads", keywords: ["show downloads", "dl"] },
  { command: "showHistory", keywords: ["show history"] },
  { command: "manageBookmarks", keywords: ["manage bookmarks", "show bookmarks"] },
  { command: "openSettings", keywords: ["preferences", "prefs", "options"] },
  { command: "clearBrowsingData", keywords: ["clear history", "clear cache", "clear cookies"] },
  { command: "importBrowserData", keywords: ["import bookmarks", "import passwords"] },
  { command: "keyboardShortcuts", keywords: ["shortcuts", "hotkeys"] },
  { command: "reportBug", keywords: ["bug", "report bug", "file an issue", "crash"] },
  { command: "mergeAllWindows", needs: "profiles" },
  { command: "newProfile", keywords: ["create profile"], needs: "profiles" },
  { command: "setAppearance", arg: "dark", keywords: ["dark mode"] },
  { command: "setAppearance", arg: "light", keywords: ["light mode"] },
  { command: "setAppearance", arg: "auto", keywords: ["auto appearance", "system appearance"] },
];

const actionId = (d: Pick<ActionDef, "command" | "arg">) => (d.arg ? `${d.command}:${d.arg}` : d.command);

export function barActions(s: BrowserState, windowId: string, bookmarked = bookmarkedPage(s, windowId, activeTab(s, windowId)?.url)): CommandAction[] {
  const w = s.windows[windowId];
  const tab = activeTab(s, windowId);
  const c: Context = { s, windowId, tab, bookmarked };
  const out: CommandAction[] = [];
  for (const d of DEFS) {
    if (d.needs === "page" && !tab?.url) continue;
    if (d.needs === "tab" && !tab) continue;
    if (d.needs === "profiles" && w?.incognito) continue;
    if (d.needs === "pins" && !canTidyPins(s, windowId)) continue;
    if (d.needs === "toggleableSite" && !canToggleDeveloperModeFor(tab?.id)) continue;
    const id = actionId(d);
    const hint = shortcutHint(id, s);
    out.push({
      id,
      title: d.title?.(c) ?? commandBarTitle(d.command, d.arg),
      icon: d.icon ?? commandSymbol(d.command, d.arg),
      ...(hint ? { hint } : {}),
      ...(d.keywords ? { keywords: d.keywords } : {}),
    });
  }
  if (w && !w.incognito) {
    s.profileOrder.forEach((id) => {
      if (id === w.profileId) return;
      const name = s.profiles[id]?.name ?? "";
      const action = `switchProfile:${id}`;
      out.push({ id: action, title: `Switch to ${name}`, icon: "person.crop.circle", hint: shortcutHint(action, s), keywords: [name, "profile", "space"] });
    });
  }
  out.push(...organizeActions(s, windowId));
  return out;
}

const barActionsOf = new WeakMap<BrowserState, Map<string, CommandAction[]>>();

export function currentBarActions(windowId: string): CommandAction[] {
  const s = useBrowser.getState();
  let byWindow = barActionsOf.get(s);
  if (!byWindow) barActionsOf.set(s, (byWindow = new Map()));
  const bookmarked = bookmarkedPage(s, windowId, activeTab(s, windowId)?.url);
  const key = `${windowId}|${menuBarRevision()}|${bookmarked}`;
  let actions = byWindow.get(key);
  if (!actions) byWindow.set(key, (actions = barActions(s, windowId, bookmarked)));
  return actions;
}
