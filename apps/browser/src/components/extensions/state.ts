import {
  configureExtension,
  ExtensionError,
  extensionActionStates,
  installExtension,
  resolveExtensionInstallPrompt,
  type ActionState,
  type ExtensionInstallPrompt,
  type ExtensionPackage,
  type InstalledExtension,
} from "@solara/solaracore";
import { nativeExtensionCommand, refreshNativeExtensionCatalog, closeNativeExtensionPopup, showNativeExtensionPopup, type ExtensionPopupChange } from "@solara/settings";
import { webviews } from "../../lib/webviews";
import { useBrowser, type BrowserState } from "../../store/browser";
import { shownPageId } from "../../store/peek";
import { tabForBrowser } from "../layout/pageState";
import { toggleSidePanel } from "./sidePanels";
import { browserIdOf, extensionProfile, pageProfile, shownIn, useExtensions, type Anchor } from "./store";

export * from "./sidePanels";
export * from "./store";

const EMPTY: InstalledExtension[] = [];

export async function refreshExtensions(profile: string): Promise<InstalledExtension[]> {
  const list: InstalledExtension[] = JSON.parse(await refreshNativeExtensionCatalog(profile));
  useExtensions.setState((e) => ({ lists: { ...e.lists, [profile]: list } }));
  return list;
}

export async function refreshExtensionsAfterChange(profile: string): Promise<InstalledExtension[]> {
  const list: InstalledExtension[] = JSON.parse(await refreshNativeExtensionCatalog(profile, true));
  useExtensions.setState((e) => ({ lists: { ...e.lists, [profile]: list } }));
  return list;
}

export const findExtension = (profile: string, id: string) => useExtensions.getState().lists[profile]?.find((x) => x.id === id);

export const addFromWebStore = (windowId: string, url: string, profile?: string) => nativeExtensionCommand({ command: "webStoreDetail", windowId, url, profile });
export const loadUnpacked = (windowId: string, profile?: string) => nativeExtensionCommand({ command: "loadUnpacked", windowId, profile });

export function showInstallPrompt(windowId: string, prompt: ExtensionInstallPrompt) {
  const current = useExtensions.getState().install;
  if (current?.prompt) void resolveExtensionInstallPrompt(current.prompt.requestId, false);
  else cancelInstall();
  const pkg: ExtensionPackage = {
    id: prompt.id,
    name: prompt.name,
    version: prompt.version,
    description: "",
    manifestVersion: 3,
    icon: prompt.icon || null,
    permissions: [],
    optionalPermissions: [],
    hostPermissions: [],
    hasAction: false,
    popup: null,
    optionsPage: null,
    sidePanel: null,
    path: "",
  };
  useExtensions.setState({ install: { windowId, profile: prompt.profile, source: "webStore", status: "ready", pkg, prompt } });
}

export async function confirmInstall() {
  const request = useExtensions.getState().install;
  if (!request?.pkg || request.status !== "ready") return;
  if (request.prompt) {
    useExtensions.setState({ install: null });
    await resolveExtensionInstallPrompt(request.prompt.requestId, true);
    for (const ms of [1500, 5000]) setTimeout(() => void refreshExtensions(request.profile), ms);
    return;
  }
  useExtensions.setState({ install: { ...request, status: "installing" } });
  try {
    await installExtension(request.pkg, request.profile);
    useExtensions.setState({ install: null });
    await refreshExtensions(request.profile);
  } catch (error) {
    useExtensions.setState({ install: { ...request, status: "error", error: message(error) } });
  }
}

export function cancelInstall() {
  const request = useExtensions.getState().install;
  if (!request) return;
  if (request.prompt) void resolveExtensionInstallPrompt(request.prompt.requestId, false);
  useExtensions.setState({ install: null });
}

export const removeExtension = (profile: string, ext: InstalledExtension, windowId?: string) => nativeExtensionCommand({ command: "remove", profile, id: ext.id, windowId });
export const setEnabled = (profile: string, id: string, enabled: boolean) => nativeExtensionCommand({ command: "setEnabled", profile, id, enabled });
export const setPinned = (profile: string, id: string, pinned: boolean) => nativeExtensionCommand({ command: "setPinned", profile, id, pinned });
export const configure = (profile: string, id: string, options: Parameters<typeof configureExtension>[2]) => nativeExtensionCommand({ command: "configure", profile, id, options });
export const openOptions = (windowId: string, ext: InstalledExtension) => nativeExtensionCommand({ command: "options", windowId, id: ext.id });
export const openManageExtensions = (windowId?: string | null) => nativeExtensionCommand({ command: "manageExtensions", windowId });
export const openPinDialog = (windowId: string) => useExtensions.setState({ pinDialog: { windowId } });
export const openWebStore = (windowId: string) => nativeExtensionCommand({ command: "addExtension", windowId });

