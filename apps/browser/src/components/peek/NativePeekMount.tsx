import { closeWindowPeek, expandWindowPeek, publishSettingsTopic, windowNativeLayout } from "@solara/settings";
import { useEffect, useRef, useState } from "react";
import { AccessibilityInfo } from "react-native";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { useTabLive } from "../../store/hooks";
import { usePageProgress } from "../../store/pageProgress";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { nativePeekState, onNativePeekEvent, registerNativePeek, type NativePeekEvent } from "./nativePeek";

const states: Record<string, string> = {};
const handlers = new Map<string, (event: NativePeekEvent) => void>();
let queued = false;
let reduceMotion = false;
void AccessibilityInfo.isReduceMotionEnabled().then(
  (on) => (reduceMotion = on),
  () => {},
);
AccessibilityInfo.addEventListener("reduceMotionChanged", (on) => (reduceMotion = on));

function publish() {
  if (queued) return;
  queued = true;
  queueMicrotask(() => {
    queued = false;
    publishSettingsTopic("peek.state", { windows: states });
  });
}

addNativeSettingsHandlers({
  "peek.event": (windowId: string, event: NativePeekEvent) => handlers.get(windowId)?.(event),
});

export function NativePeekMount({ windowId, origin, fullscreen }: { windowId: string; origin: { x: number; y: number } | null; fullscreen: boolean }) {
  const [nativeLayout] = useState(() => windowNativeLayout(windowId));
  const tabId = useBrowser((s) => s.peeks[windowId]?.tabId);
  useEffect(() => {
    handlers.set(windowId, (event) => onNativePeekEvent(windowId, event));
    const unregister = registerNativePeek(windowId, {
      close: () => {
        const tabId = useBrowser.getState().peeks[windowId]?.tabId;
        if (tabId) void closeWindowPeek(windowId, tabId);
      },
      expand: (done) => {
        const tabId = useBrowser.getState().peeks[windowId]?.tabId;
        if (tabId) void expandWindowPeek(windowId, tabId).then((accepted) => { if (accepted) done(); }, () => {});
      },
    });
    return () => {
      unregister();
      handlers.delete(windowId);
      if (!nativeLayout) {
        delete states[windowId];
        publish();
      }
    };
  }, [windowId, nativeLayout]);
  useEffect(() => {
    if (nativeLayout || tabId) return;
    states[windowId] = "";
    publish();
  }, [windowId, tabId, nativeLayout]);
  return !nativeLayout && tabId && origin ? <NativePeekState key={tabId} windowId={windowId} tabId={tabId} origin={origin} fullscreen={fullscreen} /> : null;
}

function NativePeekState({ windowId, tabId, origin, fullscreen }: { windowId: string; tabId: string; origin: { x: number; y: number }; fullscreen: boolean }) {
  const theme = useTheme();
  useBrowser((s) => s.tabs[tabId]);
  useBrowser((s) => s.peeks[windowId]);
  const loading = useTabLive(tabId, (live) => live.isLoading);
  const progress = usePageProgress(tabId);
  const last = useRef("");
  const state = nativePeekState(windowId, theme, origin, fullscreen, reduceMotion, loading ? Math.max(progress, 0.08) : null);
  useEffect(() => {
    if (state === last.current) return;
    last.current = state;
    states[windowId] = state;
    publish();
  });
  return null;
}
