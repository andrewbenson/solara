import type { InstalledExtension } from "@solara/solaracore";
import { closeNativeExtensionPopup, nativeExtensionCommand, refreshNativeExtensionCatalog } from "@solara/settings";

export async function refreshExtensions(profile: string): Promise<InstalledExtension[]> {
  return JSON.parse(await refreshNativeExtensionCatalog(profile));
}

export const refreshExtensionsAfterChange = (profile: string) => refreshNativeExtensionCatalog(profile, true);
export const setEnabled = (profile: string, id: string, enabled: boolean) => nativeExtensionCommand({ command: "setEnabled", profile, id, enabled });
export const setPinned = (profile: string, id: string, pinned: boolean) => nativeExtensionCommand({ command: "setPinned", profile, id, pinned });
export const closeExtensionPopup = (windowId: string | null = null) => closeNativeExtensionPopup(windowId);
