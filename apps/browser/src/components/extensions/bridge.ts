import {
  onExtensionInstallPrompt,
  onExtensionInstallPromptClosed,
  onExtensionActionChanged,
  onExtensionActionPopup,
  onExtensionActionShortcut,
  onExtensionSidePanel,
  onEngineEvent,
  onExtensionsChanged,
  onExtensionTabsRequest,
  resolveExtensionInstallPrompt,
  watchExtensionActions,
  webStoreExtensionId,
  type TabsRequest,
  type CloseCancelledTab,
} from "@solara/solaracore";
import { killSwitchEnvironment } from "@solara/shell";
import { onNativeExtensionPopupChanged, onNativeExtensionPopupOpenWindow } from "@solara/settings";
import { AppState } from "react-native";
import { openWindow } from "../../lib/actions";
import { webviews } from "../../lib/webviews";
import { storeTransaction, useBrowser, type BrowserState } from "../../store/browser";
import { snapshotTabId, takeCloseSnapshot } from "../../lib/windowClose";
import type { Tab, TabSnapshot } from "../../store/types";
import { changedIds } from "../../store/changes";
import { activeTabId, engineProfile, incognitoOriginal } from "../../store/model";
import { shownPageId } from "../../store/peek";
import { openFromPage, pageProfileId } from "../layout/openFromPage";
import { tabForBrowser, usePages } from "../layout/pageState";
import { refreshActionStates } from "./actions";
import { startExtensionSearchEngines } from "./searchEngines";
import * as state from "./state";
import {
  activateExtension,
  cancelInstall,
  closeExtensionPopup,
  closeInstallPrompt,
  extensionPopupChanged,
  closeSidePanel,
  extensionProfile,
  findExtension,
  installRequesterGone,
  openSidePanel,
  refreshExtensions,
  refreshExtensionsAfterChange,
  showInstallPrompt,
  wantedSidePanels,
  syncSidePanel,
  useExtensions,
  windowExtensions,
  type InstallRequester,
} from "./state";
import { PRODUCT } from "../../lib/productName";

export function startExtensionsBridge() {
  onExtensionTabsRequest(openRequestedTab);
  startExtensionSearchEngines();
  onExtensionsChanged(({ profile }) => void refreshExtensions(profile));
  onEngineEvent("extensions.changed", ({ profile }) => void refreshExtensionsAfterChange(profile));

  const loadProfiles = (s: BrowserState) => {
    for (const id of s.windowOrder) {
      const profile = extensionProfile(s, id);
      if (loadedProfiles.has(profile)) continue;
      loadedProfiles.add(profile);
      void refreshExtensions(profile);
      watchActionsOf(profile);
    }
  };
  loadProfiles(useBrowser.getState());
  useBrowser.subscribe((s, prev) => {
    if (s.windows !== prev.windows) loadProfiles(s);
    if (toolbarAnchors.size && (s.windows !== prev.windows || s.tabs !== prev.tabs)) pruneToolbarAnchors(s);
  });

  startActionStates();
  startSidePanels();
  startActionPopups();
  startWebStoreIntegration();
  if (__DEV__) Object.assign(globalThis, { acExtensionsApp: { ...state, bridge: { openExtensionFromMenu } } });
}

function openRequestedTab(request: TabsRequest) {
  if (request.action === "closeWindow") return closeChromeMadeWindow(request.chromeWindow);
  if (request.action === "closeCancelled") return restoreCancelledClose(request);
  if (request.chromeWindow && request.tabKey) return moveIntoChromeMadeWindow(request, request.chromeWindow, request.tabKey);
  if (request.chromeWindow && request.adoptId) return openChromeMadeTab(request, request.chromeWindow, request.adoptId);
  if (!request.url) return;
  const s = useBrowser.getState();
  const ofProfile = (id: string) => !!s.windows[id] && !s.windows[id]!.incognito && engineProfile(s.windows[id]!.profileId) === request.profile;
  const windowId =
    (request.window && s.windows[request.window] ? request.window : undefined) ??
    s.ui.focusOrder.find(ofProfile) ??
    s.ui.focusOrder.find((id) => s.windows[id]);
  const background = request.active === false;
  const profileId = request.adoptId
    ? windowId && ofProfile(windowId) ? s.windows[windowId]!.profileId : s.profileOrder.find((p) => engineProfile(p) === request.profile)
    : undefined;
  if (request.adoptId && profileId) {
    if (windowId && ofProfile(windowId)) s.newTab(windowId, { url: request.url, adoptId: request.adoptId, profileId, background });
    else openWindow({ url: request.url, adoptId: request.adoptId, profileId });
    return;
  }
  if (windowId) s.newTab(windowId, { url: request.url, background });
  else openWindow({ url: request.url });
}

