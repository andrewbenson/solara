import { openModeFor, openUrl } from "../bookmarks/actions";
import { openInternalPage } from "../pages/urls";
import { windowNativeLayoutGeneration, publishSettingsTopic } from "@solara/settings";
import { isPageCurrent, nativePageFacts } from "@solara/store";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { create } from "zustand";
import { publishPageContext } from "../pageEvents";
import { goBackAcrossEngines } from "../../lib/engines";
import { livePageId, withLivePage } from "../../lib/livePage";
import { webviews } from "../../lib/webviews";
import { useBrowser } from "../../store/browser";
import { changedIds } from "../../store/changes";
import { useTabLive } from "../../store/hooks";
import { closeTab } from "../../lib/actions";
import { backClosesToOpener } from "../../store/openers";
import type { BrowserState } from "../../store/browser";
import type { TabLive } from "../../store/types";
import { backAction, knownHistoryFor, type BackAction, type BackFacts } from "./backAction";
import { internalPageOf, tabDestination } from "../pages/urls";
import { pageOf, patchPage, usePage } from "./pageState";

const store = () => useBrowser.getState();

function backFacts(s: BrowserState, tabId: string): { pageId: string; facts: BackFacts } {
  const pageId = livePageId(tabId);
  const page = pageOf(pageId);
  const live = s.live[pageId];
  return {
    pageId,
    facts: {
      newTabShown: !!page.newTabShown,
      canGoBack: !!live?.canGoBack,
      engineBack: !!page.engineBack,
      backToNewTab: !!page.backToNewTab,
      historyKnown: !!live && page.historyKnown,
      opener: backClosesToOpener(s, tabId),
    },
  };
}

export function canGoBack(tabId: string): boolean {
  return backAction(backFacts(store(), tabId).facts) !== "none";
}

export function canGoForward(tabId: string, live: Pick<TabLive, "canGoForward">): boolean {
  return !!pageOf(tabId).newTabShown || live.canGoForward;
}

export function useBackAction(tabId: string): BackAction {
  const pageId = useBrowser((s) => s.tabs[tabId]?.pageIn ?? tabId);
  const opener = useBrowser((s) => backClosesToOpener(s, tabId));
  const canGoBack = useTabLive(pageId, (l) => l.canGoBack);
  const hasLive = useBrowser((s) => !!opener && !!s.live[pageId]);
  const newTabShown = usePage(pageId, (p) => !!p.newTabShown);
  const engineBack = usePage(pageId, (p) => !!p.engineBack);
  const backToNewTab = usePage(pageId, (p) => p.backToNewTab);
  const historyKnown = usePage(pageId, knownHistoryFor(opener));
  return backAction({ newTabShown, canGoBack: !!canGoBack, engineBack, backToNewTab, historyKnown: hasLive && historyKnown, opener });
}

export function useHistoryAvailability(tabId: string) {
  const back = useBackAction(tabId) !== "none";
  const forward = useTabLive(tabId, (l) => l.canGoForward);
  const shown = usePage(tabId, (p) => !!p.newTabShown);
  return { back, forward: shown || forward };
}

export function goBack(tabId: string): void {
  const { pageId, facts } = backFacts(store(), tabId);
  const action = backAction(facts);
  if (action === "opener") return closeToOpener(tabId, facts.opener!);
  if (action === "none") return;
  if (pageId !== tabId) return void withLivePage(tabId, (_, id) => goBackInPage(id));
  goBackInPage(tabId);
}

function goBackInPage(tabId: string): void {
  if (pageOf(tabId).newTabShown) return;
  if (store().live[tabId]?.canGoBack) return void webviews.get(tabId)?.goBack();
  if (pageOf(tabId).engineBack) return void goBackAcrossEngines(tabId);
  if (pageOf(tabId).backToNewTab) showNewTab(tabId);
}

function closeToOpener(tabId: string, opener: string): void {
  closeTab(tabId, opener).catch((error: unknown) => console.warn(`[back] closing ${tabId} for its opener failed`, error));
}

export function goForward(tabId: string): void {
  if (livePageId(tabId) !== tabId) return void withLivePage(tabId, (_, id) => goForward(id));
  if (pageOf(tabId).newTabShown) return hideNewTab(tabId);
  void webviews.get(tabId)?.goForward();
}

function showNewTab(tabId: string, keep?: { url: string; title: string }) {
  const tab = store().tabs[tabId];
  if (!tab?.url) return;
  patchPage(tabId, { newTabShown: { url: keep?.url ?? tab.url, title: keep?.title ?? tab.title, favicon: tab.favicon }, status: "" });
  publishPageContext(tabId);
  const internal = internalPageOf(tabDestination(tab)) !== null;
  store().updateTab(tabId, { url: "", title: "", favicon: null, ...(internal ? { navigation: null } : {}) });
}

function goBackToNewTab(tabId: string, offset: number, first: { url: string; title: string }) {
  if (!pageOf(tabId).backToNewTab || pageOf(tabId).newTabShown) return;
  if (offset) void webviews.get(tabId)?.goToOffset(offset);
  showNewTab(tabId, offset ? first : undefined);
}

function hideNewTab(tabId: string) {
  const kept = pageOf(tabId).newTabShown;
  if (!kept) return;
  patchPage(tabId, { newTabShown: null });
  publishPageContext(tabId);
  store().updateTab(tabId, { url: kept.url, title: kept.title, favicon: kept.favicon });
}

useBrowser.subscribe((s, prev) => {
  for (const id of changedIds(s.tabs, prev.tabs)) {
    const tab = s.tabs[id];
    const before = prev.tabs[id];
    if (!tab || !before) continue;
    if (!tabDestination(before) && internalPageOf(tabDestination(tab)) && !pageOf(id).backToNewTab) patchPage(id, { backToNewTab: true });
  }
});

