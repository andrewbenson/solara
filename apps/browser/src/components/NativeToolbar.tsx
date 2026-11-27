import { create } from "zustand";
import { NativeToolbarView, onPopupCountsChanged, popupCounts, type ToolbarClick } from "@solara/settings";
import { WindowDragRegion } from "@solara/shell";
import { useEffect, useRef } from "react";
import { useShallow } from "zustand/react/shallow";
import { findNodeHandle, Image, StyleSheet, View } from "react-native";
import { layout, useTheme } from "../lib/theme";
import { webviews } from "../lib/webviews";
import { usePageProgress } from "../store/pageProgress";
import { type ToolbarGeometry } from "./layout/geometry";
import { closeHistoryMenu, goBack, goForward, openHistoryMenu, useHistoryMenu } from "./layout/history";
import { usePage, usePages } from "./layout/pageState";
import { toolbarPalette } from "./layout/toolbarColors";
import { setToolbarExtensionsWidth } from "./layout/windowLayout";
import { endUrlEdit, useUrlEdit } from "./site/developerMode";
import { claimFocusTag, urlEditFocus } from "../lib/focusClaims";
import { insecureLevel } from "./Toolbar";
import { UPDATE_PILL_SHORT_TEXT, UPDATE_PILL_TEXT, updatePillTooltip, usePendingUpdate } from "../lib/pendingUpdate";



const LIGHT_STRIPES = require("../../assets/developer-stripes-light.png");
const DARK_STRIPES = require("../../assets/developer-stripes-dark.png");
const usePopupCounts = create<Record<string, number>>(() => popupCounts());
onPopupCountsChanged((counts) => usePopupCounts.setState(counts, true));

type NativeToolbarProps = {
  tabId: string;
  geometry: ToolbarGeometry;
  windowId: string;
  inSplit: boolean;
  focused: boolean;
  bare?: boolean;
  windowToolbar?: boolean;
  sidebar?: { extensionLimit: number; look: { resting: string; stroke: string; hover: string; placeholder: string; prompt: string } };
};

export function NativeToolbar(props: NativeToolbarProps) {
  const view = useRef<View>(null);
  const { json, onClick, onAnchors } = useNativeToolbarModel(props, () => findNodeHandle(view.current));

  return (
    <View style={{ height: layout.toolbarHeight }}>
      <WindowDragRegion style={StyleSheet.absoluteFill} />
      <View ref={view} collapsable={false} style={StyleSheet.absoluteFill} pointerEvents="box-none">
        <NativeToolbarView
          style={StyleSheet.absoluteFill}
          input={json}
          onToolbarClick={(e) => void onClick(e.nativeEvent)}
          onToolbarAnchors={(e) => onAnchors(e.nativeEvent.anchors)}
        />
      </View>
    </View>
  );
}

export function useNativeToolbarModel({ tabId, geometry, windowId, focused, bare, windowToolbar, sidebar }: NativeToolbarProps, focusHandle: () => number | null) {
  const theme = useTheme();
  const fullscreenTabs = usePages(useShallow((s) => Object.keys(s.pages).filter((id) => s.pages[id]?.fullscreen)));
  const historyHeld = useHistoryMenu((s) => s.menu?.tabId === tabId);
  const pending = usePendingUpdate();
  const insecure = usePage(tabId, insecureLevel);
  const editing = useUrlEdit((u) => u.tabId === tabId);
  const editRequest = useUrlEdit((u) => u.tabId === tabId ? u.request : 0);
  useEffect(() => () => endUrlEdit(tabId), [tabId]);
  const popups = usePopupCounts((counts) => counts[tabId] ?? 0);
  const capture = usePage(tabId, (p) => p.mediaAccess);
  const newTabShown = usePage(tabId, (p) => !!p.newTabShown);
  const backToNewTab = usePage(tabId, (p) => p.backToNewTab);
  const historyKnown = usePage(tabId, (p) => p.historyKnown);
  const popover = usePages((p) => p.popover[tabId] ?? null);
  const progress = usePageProgress(tabId);
  const json = JSON.stringify({
    windowId, tabId, geometry, bare: !!bare, windowToolbar: !!windowToolbar, fullscreenTabs, historyHeld, card: theme.card,
    palette: toolbarPalette(theme, null), accent: theme.accent, dark: !!theme.dark,
    lightStripes: Image.resolveAssetSource(LIGHT_STRIPES)?.uri ?? null,
    darkStripes: Image.resolveAssetSource(DARK_STRIPES)?.uri ?? null,
    sidebar: sidebar?.look, extensionLimit: sidebar?.extensionLimit,
    hints: {}, insecure, editing, editRequest, popups, capture, popover, progress,
    newTabShown, backToNewTab, historyKnown,
    update: pending ? { text: UPDATE_PILL_TEXT, short: UPDATE_PILL_SHORT_TEXT, tooltip: updatePillTooltip(pending) } : null,
  });

  const onClick = async (c: ToolbarClick) => {
    if (c.tabId !== undefined && c.tabId !== tabId) return;
    if (c.id === "urlEdit") {
      if (c.kind === "focus") return claimFocusTag(windowId, urlEditFocus(tabId), focusHandle);
      endUrlEdit(tabId);
      if (c.kind !== "blur") void webviews.get(tabId)?.focus();
      return;
    }
    if (c.id === "back" || c.id === "forward") {
      const direction = c.id === "back" ? -1 : 1;
      if (c.kind === "menu") {
        const open = useHistoryMenu.getState().menu;
        if (open?.tabId === tabId && open.direction === direction) return closeHistoryMenu();
        return void openHistoryMenu(tabId, direction);
      }
      closeHistoryMenu();
      if (!c.meta && c.kind !== "middle" && !c.shift) return direction < 0 ? goBack(tabId) : goForward(tabId);
      return;
    }
  };

  const onAnchors = ({ toolbarExtensionsWidth }: Record<string, [number, number, number, number]>) => {
    if (toolbarExtensionsWidth && !sidebar && focused) setToolbarExtensionsWidth(windowId, toolbarExtensionsWidth[2]);
  };

  return { json, onClick, onAnchors };
}