function snapshotFields(tab: Tab): Partial<TabSnapshot> {
  return {
    title: tab.title, favicon: tab.favicon, pinned: tab.pinned, muted: tab.muted,
    zoom: tab.zoom, customTitle: tab.customTitle, customIcon: tab.customIcon,
    pinnedUrl: tab.pinnedUrl, pinnedAsRow: tab.pinnedAsRow, tileFolder: tab.tileFolder,
  };
}

function restoreCancelledClose(request: TabsRequest) {
  const live = request.tabs;
  if (!request.chromeWindow || !live) return;
  const snapshot = takeCloseSnapshot(request.appWindow, live);
  if (!snapshot) return console.warn("[windowClose] no snapshot for cancelled close", request.appWindow);
  if (snapshot.pooled) {
    const { window, tabs, groups, splits } = snapshot;
    const liveTabIds = [...new Set(live.map((tab) => snapshotTabId(snapshot, tab)).filter((id): id is string => !!id))];
    if (!liveTabIds.length) {
      console.warn("[windowClose] no live snapshot tabs for cancelled close", window.id);
      return null;
    }
    const restored = useBrowser.getState().restoreClosingWindow({ window, tabs, groups, splits }, request.chromeWindow, liveTabIds);
    if (!restored) console.warn("[windowClose] a cancelled close on the page pool could not restore its window", window.id);
    return restored;
  }
  const s = useBrowser.getState();
  const old = new Map(snapshot.tabs.map((tab) => [tab.id, tab]));
  const byId = (tab: CloseCancelledTab) => old.get(snapshotTabId(snapshot, tab) ?? "");
  const remaining = live.filter((tab) => byId(tab) || snapshot.tabs.some((oldTab) => oldTab.url === tab.url));
  if (!remaining.length || snapshot.window.incognito && (remaining.some((tab) => !tab.incognito) || !s.profiles[incognitoOriginal(snapshot.window.profileId)])) return;
  const first = remaining[0]!;
  const firstOld = byId(first) ?? snapshot.tabs.find((tab) => tab.url === first.url);
  const original = snapshot.window;
  const assigned = new Map<string, string>();
  const small = original.kind === "small";
  const restoreInto = () => {
    const windowId = s.createWindow({
      profileId: original.profileId, incognito: original.incognito, small,
      frame: original.frame, linkPointer: original.linkPointer, chromeWindow: request.chromeWindow,
      url: first.url, adoptId: first.adoptId, background: request.focused === false,
    });
    const created = useBrowser.getState().windows[windowId];
    if (!created || created.incognito !== original.incognito || created.profileId !== original.profileId || created.kind !== original.kind) {
      return console.warn("[windowClose] the restored window doesn't match the closed one", JSON.stringify({ windowId, created: created && { incognito: created.incognito, profileId: created.profileId, kind: created.kind }, original: { incognito: original.incognito, profileId: original.profileId, kind: original.kind } }));
    }
    const firstId = created.tabIds[0]!;
    if (firstOld) {
      assigned.set(firstOld.id, firstId);
      s.updateTab(firstId, snapshotFields(firstOld));
    }
    for (const tab of remaining.slice(1)) {
      const saved = byId(tab) ?? snapshot.tabs.find((oldTab) => oldTab.url === tab.url && !assigned.has(oldTab.id));
      const id = s.newTab(windowId, {
        url: tab.url, adoptId: tab.adoptId, profileId: saved?.profileId ?? original.profileId,
        snapshot: saved ? snapshotFields(saved) : { title: tab.title }, background: true,
        index: saved ? original.tabIds.indexOf(saved.id) : undefined,
      });
      if (saved && id) assigned.set(saved.id, id);
    }
    if (firstOld?.pinned) s.pinTabs([firstId], true, firstOld.pinnedAsRow === true);
    if (!small && original.sidebarOpen !== created.sidebarOpen) s.toggleSidebar(windowId);
    if (!small && original.tabLayout === "top") s.toggleTabLayout(windowId);
    const groups = new Map<string, string>();
    for (const group of snapshot.groups) {
      const ids = group.tabIds.map((id) => assigned.get(id)).filter((id): id is string => !!id);
      if (!ids.length) continue;
      const id = s.groupTabs(ids, { pinned: group.pinned, name: group.name });
      if (!id) continue;
      groups.set(group.id, id);
      s.updateGroup(id, { icon: group.icon, color: group.color, collapsed: group.collapsed });
    }
    for (const group of snapshot.groups) {
      const id = groups.get(group.id);
      const parentId = group.parentId && groups.get(group.parentId);
      if (id && parentId) s.moveGroup(id, { pinned: group.pinned, parentId });
    }
    for (const split of snapshot.splits) {
      const ids = split.tabIds.map((id) => assigned.get(id)).filter((id): id is string => !!id);
      if (ids.length < 2) continue;
      const id = s.createSplit(ids, split.orientation);
      if (id) s.updateSplit(id, { sizes: split.sizes, stackSizes: split.stack?.sizes });
    }
    for (const active of Object.values(original.activeTabIds)) {
      const id = assigned.get(active);
      if (id) s.activate(id);
    }
    const closed = useBrowser.getState().closedWindows.find((entry) =>
      entry.closedAt >= snapshot.closedAt && entry.tabs.some((tab) => !!tab.tabId && old.has(tab.tabId)));
    if (closed) s.forgetClosedWindow(closed.id);
  };
  try {
    storeTransaction(restoreInto);
  } catch (error) {
    console.warn("[windowClose] restoring a cancelled close failed", error);
  }
}

