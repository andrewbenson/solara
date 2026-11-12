import { confirm, onWindowEvent, retainLastWindow } from "@solara/shell";
import { useBrowser } from "../store/browser";
import { tabsClosingWithWindow } from "../store/model";
import type { Tab } from "../store/types";
import { closeWindowDialog } from "./closeWindowDialog";
import { isSmall } from "../store/small";
import { closeLittleSolara } from "../components/littleSolara/actions";
import { closeWindowAnimated } from "./closeAnimated";
import { closeSnapshots as snapshots, type CloseSnapshot } from "./closeSnapshots";
import { usePages } from "../components/layout/pageState";
import { pagesPooledIn } from "./pagesPool";

const MIN_TABS = 2;
const SNAPSHOT_MS = 30_000;

export function snapshotTabId(snapshot: CloseSnapshot, tab: { storeTabId: string; browserId: number }) {
  return [snapshot.browsers[tab.browserId], tab.storeTabId].find((id) => !!id && snapshot.tabs.some((saved) => saved.id === id));
}

export function takeCloseSnapshot(appWindow: string | undefined, tabs: { storeTabId: string; browserId: number }[]): CloseSnapshot | undefined {
  const key = appWindow && snapshots.has(appWindow)
    ? appWindow
    : [...snapshots.keys()].find((id) => tabs.some((tab) => snapshotTabId(snapshots.get(id)!, tab)));
  const found = key ? snapshots.get(key) : undefined;
  if (key) snapshots.delete(key);
  return found;
}

function rememberClose(windowId: string) {
  const s = useBrowser.getState();
  const window = s.windows[windowId];
  if (!window) return;
  snapshots.set(windowId, {
    window: { ...window, tabIds: [...window.tabIds], activeTabIds: { ...window.activeTabIds } },
    tabs: window.tabIds.map((id) => s.tabs[id]).filter((tab): tab is Tab => !!tab).map((tab) => ({ ...tab })),
    groups: Object.values(s.groups).filter((group) => group.windowId === windowId).map((group) => ({ ...group, tabIds: [...group.tabIds] })),
    splits: Object.values(s.splits).filter((split) => split.windowId === windowId).map((split) => ({ ...split, tabIds: [...split.tabIds], sizes: [...split.sizes] })),
    pooled: pagesPooledIn(windowId),
    browsers: Object.fromEntries(Object.entries(usePages.getState().browsers).filter(([, tabId]) => window.tabIds.includes(tabId))),
    closedAt: Date.now(),
  });
  setTimeout(() => snapshots.delete(windowId), SNAPSHOT_MS);
}

export function startWindowCloseGuard() {
  const pending = new Set<string>();
  onWindowEvent((e) => {
    if (e.type !== "closeRequest" || pending.has(e.id)) return;
    pending.add(e.id);
    void requestClose(e.id).finally(() => pending.delete(e.id));
  });
}

export async function requestClose(windowId: string) {
  const s = useBrowser.getState();
  const w = s.windows[windowId];
  if (!w) return;
  if (isSmall(s, windowId)) {
    rememberClose(windowId);
    return closeLittleSolara(windowId);
  }
  if (await retainLastWindow(windowId)) return;
  if (!useBrowser.getState().windows[windowId]) return;
  const count = closingTabs(windowId).length;
  if (s.settings.warnBeforeClosingWindow && count >= MIN_TABS) {
    const { confirmed, suppressed } = await confirm({ ...closeWindowDialog(windowId), suppression: "Don’t ask me again", windowId });
    if (suppressed) useBrowser.getState().updateSettings({ warnBeforeClosingWindow: false });
    if (!confirmed) return;
  }
  if (await retainLastWindow(windowId, true)) return;
  rememberClose(windowId);
  closeWindowAnimated(windowId);
}

const closingTabs = (windowId: string) => tabsClosingWithWindow(useBrowser.getState(), windowId);