export async function activateExtension(
  windowId: string,
  ext: InstalledExtension,
  anchor: Anchor,
  state?: ActionState | null,
  tabId = shownPageId(useBrowser.getState(), windowId),
  { requiresActive = false }: { requiresActive?: boolean } = {},
) {
  const current = pendingPopup ?? useExtensions.getState().popup;
  if (current?.windowId === windowId && current.extensionId === ext.id) return closeExtensionPopup();
  if (!useBrowser.getState().windows[windowId]) return;
  if (!ext.enabled) return void showExtensionMenu(windowId, ext);
  if (!shownIn(windowId, ext.id)) return;
  const request = beginPopupRequest(windowId, ext.id, tabId);
  let shown = false;
  try {
    const web = tabId ? webviews.get(tabId) : undefined;
    const result = web ? await web.executeExtensionAction(ext.id) : null;
    const browserId = browserIdOf(tabId);
    if (!state && result === "popup" && browserId) state = (await extensionActionStates(browserId, [ext.id]))[ext.id];
    if (!popupRequestCurrent(request)) return;
    const url = state ? state.popup : ext.popup ? `chrome-extension://${ext.id}/${ext.popup.replace(/^\//, "")}` : "";
    if (result === "none" || result === "sidePanel" || !url) {
      if (result === "sidePanel") void toggleSidePanel(windowId, ext.id);
      else if (result === null && !url) void showExtensionMenu(windowId, ext);
      return;
    }
    shown = await showPopupIntent(request, url, anchor, requiresActive);
  } finally {
    if (pendingPopup === request) {
      pendingPopup = null;
      if (!shown) void closeNativeExtensionPopup(windowId).catch(() => {});
    }
  }
}

let pendingPopup: { windowId: string; extensionId: string; tabId: string | undefined } | null = null;

function beginPopupRequest(windowId: string, extensionId: string, tabId: string | undefined) {
  pendingPopup = { windowId, extensionId, tabId };
  watchPopupTab();
  return pendingPopup;
}

let stopWatchingPopupTab: (() => void) | null = null;

function watchPopupTab() {
  const wanted = !!(pendingPopup || useExtensions.getState().popup);
  if (wanted && !stopWatchingPopupTab) {
    stopWatchingPopupTab = useBrowser.subscribe((s, prev) => {
      dismissChangedPopup(s, prev);
      watchPopupTab();
    });
  } else if (!wanted && stopWatchingPopupTab) {
    stopWatchingPopupTab();
    stopWatchingPopupTab = null;
  }
}

const popupRequestCurrent = (request: NonNullable<typeof pendingPopup>) =>
  pendingPopup === request && shownPageId(useBrowser.getState(), request.windowId) === request.tabId;

export function closeExtensionPopup(windowId: string | null = null) {
  if (!windowId || pendingPopup?.windowId === windowId) pendingPopup = null;
  watchPopupTab();
  void closeNativeExtensionPopup(windowId).catch(() => {});
}

async function showPopupIntent(request: NonNullable<typeof pendingPopup>, popupUrl: string, anchor: Anchor, requiresActive: boolean): Promise<boolean> {
  if (!popupRequestCurrent(request)) return false;
  return showNativeExtensionPopup({
    extensionId: request.extensionId,
    popupUrl,
    profile: pageProfile(useBrowser.getState(), request.windowId),
    tabId: request.tabId ?? "",
    windowId: request.windowId,
    anchor,
    requiresActive,
  });
}

export function extensionPopupChanged({ windowId, extensionId, tabId, reason }: ExtensionPopupChange) {
  const popup = useExtensions.getState().popup;
  if (extensionId) useExtensions.setState({ popup: { windowId, extensionId, tabId: tabId || undefined } });
  else {
    if (reason !== "replacement" && pendingPopup?.windowId === windowId) pendingPopup = null;
    if (popup?.windowId === windowId) useExtensions.setState({ popup: null });
  }
  watchPopupTab();
}

function dismissChangedPopup(s: BrowserState, prev: BrowserState) {
  for (const popup of [pendingPopup, useExtensions.getState().popup]) {
    if (!popup) continue;
    const { windowId, tabId } = popup;
    if (!s.windows[windowId] || shownPageId(s, windowId) !== tabId ||
      (tabId && (s.tabs[tabId]?.navigation?.seq !== prev.tabs[tabId]?.navigation?.seq || s.tabs[tabId]?.url !== prev.tabs[tabId]?.url ||
        s.live[tabId]?.isLoading && !prev.live[tabId]?.isLoading))) closeExtensionPopup(windowId);
  }
}

export async function openActionPopup(windowId: string, extensionId: string, anchor: Anchor, browserId: number) {
  const s = useBrowser.getState();
  if (!s.windows[windowId]) return;
  const tabId = tabForBrowser(browserId);
  if (!tabId || s.tabs[tabId]?.windowId !== windowId || shownPageId(s, windowId) !== tabId) return;
  const request = beginPopupRequest(windowId, extensionId, tabId);
  let shown = false;
  try {
    const url = (await extensionActionStates(browserId, [extensionId]))[extensionId]?.popup ?? "";
    if (!popupRequestCurrent(request)) return;
    if (!url) {
      return console.warn(`action.openPopup for ${extensionId}: no popup for the tab`);
    }
    shown = await showPopupIntent(request, url, anchor, true);
  } finally {
    if (pendingPopup === request) {
      pendingPopup = null;
      if (!shown) void closeNativeExtensionPopup(windowId).catch(() => {});
    }
  }
}

export const showExtensionMenu = (windowId: string, ext: InstalledExtension) => nativeExtensionCommand({ command: "menu", windowId, id: ext.id });

function message(error: unknown): string {
  if (error instanceof ExtensionError) return error.message;
  return error instanceof Error ? error.message : String(error);
}

if (__DEV__) (globalThis as { acExtensionsUi?: unknown }).acExtensionsUi = { useExtensions, confirmInstall, cancelInstall, activateExtension };
