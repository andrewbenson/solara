import { hostedKinds, publishSettingsTopic } from "@solara/settings";
import { useEffect, useRef, useState } from "react";
import { Animated } from "react-native";
import { nativeSidebarShell } from "../sidebar/NativeSidebar";
import { setDockMoving, setPeekShown } from "./dockMotion";

const TOPIC = "sidebar.dock";
const states: Record<string, string> = {};
import { nativeDockListeners as listeners } from "./nativeDockEvents";

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
