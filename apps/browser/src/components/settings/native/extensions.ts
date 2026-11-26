import type { InstalledExtension, ExtensionPackage } from "@solara/solaracore";
import { type SettingsHandler } from "@solara/settings";
import { useBrowser } from "../../../store/browser";
import { activateExtension, findExtension, openPinDialog, toggleSidePanel, addFromWebStore, closeExtensionPopup, closeSidePanelsOf, refreshExtensionsAfterChange, useExtensions, wantedSidePanels, syncSidePanel, extensionProfile } from "../../extensions/state";
import { openExtensionFromMenu } from "../../extensions/bridge";
import { SETTINGS_WINDOW_ID } from "../windows";

function closeSurfaces(id: string) {
  if (useExtensions.getState().popup?.extensionId === id) closeExtensionPopup();
  closeSidePanelsOf(id);
}

function matchesMenuProfile(windowId: string, profileId?: string | null, engineProfile?: string | null) {
  if (profileId == null || engineProfile == null) return true;
  const state = useBrowser.getState();
  return state.windows[windowId]?.profileId === profileId && extensionProfile(state, windowId) === engineProfile;
}

export const extensionsHandlers: Record<string, SettingsHandler> = {
  "extensions.installReady": (windowId: string, profile: string, pkg: ExtensionPackage) => useExtensions.setState({ install: { windowId, profile, source: "unpacked", status: "ready", pkg } }),
  "extensions.installError": (windowId: string, profile: string, source: "webStore" | "unpacked", error: string) => useExtensions.setState({ install: { windowId, profile, source, status: "error", error, ...(source === "webStore" ? { pkg: { name: "Extension", version: "", description: "", manifestVersion: 3, icon: null, permissions: [], optionalPermissions: [], hostPermissions: [], hasAction: false, popup: null, optionsPage: null, sidePanel: null, path: "" } } : {}) } }),
  "extensions.pin": (windowId: string) => openPinDialog(windowId),
  "extensions.togglePanel": (windowId: string, id: string, profileId?: string | null, engineProfile?: string | null) => {
    if (matchesMenuProfile(windowId, profileId, engineProfile)) return toggleSidePanel(windowId, id);
  },
  "extensions.activate": (windowId: string, id: string, tabId: string | null, anchor: import("../../extensions/store").Anchor | null,
    profileId?: string | null, engineProfile?: string | null) => {
    if (!matchesMenuProfile(windowId, profileId, engineProfile)) return;
    if (!anchor) return openExtensionFromMenu(windowId, id, tabId ?? undefined);
    const ext = findExtension(extensionProfile(useBrowser.getState(), windowId), id);
    if (ext) return activateExtension(windowId, ext, anchor, undefined, tabId ?? undefined);
  },
  "extensions.catalog": (lists: Record<string, InstalledExtension[]>) => useExtensions.setState({ lists }),
  "extensions.syncPanels": (profiles: string[] | null) => {
    const s = useBrowser.getState();
    for (const [windowId] of wantedSidePanels()) if (!profiles || profiles.includes(extensionProfile(s, windowId))) void syncSidePanel(windowId);
  },
  "extensions.refresh": (profile: string) => void refreshExtensionsAfterChange(profile),
  "extensions.closeSurfaces": (id: string) => closeSurfaces(id),
  "extensions.openWebStoreDetail": (url: string, profile: string) => addFromWebStore(SETTINGS_WINDOW_ID, url, profile),
};