function openChromeMadeTab(request: TabsRequest, chromeWindow: string, adoptId: string) {
  const s = useBrowser.getState();
  const made = Object.values(s.windows).find((w) => w.chromeWindow === chromeWindow);
  if (made) return void s.newTab(made.id, { url: request.url, adoptId, profileId: made.profileId, background: request.active === false });
  const profileId = s.profileOrder.find((p) => engineProfile(p) === request.profile);
  if (!profileId) return void openWindow({ url: request.url, adoptId });
  openWindow({ url: request.url, adoptId, profileId, chromeWindow, background: request.focused === false });
}

function closeChromeMadeWindow(chromeWindow: string | undefined) {
  const s = useBrowser.getState();
  const made = chromeWindow ? Object.values(s.windows).find((w) => w.chromeWindow === chromeWindow) : undefined;
  if (made) s.closeWindow(made.id);
}

function moveIntoChromeMadeWindow(request: TabsRequest, chromeWindow: string, tabId: string) {
  const s = useBrowser.getState();
  const tab = s.tabs[tabId];
  if (!tab) return;
  const made = Object.values(s.windows).find((w) => w.chromeWindow === chromeWindow);
  if (made) return void s.moveTabsToWindow([tabId], made.id);
  s.createWindow({ profileId: tab.profileId, tabIds: [tabId], chromeWindow, background: request.focused === false });
}

export function openExtensionFromMenu(windowId: string, extensionId: string, tabId?: string, requiresActive = false) {
  const ext = findExtension(extensionProfile(useBrowser.getState(), windowId), extensionId);
  if (ext) void activateExtension(windowId, ext, toolbarAnchor(windowId, ext.id, tabId), undefined, tabId, { requiresActive });
}

type Anchor = import("./state").Anchor;
type AnchorEntry = { windowId: string; tabId: string; anchor: Anchor };
const toolbarAnchors = new Map<string, AnchorEntry>();
const anchorKey = (windowId: string, tabId: string, slot: string) => `${windowId}|${tabId}|${slot}`;

