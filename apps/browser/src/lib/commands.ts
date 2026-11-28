import { nativeAppIntegrationCommand, nativeWorkspaceCommand } from "@solara/settings";
import {
  cancelFocusMove,
  openExternalURL,
  prompt,
  type CommandEvent,
} from "@solara/shell";
import { useBrowser } from "../store/browser";
import { bookmarkProfileId } from "../store/model";
import {
  createProfile,
  cycleProfile,
  focus,
  switchProfile,
  toggleMute,
} from "./actions";
import { openImport, openSettings } from "../components/settings/windows";
import { focusSettingsSearch } from "../components/settings/searchState";
import { bookmarkWriter, reportBookmarkFailure } from "./bookmarkWriter";
import { webviews } from "./webviews";
import { goBack, goForward } from "../components/layout/history";
import { commandRoute } from "./commandRoute";
import { toggleDeveloperModeFor } from "../components/site/developerMode";
import { settlingCommandFocus } from "./focusHandoff";
import { expectFocus, findFocus } from "./focusClaims";

let commandHandlersEnabled = true;
let commandHandlerCalls = 0;
let commandHandlerBlocked = 0;

export const commandHandlers = {
  setEnabled(enabled: boolean) { if (__DEV__) commandHandlersEnabled = enabled; },
  stats: () => ({ enabled: commandHandlersEnabled, calls: commandHandlerCalls, blocked: commandHandlerBlocked }),
};

const nativeOnlyCommands = new Set<string>([
  "addFolderToSidebar", "restoreArcFolders", "openBookmark", "jumpToSelection", "copyUrl", "copyUrlAsMarkdown",
  "copyQuoteLink", "share", "openFile", "autofill", "searchTabs", "tabSwitcher", "focusCommandBar", "cast",
  "reload", "forceReload", "returnToPinnedUrl", "togglePageEngine", "openExtension", "addExtension", "pinExtensions",
  "manageExtensions", "showHistory", "manageBookmarks", "clearBrowsingData", "bookmarkPage", "bookmarkAllTabs",
]);

export function runCommand(event: CommandEvent) {
  const { command, arg, windowId, focusGeneration } = event;
  if (nativeWorkspaceCommand(command, arg, windowId) || nativeOnlyCommands.has(command)) {
    if (focusGeneration) cancelFocusMove(focusGeneration, false);
    return;
  }
  settlingCommandFocus(event, runLegacyCommand);
}

