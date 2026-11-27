import { nativeOwnsWorkspace } from "../store/nativeStore";
import { nativeAppIntegrationCommand, nativeWorkspaceCommand } from "@solara/settings";
import {
  closeWindow as closeNativeWindow,
  openExternalURL,
  prompt,
  setAppearance,
  type CommandEvent,
} from "@solara/shell";
import { useBrowser } from "../store/browser";
import { activeTabId, bookmarkProfileId, isPinnedRow, resolveWindowId } from "../store/model";
import {
  closeGroup,
  closeTab,
  closeTabs,
  createProfile,
  cycleProfile,
  focus,
  moveTabToProfile,
  moveTabToWindow,
  openWindow,
  switchProfile,
  toggleMute,
} from "./actions";
import { useClearDataRequest } from "../components/pages/ClearDataDialog";
import { openInternalPage } from "../components/pages/urls";
import { openImport, openSettings } from "../components/settings/windows";
import { focusSettingsSearch } from "../components/settings/searchState";
import { closePanelToHeroBar } from "../components/omnibox/barState";
import { closeNewTabBar, toggleNewTabBar } from "../components/omnibox/newTabBar";
import { NEW_TAB_BAR_POLICY } from "../store/newTabBar";
import { bookmarkWriter, reportBookmarkFailure } from "./bookmarkWriter";
import { webviews } from "./webviews";
import { goBack, goForward } from "../components/layout/history";
import { openSplitPane } from "../components/layout/splitActions";
import { commandRoute } from "./commandRoute";
import { runSidebarCommand } from "../components/sidebar/commands";
import { numberedTabs } from "../components/sidebar/entries";
import { openProfileMenu } from "../components/ProfileIndicator";
import { groupOf, multiSelection } from "../store/organize";
import { reopenClosedTogether } from "../store/closedTogether";
import { newWindowProfile, originalProfile } from "../store/small";
import {
  closeLittleSolara,
  cycleLittleSolaraProfile,
  moveLittleSolaraToProfile,
  openLittleSolara,
  openLittleSolaraProfileMenu,
} from "../components/littleSolara/actions";
import { runPeekCommand } from "../components/peek/actions";
import { toggleDeveloperModeFor } from "../components/site/developerMode";
import { peekTabId } from "../store/peek";
import { setSidebarPosition, toggleSidebarIconsOnly } from "../store/sidebarRail";
import { expectFocus, findFocus } from "./focusClaims";

let commandHandlersEnabled = true;
let commandHandlerCalls = 0;
let commandHandlerBlocked = 0;

export const commandHandlers = {
  setEnabled(enabled: boolean) { if (__DEV__) commandHandlersEnabled = enabled; },
  stats: () => ({ enabled: commandHandlersEnabled, calls: commandHandlerCalls, blocked: commandHandlerBlocked }),
};

