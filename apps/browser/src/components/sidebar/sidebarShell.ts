import { hostedKinds, profilePagerNative, windowShellActive } from "@solara/settings";

export function nativeSidebarShell(windowId: string): boolean {
  return hostedKinds().includes("sidebar.shell") && windowShellActive(windowId) && profilePagerNative(windowId);
}