function runLegacyCommand({ command, arg, windowId: requested }: CommandEvent) {
  if (__DEV__ && !commandHandlersEnabled) { commandHandlerBlocked++; return; }
  if (__DEV__) commandHandlerCalls++;
  switch (command) {
    case "showOnboarding":
    case "toolTour":
    case "videoTour":
    case "releaseNotes":
    case "sendFeedback":
    case "reportBug":
    case "copyDiagnostics":
    case "recordPerformanceIssue":
    case "taskManager":
      return void nativeAppIntegrationCommand(command, requested).catch((error) => {
        console.warn(`Native app integration command ${command} failed`, error);
      });
  }
  const s = useBrowser.getState();
  const route = commandRoute(s, command, requested);
  switch (route.kind) {
    case "settingsSearch":
      return focusSettingsSearch();
    case "utilityClose":
    case "littleSolara":
    case "peekPromote":
    case "peekCloseFind":
    case "peekDismiss":
      return;
  }
  if (route.kind === "window") return runWindowCommand(command);
  if (route.focusWindow) focus(route.focusWindow);
  if (route.kind !== "main") return;
  const windowId = route.windowId!;
  const tabId = route.tabId ?? undefined;
  const tab = tabId ? s.tabs[tabId] : undefined;
  const page = tab?.url ? tab : undefined;
  const web = tabId ? webviews.get(tabId) : undefined;
  const find = tabId ? s.find[tabId] : undefined;

  switch (command) {
    case "print":
      return void web?.print();
    case "printWithSystemDialog":
      return void web?.runPageCommand("systemPrint");
    case "savePage":
      return void web?.runPageCommand("savePage");
    case "caretBrowsing":
      return void web?.runPageCommand("caretBrowsing");
    case "emailPageLocation":
      if (!page || !/^https?:/i.test(page.url)) return;
      return void openExternalURL(
        `mailto:?subject=${encodeURIComponent(page.customTitle || page.title || page.url)}&body=${encodeURIComponent(page.url)}`,
      );
    case "stop":
      return void web?.stopLoading();
    case "findInPage":
      if (page) expectFocus(windowId, findFocus(page.id));
      return page ? s.setFind(page.id, { open: true, replace: false, focusRequest: Date.now() }) : undefined;
    case "findAndReplace":
      return page ? s.setFind(page.id, { open: true, replace: true, focusRequest: Date.now() }) : undefined;
    case "useSelectionForFind":
      if (!page || !web) return;
      return void web.evaluate<string>("post('result', JSON.stringify(String(getSelection() || '').trim().slice(0, 500)))").then((query) => {
        if (query) useBrowser.getState().setFind(page.id, { open: true, query, focusRequest: Date.now() });
      });
    case "findNext":
    case "findPrevious":
      if (!page) return;
      if (!find?.query) return s.setFind(page.id, { open: true });
      return void web?.find(find.query, command === "findNext", true);
    case "zoomIn":
      return page ? void web?.zoomStep(1) : undefined;
    case "zoomOut":
      return page ? void web?.zoomStep(-1) : undefined;
    case "zoomReset":
      return page ? void web?.zoomStep(0) : undefined;
    case "devTools":
      return void web?.showDevTools();
    case "toggleDevTools":
      return void web?.showDevTools("toggle");
    case "inspectElements":
      return void web?.showDevTools("inspect");
    case "javaScriptConsole":
      return void web?.showDevTools("console");
    case "toggleDeveloperMode":
      return toggleDeveloperModeFor(page?.id);
    case "viewSource":
      if (!page || !web || !/^(https?|file):/.test(page.url)) return;
      return void s.newTab(windowId, { url: `view-source:${page.url}`, openerId: page.id, profileId: page.profileId });
    case "back":
      return tabId ? goBack(tabId) : undefined;
    case "forward":
      return tabId ? goForward(tabId) : undefined;
    case "addBookmarkToFolder":
      return page && arg ? void addBookmarkToFolder(windowId, page.id, arg) : undefined;
    case "toggleMute":
      return page ? toggleMute(page.id) : undefined;
    case "switchProfile":
      return arg ? switchProfile(windowId, arg, true) : undefined;
    case "nextProfile":
      return cycleProfile(windowId, 1);
    case "previousProfile":
      return cycleProfile(windowId, -1);
    case "newProfile":
      return void createProfile(windowId).then((id) => id && switchProfile(windowId, id));
  }
}

function runWindowCommand(command: string) {
  switch (command) {
    case "openSettings":
      return openSettings();
    case "keyboardShortcuts":
      return openSettings("shortcuts");
    case "importBrowserData":
      return openImport();
  }
}

async function addBookmarkToFolder(windowId: string, tabId: string, folder: string) {
  const s = useBrowser.getState();
  const tab = s.tabs[tabId];
  if (!tab?.url) return;
  const profileId = bookmarkProfileId(s, s.windows[windowId]);
  let parentId = folder;
  if (folder === "new") {
    const title = await prompt({ title: "New Folder", placeholder: "Folder name", confirmTitle: "Create", windowId });
    if (!title) return;
    try {
      parentId = await bookmarkWriter.addBookmarkFolder({ profileId, title });
    } catch (error) {
      return reportBookmarkFailure(error, windowId);
    }
  }
  await bookmarkWriter.addBookmark({ profileId, url: tab.url, title: tab.title, favicon: tab.favicon, parentId }).catch((error: unknown) => reportBookmarkFailure(error, windowId));
}

