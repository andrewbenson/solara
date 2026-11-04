import { requireOptionalNativeModule } from "expo-modules-core";
import { encodeCommand } from "@solara/store";
import { useBrowser } from "./browser";
import { nativeOwnsWorkspace, nativeWrite, writeState } from "./nativeStore";
import { choose, type Settings } from "./settings";
import type { BrowserWindow } from "./types";

export const SIDEBAR_RAIL_WIDTH = 84;
export const SIDEBAR_DEFAULT_WIDTH = 190;
export const SIDE_PANEL_DEFAULT_WIDTH = 360;

export const nativeSidebarRailSupported = requireOptionalNativeModule<{ sidebarRail?: boolean }>("SolaraApp")?.sidebarRail === true;

type SidebarWindow = Pick<BrowserWindow, "sidebarWidth" | "sidebarIconsOnly" | "sidePanelWidth"> | undefined;
export type WindowSidebarPatch = Pick<BrowserWindow, "sidebarWidth" | "sidebarIconsOnly" | "sidePanelWidth">;

export function sidebarIconsOnlyOf(window: SidebarWindow, settings: Pick<Settings, "sidebarIconsOnly">): boolean {
  return window?.sidebarIconsOnly ?? settings.sidebarIconsOnly ?? false;
}

export function sidebarWidthOf(window: SidebarWindow, settings: Pick<Settings, "sidebarWidth" | "sidebarIconsOnly">, nativeShell: boolean, supported = nativeSidebarRailSupported): number {
  return sidebarIconsOnlyOf(window, settings) && supported && nativeShell ? SIDEBAR_RAIL_WIDTH : (window?.sidebarWidth ?? settings.sidebarWidth ?? SIDEBAR_DEFAULT_WIDTH);
}

export function sidePanelWidthOf(window: SidebarWindow, settings: Pick<Settings, "extensionSidePanelWidth">): number {
  return window?.sidePanelWidth ?? settings.extensionSidePanelWidth ?? SIDE_PANEL_DEFAULT_WIDTH;
}

export function useEffectiveSidebarWidth(windowId: string, nativeShell: boolean): number {
  return useBrowser((s) => sidebarWidthOf(s.windows[windowId], s.settings, nativeShell));
}

export function setWindowSidebar(windowId: string, patch: WindowSidebarPatch) {
  if (nativeOwnsWorkspace()) return nativeWrite(encodeCommand("setWindowSidebar", [windowId, patch]));
  return writeState(useBrowser, (s) => {
    const window = s.windows[windowId];
    if (!window || window.kind === "small") return {};
    const windows = { ...s.windows };
    const settings: Partial<Settings> = {};
    for (const key of ["sidebarWidth", "sidebarIconsOnly", "sidePanelWidth"] as const) {
      const value = patch[key];
      if (value === undefined) continue;
      for (const [id, other] of Object.entries(windows)) {
        if (id === windowId || other.kind === "small" || other[key] !== undefined) continue;
        const effective = key === "sidebarIconsOnly" ? sidebarIconsOnlyOf(other, s.settings) : key === "sidePanelWidth" ? sidePanelWidthOf(other, s.settings) : sidebarWidthOf(other, s.settings, false);
        windows[id] = { ...other, [key]: effective };
      }
      windows[windowId] = { ...windows[windowId]!, [key]: value };
      Object.assign(settings, { [key === "sidePanelWidth" ? "extensionSidePanelWidth" : key]: value });
    }
    return { windows, settings: choose(s.settings, settings) };
  });
}

export function setSidebarIconsOnly(windowId: string, on: boolean) {
  return setWindowSidebar(windowId, { sidebarIconsOnly: on });
}

export function toggleSidebarIconsOnly(windowId: string) {
  const s = useBrowser.getState();
  return setSidebarIconsOnly(windowId, !sidebarIconsOnlyOf(s.windows[windowId], s.settings));
}

export function commitSidebarWidth(windowId: string, width: number, nativeShell = true) {
  return setWindowSidebar(windowId, { sidebarWidth: width, ...(nativeShell ? { sidebarIconsOnly: false } : {}) });
}