export function runCommand({ command, arg, windowId: requested }: CommandEvent) {
  if (command === "addFolderToSidebar" || command === "restoreArcFolders" || command === "openBookmark" || command === "jumpToSelection" || ["copyUrl", "copyUrlAsMarkdown", "copyQuoteLink", "share", "openFile", "autofill", "searchTabs", "tabSwitcher", "focusCommandBar", "cast", "reload", "forceReload", "returnToPinnedUrl", "togglePageEngine", "openExtension", "addExtension", "pinExtensions", "manageExtensions", "showHistory", "manageBookmarks", "bookmarkPage", "bookmarkAllTabs"].includes(command)) return void nativeWorkspaceCommand(command, arg, requested);
  if (nativeOwnsWorkspace() && nativeWorkspaceCommand(command, arg, requested)) return;
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
    case "utilityClose":
      return void closeNativeWindow(route.windowId!);
    case "settingsSearch":
      return focusSettingsSearch();
    case "littleSolara":
      return void runLittleSolaraCommand(command, arg, route.windowId!);
    case "peekPromote":
    case "peekCloseFind":
    case "peekDismiss":
      return void runPeekCommand(command, route.windowId!);
  }
  if (route.kind === "window") return runWindowCommand(command, arg, route.windowId);
  if (route.focusWindow) focus(route.focusWindow);
  if (route.kind === "invoker") return;
  if (route.kind === "noWindow") {
    if (command === "newTab") openWindow({ newTabCommand: true });
    if (command === "reopenClosedTab" || command === "restoreClosed") {
      if (arg) s.restoreClosed(arg);
      else s.reopenClosed();
    }
    return;
  }
  const windowId = route.windowId!;
  const tabId = route.tabId ?? undefined;
  const tab = tabId ? s.tabs[tabId] : undefined;
  const page = tab?.url ? tab : undefined;
  const web = tabId ? webviews.get(tabId) : undefined;
  const ui = s.windowUi[windowId];
  const find = tabId ? s.find[tabId] : undefined;
  if (runSidebarCommand(command, arg, windowId)) return;

  switch (command) {
    case "newTab":
      if (toggleNewTabBar(windowId)) return;
      return void s.newTab(windowId, { newTabCommand: true });
    case "reopenClosedTab":
      if (reopenClosedTogether(windowId)) return;
      return s.reopenClosed(windowId);
    case "restoreClosed":
      return arg ? s.restoreClosed(arg, windowId) : undefined;
    case "closeTab":
      if (ui?.panel.newTab) {
        closeNewTabBar(windowId);
        if (NEW_TAB_BAR_POLICY.closeTabKeyOnlyDismissesBar || !tabId) return;
        return void closeTab(tabId);
      }
      if (ui?.panel.open) return tabId ? closePanelToHeroBar(windowId, tabId, "closeKey") : s.closePanel(windowId);
      if (!peekTabId(s, windowId) && multiSelection(s, windowId).length) return void closeTabs(windowId, multiSelection(s, windowId));
      return tabId ? void closeTab(tabId) : undefined;
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
    case "toggleTabLayout":
      return s.toggleTabLayout(windowId);
    case "openSplitPane":
      return void openSplitPane(windowId);
    case "focusNextPane":
      return s.focusPane(windowId, 1);
    case "focusPreviousPane":
      return s.focusPane(windowId, -1);
    case "toggleSidebar":
      return s.toggleSidebar(windowId);
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
    case "nextTab":
      return s.cycle(windowId, 1);
    case "previousTab":
      return s.cycle(windowId, -1);
    case "selectTab":
    case "selectLastTab": {
      const rows = numberedTabs(s, windowId);
      const id = command === "selectLastTab" ? rows.at(-1) : rows[Number(arg) - 1];
      return id ? s.activate(id) : undefined;
    }
    case "togglePin":
      if (!tab) return;
      if (arg === "row") return s.pinTabs([tab.id], true, !isPinnedRow(tab));
      if (arg === "tile") return isPinnedRow(tab) ? s.pinTabs([tab.id], true, false) : undefined;
      return s.togglePin(tab.id);
    case "moveTabDown":
    case "moveTabUp":
      return tab ? s.moveTabBy(tab.id, command === "moveTabDown" ? 1 : -1) : undefined;
    case "closeTabGroup": {
      const group = groupOf(s, tabId);
      return group ? void closeGroup(group.id) : undefined;
    }
    case "openProfileMenu":
      return s.windows[windowId]?.incognito ? undefined : void openProfileMenu(windowId);
    case "duplicateTab":
      return tab ? void s.duplicateTab(tab.id) : undefined;
    case "moveTabToProfile":
      return tab && arg ? void moveTabToProfile(tab.id, arg) : undefined;
    case "moveTabToWindow":
      return tab && arg ? moveTabToWindow(tab.id, arg) : undefined;
    case "addBookmarkToFolder":
      return page && arg ? void addBookmarkToFolder(windowId, page.id, arg) : undefined;
    case "toggleMute":
      return page ? toggleMute(page.id) : undefined;
    case "downloads":
      return s.setDownloadsOpen(windowId, !ui?.downloadsOpen);
    case "clearBrowsingData":
      openInternalPage("history", windowId);
      return useClearDataRequest.getState().request(windowId);
    case "mergeAllWindows":
      return s.mergeAllWindows(windowId);
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

function runWindowCommand(command: string, arg: string | null | undefined, requested: string | null) {
  const s = useBrowser.getState();
  switch (command) {
    case "newWindow":
      return void openWindow({ profileId: newWindowProfile(s, requested, arg) });
    case "newIncognitoWindow":
      return void openWindow({ incognito: true, profileId: originalProfile(s, s.windows[requested ?? ""]) });
    case "newLittleSolara":
      return void openLittleSolara(undefined, arg ?? undefined);
    case "toggleOpenLinksInLittleSolara":
      return s.updateSettings({ openLinksInLittleSolara: !s.settings.openLinksInLittleSolara });
    case "reopenClosedWindow":
      return s.reopenClosedWindow();
    case "setAppearance":
      if (arg === "auto" || arg === "light" || arg === "dark") {
        s.updateSettings({ appearance: arg });
        void setAppearance(useBrowser.getState().settings.appearance);
      }
      return;
    case "toggleFullUrl":
      return s.updateSettings({ showFullUrl: !s.settings.showFullUrl });
    case "toggleJavaScriptFromAppleEvents":
      return s.updateSettings({ allowJavaScriptFromAppleEvents: !s.settings.allowJavaScriptFromAppleEvents });
    case "setSidebarPosition":
      if (arg === "left" || arg === "right") {
        const id = resolveWindowId(s, requested);
        if (id) return setSidebarPosition(id, arg);
      }
      return;
    case "toggleSidebarIconsOnly":
      return toggleSidebarIconsOnly(resolveWindowId(s, requested) ?? "");
    case "toggleAddressBar":
      return s.updateSettings({ addressBar: s.settings.addressBar === "sidebar" ? "toolbar" : "sidebar" });
    case "openSettings":
      return openSettings();
    case "keyboardShortcuts":
      return openSettings("shortcuts");
    case "importBrowserData":
      return openImport();
    case "setBookmarksBar":
      if (arg === "always" || arg === "newTab" || arg === "never") s.updateSettings({ bookmarksBar: arg });
      return;
    case "toggleBookmarksBar": {
      const mode = s.settings.bookmarksBar;
      const target = resolveWindowId(s, requested);
      const active = target ? activeTabId(s, target) : undefined;
      const shown = mode === "always" || (mode === "newTab" && !(active && s.tabs[active]?.url));
      return s.updateSettings({ bookmarksBar: shown ? "never" : "always" });
    }
  }
}

function runLittleSolaraCommand(command: string, arg: string | null | undefined, windowId: string) {
  const s = useBrowser.getState();
  const tabId = activeTabId(s, windowId);
  const tab = tabId ? s.tabs[tabId] : undefined;
  switch (command) {
    case "closeTab":
      if (s.windowUi[windowId]?.panel.open && tab?.url) s.closePanel(windowId);
      else closeLittleSolara(windowId);
      return;
    case "switchProfile":
      if (arg) moveLittleSolaraToProfile(windowId, arg);
      return;
    case "nextProfile":
      cycleLittleSolaraProfile(windowId, 1);
      return;
    case "previousProfile":
      cycleLittleSolaraProfile(windowId, -1);
      return;
    case "openProfileMenu":
      void openLittleSolaraProfileMenu(windowId);
      return;
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
      return reportBookmarkFailure(error);
    }
  }
  await bookmarkWriter.addBookmark({ profileId, url: tab.url, title: tab.title, favicon: tab.favicon, parentId }).catch(reportBookmarkFailure);
}

