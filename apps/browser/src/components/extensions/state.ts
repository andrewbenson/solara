import {
  configureExtension,
  ExtensionError,
  installExtension,
  resolveExtensionInstallPrompt,
  type ExtensionInstallPrompt,
  type ExtensionPackage,
  type InstalledExtension,
} from "@solara/solaracore";
import { nativeExtensionCommand, refreshNativeExtensionCatalog, closeNativeExtensionPopup } from "@solara/settings";
import { useExtensions, type Anchor } from "./store";

export * from "./sidePanels";
export * from "./store";

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

export const activateExtension = (windowId: string, ext: Pick<InstalledExtension, "id">, anchor?: Anchor, _state?: unknown, tabId?: string, { requiresActive = false }: { requiresActive?: boolean } = {}) =>
  nativeExtensionCommand({ command: "openExtension", windowId, id: ext.id, tabId, anchor, requiresActive });

export const closeExtensionPopup = (windowId: string | null = null) => closeNativeExtensionPopup(windowId);

export const showExtensionMenu = (windowId: string, ext: InstalledExtension) => nativeExtensionCommand({ command: "menu", windowId, id: ext.id });

function message(error: unknown): string {
  if (error instanceof ExtensionError) return error.message;
  return error instanceof Error ? error.message : String(error);
}

if (__DEV__) (globalThis as { acExtensionsUi?: unknown }).acExtensionsUi = { useExtensions, confirmInstall, cancelInstall, activateExtension };
