import { useEffect, useRef, type RefObject } from "react";
import { NativeSidebarAddressBarView, setSidebarAddressBar, type ToolbarClick } from "@solara/settings";
import { StyleSheet } from "react-native";
import { layout, useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { activeTabId } from "../../store/model";
import { useWindowId } from "../../store/hooks";
import { setUrlAnchor, useAddressBarInSidebar, useNativeWindowPreferences, useWindowReplicaFallback } from "../layout/windowLayout";
import { useNativeToolbarModel } from "../NativeToolbar";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";

const HOST_ROOM = 84;

export function SidebarAddressRow(_: { width: number }) {
  return null;
}

type AddressBarHandlers = { onClick: (c: ToolbarClick) => unknown; onAnchors: (anchors: Record<string, [number, number, number, number]>) => void };

const addressBarHandlers = new Map<string, RefObject<AddressBarHandlers>>();

addNativeSettingsHandlers({
  "sidebar.addressClick": (windowId: string, click: ToolbarClick) => {
    void addressBarHandlers.get(windowId)?.current?.onClick(click);
  },
  "sidebar.addressAnchors": (windowId: string, anchors: Record<string, [number, number, number, number]>) => {
    addressBarHandlers.get(windowId)?.current?.onAnchors(anchors);
  },
});

const noFocusHandle = () => null;
const SIDEBAR_GEOMETRY = { sidebarButton: null, back: 0, forward: 0, reload: 0, urlLeft: 0 };

export function SidebarHeaderTools({ width }: { width: number }) {
  const windowId = usePublishedSidebarAddressBar(width);
  return <NativeSidebarAddressBarView windowId={windowId} style={StyleSheet.absoluteFill} />;
}

export function SidebarAddressBarState({ width }: { width: number }) {
  usePublishedSidebarAddressBar(width);
  return null;
}

function usePublishedSidebarAddressBar(width: number): string {
  const windowId = useWindowId();
  const selected = useNativeWindowPreferences(windowId, (value) => value?.activeTabId);
  const fallback = useWindowReplicaFallback(windowId, (state) => activeTabId(state, windowId));
  const tabId = selected ?? fallback ?? "";
  const inSidebar = useAddressBarInSidebar();
  const theme = useTheme();
  const extensionLimit = Math.max(1, Math.floor((width - 2 * layout.sidebarInset - 10 - 3 - HOST_ROOM + 2) / 30));
  const look = { resting: theme.pinnedResting, stroke: theme.pinnedRestingStroke, hover: theme.tabHover, placeholder: theme.placeholder, prompt: "Search or enter address" };
  const model = useNativeToolbarModel({ tabId, geometry: SIDEBAR_GEOMETRY, windowId, inSplit: false, focused: true, sidebar: { extensionLimit, look } }, noFocusHandle);
  const handlers = useRef<AddressBarHandlers>({ onClick: () => undefined, onAnchors: () => undefined });
  handlers.current = {
    onClick: (c) => {
      if (c.tabId !== undefined && c.tabId !== tabId) return;
      if (c.id === "sidebar") return useBrowser.getState().toggleSidebar(windowId);
      if (c.id === "url" && !useBrowser.getState().tabs[tabId]?.url) return c.kind === "press" ? useBrowser.getState().openPanel(windowId, "") : undefined;
      return model.onClick(c);
    },
    onAnchors: ({ field, ...extensions }) => {
      if (field && field[2] && inSidebar) setUrlAnchor(windowId, { left: field[0], top: field[1], width: field[2], sidebar: { height: field[3] } });
      model.onAnchors(extensions);
    },
  };
  useEffect(() => {
    addressBarHandlers.set(windowId, handlers);
    return () => {
      if (addressBarHandlers.get(windowId) === handlers) addressBarHandlers.delete(windowId);
    };
  }, [windowId]);
  useEffect(() => setSidebarAddressBar(windowId, model.json), [windowId, model.json]);
  useEffect(() => () => setSidebarAddressBar(windowId, null), [windowId]);
  return windowId;
}
