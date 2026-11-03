import { requireOptionalNativeModule } from "expo-modules-core";
import { useBrowser } from "./browser";
import type { Settings } from "./settings";

export const SIDEBAR_RAIL_WIDTH = 84;
export const SIDEBAR_DEFAULT_WIDTH = 190;

export const nativeSidebarRailSupported = requireOptionalNativeModule<{ sidebarRail?: boolean }>("SolaraApp")?.sidebarRail === true;

export function sidebarWidthOf(settings: Pick<Settings, "sidebarWidth" | "sidebarIconsOnly">, nativeShell: boolean, supported = nativeSidebarRailSupported): number {
  return settings.sidebarIconsOnly && supported && nativeShell ? SIDEBAR_RAIL_WIDTH : (settings.sidebarWidth ?? SIDEBAR_DEFAULT_WIDTH);
}

export function useEffectiveSidebarWidth(nativeShell: boolean): number {
  return useBrowser((s) => sidebarWidthOf(s.settings, nativeShell));
}

export function setSidebarIconsOnly(on: boolean) {
  const s = useBrowser.getState();
  if (s.settings.sidebarIconsOnly !== on) s.updateSettings({ sidebarIconsOnly: on });
}

export function toggleSidebarIconsOnly() {
  setSidebarIconsOnly(!useBrowser.getState().settings.sidebarIconsOnly);
}

export function commitSidebarWidth(width: number, nativeShell = true) {
  useBrowser.getState().updateSettings({ sidebarWidth: width, ...(nativeShell ? { sidebarIconsOnly: false } : {}) });
}
