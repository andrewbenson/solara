import { useEffect, useMemo, useRef, type RefObject } from "react";
import { NativeSidebarAddressBarView, setSidebarAddressBar, type ToolbarClick } from "@solara/settings";
import { StyleSheet } from "react-native";
import { useShortcutHint, withShortcut } from "../../lib/commandShortcuts";
import { layout, useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { useActiveTabId, useWindowId } from "../../store/hooks";
import { extensionsFitting } from "../extensions/ToolbarExtensionHost";
import { toolbarPalette } from "../layout/toolbarColors";
import { addressBarInSidebar, setUrlAnchor } from "../layout/windowLayout";
import { GLYPH } from "../Toolbar";
import { useNativeToolbarModel } from "../NativeToolbar";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";

const PLATE = 32;
const PLATE_RADIUS = 6;
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
const SIDEBAR_PLATE = { box: PLATE, radius: PLATE_RADIUS };
const SIDEBAR_GEOMETRY = (toggle: boolean) => ({ sidebarButton: toggle ? 0 : null, back: 0, forward: 0, reload: 0, urlLeft: 0 });

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
  const tabId = useActiveTabId() ?? "";
  const theme = useTheme();
  const toggle = useBrowser((s) => s.settings.showSidebarButton !== false);
  const sidebarHint = useShortcutHint("toggleSidebar");
  const extensionLimit = extensionsFitting(width - 2 * layout.sidebarInset - 10 - 3 - HOST_ROOM);
  const geometry = useMemo(() => SIDEBAR_GEOMETRY(toggle), [toggle]);
  const model = useNativeToolbarModel({ tabId, geometry, windowId, inSplit: false, focused: true, sidebar: { extensionLimit } }, noFocusHandle);
  const palette = toolbarPalette(theme, null);
  const { state } = model;
  const page = !!model.tab?.url;
  const json = useMemo(
    () =>
      JSON.stringify({
        palette: state?.palette ?? palette,
        accent: theme.accent,
        look: { resting: theme.pinnedResting, stroke: theme.pinnedRestingStroke, hover: theme.tabHover, placeholder: theme.placeholder, prompt: "Search or enter address" },
        buttons: [
          ...(toggle ? [{ id: "sidebar", icon: "sidebar.left", size: GLYPH, ...SIDEBAR_PLATE, tooltip: withShortcut("Auto-Hide Tabs", sidebarHint) }] : []),
          ...(state ? state.left.filter((b) => b.id !== "sidebar").map((b) => ({ ...b, ...SIDEBAR_PLATE })) : []),
        ],
        url: page ? state?.url ?? null : null,
        extensions: page ? state?.extensions ?? [] : [],
        progress: state?.progress ?? null,
      }),
    [state, palette, theme, toggle, sidebarHint, page],
  );
  const handlers = useRef<AddressBarHandlers>({ onClick: () => undefined, onAnchors: () => undefined });
  handlers.current = {
    onClick: (c) => {
      if (c.id === "sidebar") return useBrowser.getState().toggleSidebar(windowId);
      if (c.id === "url" && !page) return c.kind === "press" ? useBrowser.getState().openPanel(windowId, "") : undefined;
      return model.onClick(c);
    },
    onAnchors: ({ field, ...extensions }) => {
      if (field && field[2] && addressBarInSidebar(useBrowser.getState(), windowId)) setUrlAnchor(windowId, { left: field[0], top: field[1], width: field[2], sidebar: { height: field[3] } });
      model.onAnchors(extensions);
    },
  };
  useEffect(() => {
    addressBarHandlers.set(windowId, handlers);
    return () => {
      if (addressBarHandlers.get(windowId) === handlers) addressBarHandlers.delete(windowId);
    };
  }, [windowId]);
  useEffect(() => setSidebarAddressBar(windowId, json), [windowId, json]);
  useEffect(() => () => setSidebarAddressBar(windowId, null), [windowId]);
  return windowId;
}