export const setToolbarAnchor = (windowId: string, tabId: string, slot: string, anchor: Anchor) =>
  void toolbarAnchors.set(anchorKey(windowId, tabId, slot), { windowId, tabId, anchor });

export function dropToolbarAnchor(windowId: string, tabId: string, slot: string, anchor: Anchor) {
  const key = anchorKey(windowId, tabId, slot);
  if (toolbarAnchors.get(key)?.anchor === anchor) toolbarAnchors.delete(key);
}

function pruneToolbarAnchors(s: BrowserState) {
  for (const [key, entry] of toolbarAnchors) if (!s.windows[entry.windowId] || s.tabs[entry.tabId]?.windowId !== entry.windowId) toolbarAnchors.delete(key);
}

function toolbarAnchor(windowId: string, extensionId: string, tabId?: string): Anchor {
  const s = useBrowser.getState();
  for (const pane of new Set([tabId ?? shownPageId(s, windowId), activeTabId(s, windowId)])) {
    if (!pane) continue;
    const entry = toolbarAnchors.get(anchorKey(windowId, pane, extensionId)) ?? toolbarAnchors.get(anchorKey(windowId, pane, "*"));
    if (entry) return entry.anchor;
  }
  return { x: 100_000, y: 13, width: 28, height: 28 };
}

const ACTION_POLL_MS = 1500;
const ACTION_EVENT_COALESCE_MS = 150;

function refreshActionsAndPanels() {
  void refreshActionStates();
  for (const [windowId] of wantedSidePanels()) void syncSidePanel(windowId);
}

let actionPoll: ReturnType<typeof setInterval> | null = null;
function pollActionStates() {
  actionPoll ??= setInterval(() => {
    if (AppState.currentState === "active") refreshActionsAndPanels();
  }, ACTION_POLL_MS);
}

const pollsActions = () => killSwitchEnvironment("SOLARA_EXTENSION_ACTION_POLL") === "on";

function watchActionsOf(profile: string) {
  if (pollsActions()) return pollActionStates();
  void watchExtensionActions(profile).then((watching) => watching || pollActionStates());
}

const loadedProfiles = new Set<string>();
const dirtyActions = new Set<string>();
const dirtyLists = new Set<string>();
let flushTimer: ReturnType<typeof setTimeout> | null = null;

const windowsOf = (s: BrowserState, profile: string) => s.windowOrder.filter((windowId) => extensionProfile(s, windowId) === profile);

function showsAction(profile: string, extensionId: string) {
  const s = useBrowser.getState();
  const popup = useExtensions.getState().popup;
  const windows = windowsOf(s, profile);
  if (wantedSidePanels().some(([windowId, id]) => id === extensionId && windows.includes(windowId))) return true;
  return windows.some((windowId) => windowExtensions(s, windowId).some((x) => x.id === extensionId && (x.pinned || popup?.extensionId === x.id)));
}

function flushActionChanges() {
  flushTimer = null;
  if (AppState.currentState !== "active") return;
  for (const profile of dirtyLists) if (loadedProfiles.has(profile)) void refreshExtensionsAfterChange(profile);
  dirtyLists.clear();
  if (dirtyActions.size) {
    const profiles = [...dirtyActions];
    dirtyActions.clear();
    void refreshActionStates(profiles);
    const s = useBrowser.getState();
    for (const [windowId] of wantedSidePanels()) if (profiles.includes(extensionProfile(s, windowId))) void syncSidePanel(windowId);
  }
}

function flushSoon() {
  if (AppState.currentState !== "active" || (!dirtyActions.size && !dirtyLists.size)) return;
  flushTimer ??= setTimeout(flushActionChanges, ACTION_EVENT_COALESCE_MS);
}

