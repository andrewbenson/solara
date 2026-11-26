import type { InstalledExtension, ActionState } from "@solara/solaracore";
import { type SettingsHandler } from "@solara/settings";
import { useBrowser } from "../../../store/browser";
import { resolveWindowId } from "../../../store/model";
import { addFromWebStore, closeExtensionPopup, closeSidePanelsOf, refreshExtensionsAfterChange, useExtensions, wantedSidePanels, syncSidePanel, extensionProfile } from "../../extensions/state";
import { SETTINGS_WINDOW_ID } from "../windows";

function openInNewTab(url: string) {
  const windowId = resolveWindowId(useBrowser.getState());
  if (windowId) useBrowser.getState().newTab(windowId, { url });
}

function closeSurfaces(id: string) {
  if (useExtensions.getState().popup?.extensionId === id) closeExtensionPopup();
  closeSidePanelsOf(id);
}

export const extensionsHandlers: Record<string, SettingsHandler> = {
  "extensions.catalog": (lists: Record<string, InstalledExtension[]>, actions: Record<number, Record<string, ActionState>>) => useExtensions.setState({ lists, actions }),
  "extensions.syncPanels": (profiles: string[] | null) => {
    const s = useBrowser.getState();
    for (const [windowId] of wantedSidePanels()) if (!profiles || profiles.includes(extensionProfile(s, windowId))) void syncSidePanel(windowId);
  },
  "extensions.refresh": (profile: string) => void refreshExtensionsAfterChange(profile),
  "extensions.closeSurfaces": (id: string) => closeSurfaces(id),
  "extensions.openWebStoreDetail": (url: string, profile: string) => addFromWebStore(SETTINGS_WINDOW_ID, url, profile),
  "extensions.openInNewTab": (url: string) => openInNewTab(url),
};

export function publishExtensions(): void {}
