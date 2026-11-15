import { setWindowShellLayout, windowShellActive } from "@solara/settings";
import { useEffect, useState } from "react";
import type { Animated } from "react-native";


type ShellLayout = { sidebarWidth: number; topTabs: boolean; fullscreen: boolean; addressBarInSidebar: boolean; away: boolean; peekRight?: number };

export const current = (value: Animated.Value) => (value as unknown as { __getValue(): number }).__getValue();

export function nextFrame(push: () => void): () => void {
  let pending = false;
  return () => {
    if (pending) return;
    pending = true;
    requestAnimationFrame(() => {
      pending = false;
      push();
    });
  };
}

export function useShellLayoutPush(windowId: string, dock: Animated.Value, layout: ShellLayout, nativeDock = false) {
  const [shell] = useState(() => windowShellActive(windowId));
  useEffect(() => {
    if (!shell || nativeDock) return;
    const sub = dock.addListener(nextFrame(() => void setWindowShellLayout(windowId, { dock: current(dock) })));
    return () => dock.removeListener(sub);
  }, [shell, nativeDock, windowId, dock]);
  const { sidebarWidth, topTabs, fullscreen, addressBarInSidebar, away } = layout;
  const peekRight = layout.peekRight ?? 0;
  useEffect(() => {
    if (!shell) return;
    requestAnimationFrame(() =>
      void setWindowShellLayout(windowId, nativeDock ? { sidebarWidth, topTabs, fullscreen, addressBarInSidebar } : { dock: current(dock), sidebarWidth, topTabs, fullscreen, addressBarInSidebar, away, peekRight }),
    );
  }, [shell, nativeDock, windowId, dock, sidebarWidth, topTabs, fullscreen, addressBarInSidebar, away, peekRight]);
}

export { useNativeWindowAnchors } from "./nativeWindowAnchors";
