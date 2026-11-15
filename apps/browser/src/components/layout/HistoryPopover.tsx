import { useEffect, useMemo, useState } from "react";
import { Image, StyleSheet, View } from "react-native";
import { NativePanelView, windowShellActive, windowNativeLayout, type NativePanelEvent } from "@solara/settings";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { openModeFor, openUrl } from "../bookmarks/actions";
import { openInternalPage } from "../pages/urls";
import { NEW_TAB_MARK } from "../primitives";
import { PANEL, POPOVER_MARGIN } from "./controls";
import { closeHistoryMenu, goToHistoryItem, useHistoryMenu, type HistoryItem } from "./history";
import { useNativePaneHandler, useNativePaneOverlay, usePageFrame } from "./nativePaneOverlays";

const WIDTH = 300;
const FAVICON_X = PANEL.inset + (PANEL.iconSlot - 16) / 2;

export function HistoryPopover(props: { tabId: string; windowId: string; anchors: { back: number; forward: number }; nativeAllowed?: boolean }) {
  const [native] = useState(() => windowNativeLayout(props.windowId));
  return native ? null : <LegacyHistoryPopover {...props} />;
}

function LegacyHistoryPopover({ tabId, windowId, anchors, nativeAllowed = true }: { tabId: string; windowId: string; anchors: { back: number; forward: number }; nativeAllowed?: boolean }) {
  const menu = useHistoryMenu((s) => (s.menu?.tabId === tabId ? s.menu : null));
  const theme = useTheme();
  const profileId = useBrowser((s) => s.tabs[tabId]?.profileId ?? "");
  const favicons = useMemo(() => {
    if (!menu) return new Map<string, string | null>();
    const history = useBrowser.getState().history[profileId] ?? [];
    const urls = new Set(menu.items.map((i) => i.url));
    return new Map(history.filter((h) => urls.has(h.url)).map((h) => [h.url, h.favicon]));
  }, [menu, profileId]);
  const [inShell] = useState(() => nativeAllowed && windowShellActive(windowId));
  const { frame, ref, onLayout } = usePageFrame();
  useEffect(() => () => void (useHistoryMenu.getState().menu?.tabId === tabId && closeHistoryMenu()), [tabId]);
  const left = menu ? Math.max(POPOVER_MARGIN, (menu.direction < 0 ? anchors.back : anchors.forward) - FAVICON_X - 2) : 0;
  const panelState = menu && {
    items: menu.items.map((item) => ({ title: item.title, url: item.url, favicon: favicons.get(item.url) ?? null, newTab: item.offset === "newTab" })),
    profileId,
    dark: !!theme.dark,
    theme: { textPrimary: theme.textPrimary, textSecondary: theme.textSecondary, icon: theme.icon },
    newTabMark: Image.resolveAssetSource(NEW_TAB_MARK)?.uri ?? null,
    popover: { width: WIDTH, top: POPOVER_MARGIN, left },
  };
  const open = (item: HistoryItem, e: { metaKey?: boolean; shiftKey?: boolean; altKey?: boolean; middle?: boolean }) => {
    const mode = openModeFor(e);
    if (mode === "current" || mode === "split" || !item.url) {
      closeHistoryMenu();
      return void goToHistoryItem(tabId, item);
    }
    if (mode !== "background") closeHistoryMenu();
    openUrl(item.url, windowId, mode);
  };

  const onPanelEvent = (ev: { kind: string; index?: unknown; metaKey?: unknown; shiftKey?: unknown; altKey?: unknown; middle?: unknown }) => {
    if (!menu) return;
    if (ev.kind === "dismiss") return closeHistoryMenu();
    if (ev.kind === "fullHistory") {
      closeHistoryMenu();
      return openInternalPage("history", windowId);
    }
    const item = menu.items[Number(ev.index)];
    if (item) open(item, { metaKey: !!ev.metaKey, shiftKey: !!ev.shiftKey, altKey: !!ev.altKey, middle: !!ev.middle });
  };
  useNativePaneOverlay(inShell, windowId, tabId, "history", panelState && frame ? { ...panelState, frame } : null);
  useNativePaneHandler("history", inShell, windowId, tabId, onPanelEvent);
  if (!menu) return null;
  if (inShell) return <View ref={ref} pointerEvents="none" collapsable={false} onLayout={onLayout} style={StyleSheet.absoluteFill} />;

  return (
    <NativePanelView
      kind="history"
      style={StyleSheet.absoluteFill}
      pointerEvents="box-none"
      state={JSON.stringify(panelState)}
      onPanelEvent={(e) => onPanelEvent(e.nativeEvent as NativePanelEvent & { index?: unknown })}
    />
  );
}
