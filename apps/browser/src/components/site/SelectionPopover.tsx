import { onHostedEvent, SolaraHostedView, windowShellActive } from "@solara/settings";
import { memo, useEffect, useState } from "react";
import { StyleSheet, View } from "react-native";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { defaultSearchEngine } from "../../store/settings";
import { useWindowId } from "../../store/hooks";
import { useNativePaneHandler, useNativePaneOverlay, usePageFrame, type PaneClick } from "../layout/nativePaneOverlays";
import { searchSelection, setPageSelection, usePageSelection, type PageSelection } from "./selection";

const SHOW_DELAY = 150;

export const SelectionPopover = memo(function SelectionPopover({ tabId, zoom, nativeAllowed = true }: { tabId: string; zoom: number; nativeAllowed?: boolean }) {
  const theme = useTheme();
  const windowId = useWindowId();
  const [inShell] = useState(() => nativeAllowed && windowShellActive(windowId));
  const page = usePageFrame();
  const engine = useBrowser((s) => defaultSearchEngine(s.settings).name);
  const enabled = useBrowser((s) => s.settings.showSelectionSearch);
  const selection = usePageSelection((s) => (enabled ? (s[tabId] ?? null) : null));
  const [shown, setShown] = useState<PageSelection | null>(null);
  useEffect(() => {
    if (!selection) return setShown(null);
    const timer = setTimeout(() => setShown(selection), SHOW_DELAY);
    return () => clearTimeout(timer);
  }, [selection]);
  useEffect(() => () => setPageSelection(tabId, null), [tabId]);
  const r = shown?.rect;
  const state = shown && r ? {
    key: `${r.x},${r.y}`,
    top: r.y * zoom,
    bottom: (r.y + r.height) * zoom,
    center: (r.x + r.width / 2) * zoom,
    dark: !!theme.dark,
    icon: theme.icon,
    textPrimary: theme.textPrimary,
    tooltip: searchTooltip(engine, shown.text),
    label: `Search ${engine}`,
  } : null;
  useNativePaneOverlay(inShell, windowId, tabId, "selection", state && page.frame ? { ...state, frame: page.frame } : null);
  useNativePaneHandler("selection", inShell, windowId, tabId, (click: PaneClick) => shown && searchSelection(tabId, shown.text, click));
  useEffect(() => {
    if (inShell) return;
    return onHostedEvent("selectionBar", windowId, (name, payload) => {
      if (name !== "search" || payload.tabId !== tabId || !shown) return;
      searchSelection(tabId, shown.text, { metaKey: !!payload.metaKey, shiftKey: !!payload.shiftKey, altKey: !!payload.altKey });
    });
  }, [inShell, windowId, tabId, shown]);
  if (!selection && !shown) return null;
  if (inShell) return <View ref={page.ref} pointerEvents="none" collapsable={false} onLayout={page.onLayout} style={StyleSheet.absoluteFill} />;
  return <SolaraHostedView kind="selectionBar" windowId={windowId} state={JSON.stringify({ tabId, selection: state })} style={StyleSheet.absoluteFill} />;
});

function searchTooltip(engine: string, text: string) {
  const quoted = text.length > 40 ? `${text.slice(0, 40).trimEnd()}…` : text;
  return `Search ${engine} for “${quoted.replace(/\s+/g, " ")}”`;
}
