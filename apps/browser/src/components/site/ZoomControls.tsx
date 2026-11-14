import { useState } from "react";
import { StyleSheet, View } from "react-native";
import { NativePanelView, windowShellActive } from "@solara/settings";
import { useTheme } from "../../lib/theme";
import { webviews } from "../../lib/webviews";
import { useTab, useWindowId } from "../../store/hooks";
import { useNativePaneOverlay, usePageFrame } from "../layout/nativePaneOverlays";
import { setPopover } from "../layout/pageState";

export const ZOOM_POPOVER_WIDTH = 236;

export function ZoomPopover({ tabId, right, left, top, nativeAllowed = true }: { tabId: string; right?: number; left?: number; top: number; nativeAllowed?: boolean }) {
  const theme = useTheme();
  const zoom = useTab(tabId)?.zoom ?? 1;
  const windowId = useWindowId();
  const [inShell] = useState(() => nativeAllowed && windowShellActive(windowId));
  const { frame, ref, onLayout } = usePageFrame();
  const panelTheme = { textPrimary: theme.textPrimary, textSecondary: theme.textSecondary, toolbarHover: theme.toolbarHover, toolbarPressed: theme.toolbarPressed, icon: theme.icon };
  const popover = { width: ZOOM_POPOVER_WIDTH, top, right: right ?? null, left: left ?? null };
  useNativePaneOverlay(inShell, windowId, tabId, "zoom", frame ? { zoom, dark: !!theme.dark, theme: panelTheme, popover, frame } : null);
  if (inShell) return <View ref={ref} pointerEvents="none" collapsable={false} onLayout={onLayout} style={StyleSheet.absoluteFill} />;
  return (
    <NativePanelView
      kind="zoom"
      style={StyleSheet.absoluteFill}
      pointerEvents="box-none"
      state={JSON.stringify({
        zoom,
        dark: !!theme.dark,
        theme: panelTheme,
        popover,
      })}
      onPanelEvent={(e) => {
        if (e.nativeEvent.kind === "dismiss") return setPopover(tabId, null);
        if (e.nativeEvent.kind === "step") void webviews.get(tabId)?.zoomStep(Math.sign(Number(e.nativeEvent.step)) as -1 | 0 | 1);
      }}
    />
  );
}
