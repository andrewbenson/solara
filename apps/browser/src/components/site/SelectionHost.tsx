import { SolaraHostedView, windowShellActive } from "@solara/settings";
import { memo, useState } from "react";
import { StyleSheet, View } from "react-native";
import { useTheme } from "../../lib/theme";
import { useWindowId } from "../../store/hooks";
import { useNativePaneOverlay, usePageFrame } from "../layout/nativePaneOverlays";

export const SelectionHost = memo(function SelectionHost({ tabId, nativeAllowed = true }: { tabId: string; nativeAllowed?: boolean }) {
  const theme = useTheme();
  const windowId = useWindowId();
  const [inShell] = useState(() => nativeAllowed && windowShellActive(windowId));
  const page = usePageFrame();
  const state = { tabId, dark: !!theme.dark, icon: theme.icon, textPrimary: theme.textPrimary };
  useNativePaneOverlay(inShell, windowId, tabId, "selection", page.frame ? { ...state, frame: page.frame } : null);
  if (inShell) return <View ref={page.ref} pointerEvents="none" collapsable={false} onLayout={page.onLayout} style={StyleSheet.absoluteFill} />;
  return <SolaraHostedView kind="selectionBar" windowId={windowId} state={JSON.stringify(state)} style={StyleSheet.absoluteFill} />;
});
