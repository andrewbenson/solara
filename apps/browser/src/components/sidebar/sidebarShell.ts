import { hostedKinds, profilePagerNative, windowNativeLayout, windowShellActive } from "@solara/settings";

export function nativeSidebarShell(windowId: string): boolean {
  return windowNativeLayout(windowId) || hostedKinds().includes("sidebar.shell") && windowShellActive(windowId) && profilePagerNative(windowId);
}
