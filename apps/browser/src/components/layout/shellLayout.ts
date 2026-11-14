import { observeWindowLayoutAnchors, windowLayoutAnchorsAvailable, setWindowShellLayout, windowShellActive, type WindowLayoutAnchors } from "@solara/settings";
import { useEffect, useState } from "react";
import type { Animated } from "react-native";

import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { applyNativeWindowAnchors, dropNativeWindowAnchors, nativeWindowAnchorFeed } from "./windowLayout";

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


let anchorReaderSequence = 0;

addNativeSettingsHandlers({
  "window.layoutAnchors": (windowId: string, batch: WindowLayoutAnchors) => {
    const accepted = nativeWindowAnchorFeed.event(windowId, batch);
    if (accepted) applyNativeWindowAnchors(accepted);
  },
});

export function useNativeWindowAnchors(windowId: string): boolean {
  const [native] = useState(() => windowLayoutAnchorsAvailable(windowId));
  useEffect(() => {
    if (!native) return;
    const owner = {};
    const reader = `${windowId}:${++anchorReaderSequence}`;
    let disposed = false;
    nativeWindowAnchorFeed.begin(windowId, owner);
    void observeWindowLayoutAnchors(windowId, true, reader).then((observation) => {
      if (!observation) return;
      if (disposed) return void observeWindowLayoutAnchors(windowId, false, reader, observation.windowGeneration);
      const accepted = nativeWindowAnchorFeed.initial(windowId, owner, observation);
      if (accepted) applyNativeWindowAnchors(accepted);
    });
    return () => {
      disposed = true;
      const generation = nativeWindowAnchorFeed.end(windowId, owner);
      if (generation === undefined) return;
      dropNativeWindowAnchors(windowId);
      if (generation !== null) void observeWindowLayoutAnchors(windowId, false, reader, generation);
    };
  }, [native, windowId]);
  return native;
}