function startActionStates() {
  onExtensionActionChanged(({ profile, id, kind }) => {
    if (kind === "registry") dirtyLists.add(profile);
    else if (showsAction(profile, id)) dirtyActions.add(profile);
    else return;
    flushSoon();
  });
  AppState.addEventListener("change", (state) => state === "active" && flushSoon());
  useBrowser.subscribe((s, prev) => {
    if (s.windows !== prev.windows || s.ui.focusedWindowId !== prev.ui.focusedWindowId) return void refreshActionStates();
    if (s.tabs === prev.tabs) return;
    if (s.windowOrder.some((id) => { const active = activeTabId(s, id); return !!active && s.tabs[active] !== prev.tabs[active]; })) void refreshActionStates();
  });
  useExtensions.subscribe((e, prev) => {
    if (e.lists !== prev.lists || e.popup !== prev.popup) void refreshActionStates();
  });
  usePages.subscribe((p, prev) => {
    if (p.browsers === prev.browsers) return;
    void refreshActionStates();
    const actions = useExtensions.getState().actions;
    const gone = Object.keys(actions).filter((id) => !p.browsers[Number(id)]);
    if (!gone.length) return;
    const next = { ...actions };
    for (const id of gone) delete next[Number(id)];
    useExtensions.setState({ actions: next });
  });
}

function startActionPopups() {
  AppState.addEventListener("change", (state) => { if (state !== "active") closeExtensionPopup(); });
  onNativeExtensionPopupChanged(extensionPopupChanged);
  onNativeExtensionPopupOpenWindow(({ windowId, profile, request }) => {
    openFromPage(request, { windowId, profileId: pageProfileId(windowId, profile) });
  });
  onExtensionActionPopup(({ browserId, extensionId }) => {
    const tabId = tabForBrowser(browserId);
    const windowId = tabId ? useBrowser.getState().tabs[tabId]?.windowId : undefined;
    if (!windowId) return console.warn(`action.openPopup for ${extensionId}: ${tabId ? "its tab has no window" : `no tab for browser ${browserId}`}`);
    void state.openActionPopup(windowId, extensionId, toolbarAnchor(windowId, extensionId, tabId), browserId);
  });
  onExtensionActionShortcut(({ browserId, extensionId }) => {
    const tabId = tabForBrowser(browserId);
    const windowId = tabId ? useBrowser.getState().tabs[tabId]?.windowId : undefined;
    if (windowId) openExtensionFromMenu(windowId, extensionId, tabId, true);
  });
}

function startSidePanels() {
  onExtensionSidePanel(({ browserId, extensionId, open }) => {
    const tabId = tabForBrowser(browserId);
    const windowId = tabId ? useBrowser.getState().tabs[tabId]?.windowId : undefined;
    if (!windowId) return;
    if (open) void openSidePanel(windowId, extensionId);
    else closeSidePanel(windowId, extensionId);
  });
  const active = (s: BrowserState) => s.windowOrder.map((id) => `${id}:${shownPageId(s, id) ?? ""}`).join(",");
  useBrowser.subscribe((s, prev) => {
    if (s.windows === prev.windows && s.tabs === prev.tabs) return;
    if (active(s) === active(prev)) return;
    for (const [windowId] of wantedSidePanels()) {
      if (!s.windows[windowId]) closeSidePanel(windowId);
      else void syncSidePanel(windowId);
    }
  });
  useExtensions.subscribe((e, prev) => {
    if (e.lists === prev.lists) return;
    const s = useBrowser.getState();
    for (const [windowId, extensionId] of wantedSidePanels()) {
      if (!windowExtensions(s, windowId).some((x) => x.id === extensionId)) closeSidePanel(windowId);
    }
    if (e.popup && !windowExtensions(s, e.popup.windowId).some((x) => x.id === e.popup!.extensionId)) closeExtensionPopup();
  });
}

