import { useState } from "react";
import { StyleSheet, View } from "react-native";
import { NativePanelView, windowShellActive } from "@solara/settings";
import { useTheme } from "../../lib/theme";
import { useWindowId } from "../../store/hooks";
import { useNativePaneOverlay, usePageFrame } from "../layout/nativePaneOverlays";

export const ZOOM_POPOVER_WIDTH = 236;

export function ZoomPopover({ tabId, right, left, top, nativeAllowed = true }: { tabId: string; right?: number; left?: number; top: number; nativeAllowed?: boolean }) {
  const theme = useTheme();
  const windowId = useWindowId();
  const [inShell] = useState(() => nativeAllowed && windowShellActive(windowId));
  const { frame, ref, onLayout } = usePageFrame();
  const panelTheme = { textPrimary: theme.textPrimary, textSecondary: theme.textSecondary, toolbarHover: theme.toolbarHover, toolbarPressed: theme.toolbarPressed, icon: theme.icon };
  const popover = { width: ZOOM_POPOVER_WIDTH, top, right: right ?? null, left: left ?? null };
  useNativePaneOverlay(inShell, windowId, tabId, "zoom", frame ? { tabId, zoom: 1, dark: !!theme.dark, theme: panelTheme, popover, frame } : null);
  if (inShell) return <View ref={ref} pointerEvents="none" collapsable={false} onLayout={onLayout} style={StyleSheet.absoluteFill} />;
  return (
    <NativePanelView
      kind="zoom"
      style={StyleSheet.absoluteFill}
      pointerEvents="box-none"
      state={JSON.stringify({
        tabId,
        zoom: 1,
        dark: !!theme.dark,
        theme: panelTheme,
        popover,
      })}
    />
  );
}