export type HistoryItem = {
  key: string;
  title: string;
  url: string;
  offset: number | "newTab";
};

export async function historyItems(asked: string, direction: -1 | 1, max = 15): Promise<HistoryItem[]> {
  const tabId = livePageId(asked);
  const page = pageOf(tabId);
  const list = (await webviews.get(tabId)?.navigationEntries()) ?? [];
  const current = list.findIndex((e) => e.current);
  if (page.newTabShown) {
    if (direction < 0) return [];
    const items: HistoryItem[] = [];
    for (let i = Math.max(current, 0); i < list.length && items.length < max; i++) {
      const e = list[i]!;
      items.push({ key: String(i), title: e.title || e.url, url: e.url, offset: i - current });
    }
    if (!items.length) items.push({ key: "kept", title: page.newTabShown.title || page.newTabShown.url, url: page.newTabShown.url, offset: 0 });
    return items;
  }
  const items: HistoryItem[] = [];
  if (current >= 0) {
    for (let i = current + direction; i >= 0 && i < list.length && items.length < max; i += direction) {
      const e = list[i]!;
      items.push({ key: String(i), title: e.title || e.url, url: e.url, offset: i - current });
    }
  }
  if (direction < 0 && page.backToNewTab && items.length < max) items.push({ key: "newTab", title: "New Tab", url: "", offset: "newTab" });
  return items;
}

export async function goToHistoryItem(tabId: string, item: HistoryItem, current = () => true): Promise<void> {
  if (!current()) return;
  if (livePageId(tabId) !== tabId) return withLivePage(tabId, (_, id) => void goToHistoryItem(id, item, current));
  const page = pageOf(tabId);
  if (item.offset === "newTab") {
    const list = (await webviews.get(tabId)?.navigationEntries()) ?? [];
    if (!current()) return;
    const index = list.findIndex((e) => e.current);
    if (index <= 0 || !list[0]) return goBack(tabId);
    return goBackToNewTab(tabId, -index, list[0]);
  }
  if (page.newTabShown) {
    hideNewTab(tabId);
    if (item.offset) void webviews.get(tabId)?.goToOffset(item.offset);
    return;
  }
  if (item.offset === -1) return goBack(tabId);
  if (item.offset === 1) return goForward(tabId);
  if (item.offset) void webviews.get(tabId)?.goToOffset(item.offset);
}

let nativeMenuRequest = 0;

type HistoryMenu = { tabId: string; direction: -1 | 1; items: HistoryItem[] };
export const useHistoryMenu = create<{ menu: HistoryMenu | null }>(() => ({ menu: null }));

export async function openHistoryMenu(tabId: string, direction: -1 | 1) {
  const windowId = store().tabs[tabId]?.windowId;
  const generation = windowId ? windowNativeLayoutGeneration(windowId) : 0;
  if (generation > 0) {
    publishSettingsTopic("pane.navigationMenu", { windowId, tabId, generation, direction, request: ++nativeMenuRequest });
    return;
  }
  const items = await historyItems(tabId, direction);
  if (!items.length) return;
  useHistoryMenu.setState({ menu: { tabId, direction, items } });
}

export const closeHistoryMenu = () => useHistoryMenu.setState({ menu: null });


type NavigationCompatibilityAction = { kind: "back" | "forward" } | ({ kind: "item" } & HistoryItem);
const nativeNavigationCurrent = (windowId: string, tabId: string, generation: number) => generation > 0 && windowNativeLayoutGeneration(windowId) === generation && store().tabs[tabId]?.windowId === windowId;

addNativeSettingsHandlers({
  "pane.navigationOpen": (windowId: string, tabId: string, generation: number, item: HistoryItem, click: { metaKey?: boolean; shiftKey?: boolean; altKey?: boolean; middle?: boolean }) => {
    if (!nativeNavigationCurrent(windowId, tabId, generation) || !item.url) return;
    openUrl(item.url, windowId, openModeFor(click));
  },
  "pane.navigationFullHistory": (windowId: string, tabId: string, generation: number) => {
    if (nativeNavigationCurrent(windowId, tabId, generation)) openInternalPage("history", windowId);
  },
  "pane.navigationHistory": async (windowId: string, tabId: string, generation: number, direction: -1 | 1) => {
    if (!nativeNavigationCurrent(windowId, tabId, generation)) return [];
    const handle = webviews.get(tabId);
    const items = await historyItems(tabId, direction);
    return nativeNavigationCurrent(windowId, tabId, generation) && webviews.get(tabId) === handle ? items : [];
  },
  "pane.navigationCompatibility": (windowId: string, tabId: string, generation: number, registrationGeneration: number, sourceUrl: string, action: NavigationCompatibilityAction) => {
    const facts = nativePageFacts(tabId);
    const pageCurrent = () => {
      if (!nativeNavigationCurrent(windowId, tabId, generation)) return false;
      if (registrationGeneration === 0) {
        const tab = store().tabs[tabId];
        return !!tab && tab.url === sourceUrl && (internalPageOf(tabDestination(tab)) !== null || !tabDestination(tab));
      }
      return !!facts && isPageCurrent({ tabId, sessionGeneration: facts.generation, registrationGeneration });
    };
    if (!pageCurrent()) return;
    if (action.kind === "back") goBack(tabId);
    else if (action.kind === "forward") goForward(tabId);
    else if (action.kind === "item") void goToHistoryItem(tabId, action, pageCurrent);
  },
});
