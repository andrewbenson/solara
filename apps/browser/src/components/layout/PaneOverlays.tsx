import { SolaraHostedView, windowShellActive } from "@solara/settings";
import { memo, useState } from "react";
import { StyleSheet, View } from "react-native";
import { useTheme } from "../../lib/theme";
import { usePage } from "./pageState";
import { useNativeSadTab, usePageFrame } from "./nativePaneOverlays";
import { useWindowId } from "../../store/hooks";
import { sadTabHostState } from "./sadTabState";

export function StatusBubble({ tabId, windowId }: { tabId: string; windowId: string }) {
  const dark = useTheme().dark;
  const text = usePage(tabId, (p) => p.status);
  const state = JSON.stringify({ text, dark });
  return <SolaraHostedView kind="statusBubble" windowId={windowId} state={state} pointerEvents="none" style={StyleSheet.absoluteFill} />;
}

export const SadTab = memo(function SadTab({ tabId, nativeAllowed = true }: { tabId: string; nativeAllowed?: boolean }) {
  const theme = useTheme();
  const windowId = useWindowId();
  const [native] = useState(() => nativeAllowed && windowShellActive(windowId));
  const crashed = usePage(tabId, (p) => !!p.crashed);
  const unresponsive = usePage(tabId, (p) => p.unresponsive);
  const mode = crashed ? "crashed" : unresponsive ? "unresponsive" : null;
  const { frame, ref, onLayout } = usePageFrame();
  useNativeSadTab(native, windowId, tabId, mode, frame, theme);
  if (native) return mode ? <View ref={ref} pointerEvents="none" collapsable={false} onLayout={onLayout} style={StyleSheet.absoluteFill} /> : null;
  if (!mode) return null;
  return <SolaraHostedView kind="sadTab" windowId={windowId} state={JSON.stringify(sadTabHostState(tabId, crashed, unresponsive, theme))} style={StyleSheet.absoluteFill} />;
});
