import type { BrowserState } from "../store/browser";
import { activeTabId, resolveWindowId } from "../store/model";
import { peekTabId } from "../store/peek";
import { isSmall, mainWindowFor } from "../store/small";
import { IMPORT_WINDOW_ID, SETTINGS_WINDOW_ID } from "../components/settings/windows";
import { LITTLE_SOLARA_PAGE_COMMANDS } from "./commandCatalog";

export const UTILITY_WINDOW_IDS: ReadonlySet<string> = new Set([SETTINGS_WINDOW_ID, IMPORT_WINDOW_ID]);

export const LITTLE_SOLARA_COMMANDS: ReadonlySet<string> = new Set([
  "closeTab", "focusCommandBar", "openFile", "switchProfile", "nextProfile", "previousProfile", "openProfileMenu",
]);

export const WINDOW_LEVEL_COMMANDS: ReadonlySet<string> = new Set([
  "newWindow", "newIncognitoWindow", "newLittleSolara", "toggleOpenLinksInLittleSolara", "reopenClosedWindow", "setAppearance",
  "toggleFullUrl", "toggleJavaScriptFromAppleEvents", "setSidebarPosition", "toggleSidebarIconsOnly", "toggleAddressBar",
  "openSettings", "keyboardShortcuts", "importBrowserData", "openFile", "manageExtensions", "setBookmarksBar", "toggleBookmarksBar",
]);

export const INVOKER_COMMANDS: ReadonlySet<string> = new Set(["addFolderToSidebar", "restoreArcFolders"]);

export type CommandRouteKind =
  | "utilityClose"
  | "settingsSearch"
  | "littleSolara"
  | "peekPromote"
  | "peekCloseFind"
  | "peekDismiss"
  | "window"
  | "invoker"
  | "noWindow"
  | "main";

export type CommandRoute = {
  kind: CommandRouteKind;
  windowId: string | null;
  focusWindow: string | null;
  tabId: string | null;
};

type RouteState = Pick<BrowserState, "windows" | "windowOrder" | "ui" | "peeks" | "find" | "windowUi" | "tabs">;

const route = (kind: CommandRouteKind, windowId: string | null = null, focusWindow: string | null = null, tabId: string | null = null): CommandRoute =>
  ({ kind, windowId, focusWindow, tabId });

export function commandRoute(s: RouteState, command: string, requested: string | null | undefined): CommandRoute {
  let target = requested ?? null;
  if (target && UTILITY_WINDOW_IDS.has(target)) {
    if (command === "closeTab") return route("utilityClose", target);
    if (command === "findInPage" && target === SETTINGS_WINDOW_ID) return route("settingsSearch", target);
    target = null;
  }
  if (isSmall(s, target) && LITTLE_SOLARA_COMMANDS.has(command)) return route("littleSolara", target);
  const peekWindow = resolveWindowId(s as BrowserState, target);
  const peek = peekWindow ? s.peeks[peekWindow] : undefined;
  if (peekWindow && peek) {
    if (command === "openFile") return route("peekPromote", peekWindow, null, peek.tabId || null);
    if (command === "closeTab" && !s.windowUi[peekWindow]?.panel.open) {
      return route(s.find[peek.tabId]?.open ? "peekCloseFind" : "peekDismiss", peekWindow, null, peek.tabId || null);
    }
  }
  if (WINDOW_LEVEL_COMMANDS.has(command)) return route("window", target);
  const invokedFrom = target;
  let focusWindow: string | null = null;
  if (target && isSmall(s, target) && !LITTLE_SOLARA_PAGE_COMMANDS.has(command)) {
    target = mainWindowFor(s as BrowserState, s.windows[target]!.profileId) ?? null;
    focusWindow = target;
  }
  if (INVOKER_COMMANDS.has(command)) return route("invoker", resolveWindowId(s as BrowserState, invokedFrom) ?? null, focusWindow);
  const windowId = resolveWindowId(s as BrowserState, target);
  if (!windowId) return route("noWindow", null, focusWindow);
  const tabId = (LITTLE_SOLARA_PAGE_COMMANDS.has(command) && peekTabId(s, windowId)) || activeTabId(s as BrowserState, windowId);
  return route("main", windowId, focusWindow, tabId || null);
}
