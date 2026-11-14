import { hostedKinds, publishSettingsTopic } from "@solara/settings";
import { useEffect, useRef, useState } from "react";
import { Animated } from "react-native";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { nativeSidebarShell } from "../sidebar/NativeSidebar";
import { dismissHoverIn } from "../sidebar/hover";
import { setDockMoving, setPeekShown } from "./dockMotion";

const TOPIC = "sidebar.dock";
const states: Record<string, string> = {};
const listeners = new Map<string, (value: number, moving: boolean) => void>();

export type NativeDockState = {
  open: boolean;
  arc: boolean;
  fullscreen: boolean;
  topTabs: boolean;
  width: number;
  held: boolean;
  slideSwitch: boolean;
  lights: readonly [number, number];
  look: { fill: string; border: string; shadowOpacity: number };
};

export function nativeDockIn(windowId: string): boolean {
  return nativeSidebarShell(windowId) && hostedKinds().includes(TOPIC);
}

function publish(windowId: string, state: string | null) {
  if (state) states[windowId] = state;
  else if (states[windowId]) delete states[windowId];
  else return;
  publishSettingsTopic(TOPIC, { windows: states });
}

addNativeSettingsHandlers({
  [TOPIC]: (windowId: string, event: string, extra: { value?: number; moving?: boolean; live?: boolean; right?: number; rect?: [number, number, number, number] | null }) => {
    if (event === "dock") {
      setDockMoving(windowId, !!extra.moving);
      listeners.get(windowId)?.(extra.value ?? 0, !!extra.moving);
    } else if (event === "peek") {
      setPeekShown(windowId, !!extra.live, extra.right ?? 0, extra.rect ?? undefined);
      dismissHoverIn(windowId);
    } else if (event === "slideOut") dismissHoverIn(windowId);
  },
});

export function useNativeDockState(windowId: string, state: NativeDockState) {
  const json = JSON.stringify(state);
  useEffect(() => publish(windowId, json), [windowId, json]);
  useEffect(() => () => publish(windowId, null), [windowId]);
}

export function useNativeDock(windowId: string, open: boolean, active: boolean): { dock: Animated.Value; away: boolean } {
  const dock = useRef(new Animated.Value(open ? 1 : 0)).current;
  const [away, setAway] = useState(!open);
  const latestOpen = useRef(open);
  latestOpen.current = open;
  useEffect(() => {
    if (!active) return;
    dock.setValue(latestOpen.current ? 1 : 0);
    setAway(!latestOpen.current);
    listeners.set(windowId, (value, moving) => {
      dock.setValue(value);
      setAway(!moving && !latestOpen.current);
    });
    return () => {
      listeners.delete(windowId);
      setDockMoving(windowId, false);
      setPeekShown(windowId, false);
    };
  }, [windowId, dock, active]);
  useEffect(() => {
    if (active && open) setAway(false);
  }, [open, active]);
  return { dock, away };
}
