import type { InstalledExtension, ExtensionPackage } from "@solara/solaracore";
import { type SettingsHandler } from "@solara/settings";
import { openPinDialog, addFromWebStore, refreshExtensionsAfterChange, useExtensions } from "../../extensions/state";
import { SETTINGS_WINDOW_ID } from "../windows";

export const extensionsHandlers: Record<string, SettingsHandler> = {
  "extensions.installReady": (windowId: string, profile: string, pkg: ExtensionPackage) => useExtensions.setState({ install: { windowId, profile, source: "unpacked", status: "ready", pkg } }),
  "extensions.installError": (windowId: string, profile: string, source: "webStore" | "unpacked", error: string) => useExtensions.setState({ install: { windowId, profile, source, status: "error", error, ...(source === "webStore" ? { pkg: { name: "Extension", version: "", description: "", manifestVersion: 3, icon: null, permissions: [], optionalPermissions: [], hostPermissions: [], hasAction: false, popup: null, optionsPage: null, sidePanel: null, path: "" } } : {}) } }),
  "extensions.pin": (windowId: string) => openPinDialog(windowId),
  "extensions.catalog": (lists: Record<string, InstalledExtension[]>) => useExtensions.setState({ lists }),
  "extensions.refresh": (profile: string) => void refreshExtensionsAfterChange(profile),
  "extensions.openWebStoreDetail": (url: string, profile: string) => addFromWebStore(SETTINGS_WINDOW_ID, url, profile),
};