const STORE_SCRIPT = `
const g = window;
if (!g.__solaraStore) {
  const store = (g.__solaraStore = { waiting: null, queued: [] });
  const request = (id) => {
    if (!id) return;
    if (store.waiting) { const w = store.waiting; store.waiting = null; w(id); } else store.queued.push(id);
  };
  // "Remove from Chrome" would bring up Chrome's own dialog.
  const mg = g.chrome && g.chrome.management;
  if (mg && typeof mg.uninstall === "function") {
    Object.defineProperty(mg, "uninstall", { configurable: true, writable: true, value: (id, options, callback) => {
      request(id);
      const done = typeof options === "function" ? options : callback;
      if (typeof done === "function") { setTimeout(done); return; }
      return Promise.resolve();
    } });
  }
  const relabel = () => {
    for (const el of document.querySelectorAll("button, button *")) {
      if (el.childElementCount) continue;
      const t = el.textContent;
      if (t === "Add to Chrome") el.textContent = ${JSON.stringify(`Add to ${PRODUCT}`)};
      else if (t === "Remove from Chrome") el.textContent = ${JSON.stringify(`Remove from ${PRODUCT}`)};
    }
  };
  relabel();
  new MutationObserver(relabel).observe(document.documentElement, { subtree: true, childList: true, characterData: true });
}
const store = g.__solaraStore;
if (store.queued.length) post("result", JSON.stringify(store.queued.shift()));
else store.waiting = (id) => post("result", JSON.stringify(id));
`;

const isStorePage = (url: string | undefined) => !!url && /^https:\/\/chromewebstore\.google\.com\//.test(url);

function startWebStoreIntegration() {
  let watchRequester: (() => void) | null = null;
  onExtensionInstallPromptClosed((closed) => closeInstallPrompt(closed.requestId));
  onExtensionInstallPrompt((prompt) => {
    const s = useBrowser.getState();
    const tabId = prompt.browserId ? tabForBrowser(prompt.browserId) : undefined;
    const windowId = (tabId && s.tabs[tabId]?.windowId) || s.ui.focusedWindowId || s.windowOrder[0];
    if (!windowId) return void resolveExtensionInstallPrompt(prompt.requestId, false);
    showInstallPrompt(windowId, prompt);
    watchRequester?.();
    const popup = useExtensions.getState().popup;
    const requester: InstallRequester = tabId ? { tabId } : popup && popup.extensionId === prompt.id ? { popupOf: popup.extensionId } : null;
    if (!requester) return void (watchRequester = null);
    const check = () => {
      if (useExtensions.getState().install?.prompt?.requestId !== prompt.requestId) return stop();
      if (installRequesterGone(requester, useBrowser.getState(), useExtensions.getState().popup)) {
        stop();
        cancelInstall();
      }
    };
    const unsubscribers = [useBrowser.subscribe(check), useExtensions.subscribe(check)];
    const stop = () => {
      unsubscribers.splice(0).forEach((off) => off());
      if (watchRequester === stop) watchRequester = null;
    };
    watchRequester = stop;
  });
  const listening = new Map<string, string>();
  const listen = (tabId: string, url: string) => {
    listening.set(tabId, url);
    const web = webviews.get(tabId);
    if (!web) return void listening.delete(tabId);
    void web.evaluate<string>(STORE_SCRIPT).then((id) => {
      const s = useBrowser.getState();
      const tab = s.tabs[tabId];
      if (!tab || listening.get(tabId) !== url) return;
      const profile = extensionProfile(s, tab.windowId);
      const ext = id && webStoreExtensionId(id) ? findExtension(profile, id) : undefined;
      if (ext) void state.removeExtension(profile, ext, tab.windowId);
      if (tab.url === url) listen(tabId, url);
    });
  };
  const sync = (s: BrowserState, prev?: BrowserState) => {
    for (const [tabId, url] of listening) if (s.tabs[tabId]?.url !== url || s.live[tabId]?.isLoading) listening.delete(tabId);
    const ids = prev ? new Set([...changedIds(s.tabs, prev.tabs), ...changedIds(s.live, prev.live)]) : Object.keys(s.tabs);
    for (const id of ids) {
      const tab = s.tabs[id];
      if (!tab || !isStorePage(tab.url) || s.live[id]?.isLoading || listening.get(id) === tab.url) continue;
      listen(id, tab.url);
    }
  };
  useBrowser.subscribe((s, prev) => {
    if (s.tabs !== prev.tabs || s.live !== prev.live) sync(s, prev);
  });
  sync(useBrowser.getState());
}
