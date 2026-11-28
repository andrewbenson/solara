import { SolaraHostedView, tabPool, windowNativeLayout, windowShellActive } from "@solara/settings";
import { memo, useEffect, useLayoutEffect, useMemo, useState } from "react";
import { Animated, StyleSheet, View, type ViewStyle } from "react-native";
import { layout } from "../lib/theme";
import { panePromptsNativeIn } from "../lib/pagesPool";
import { useBrowser } from "../store/browser";
import { shallowEqual, useTabValue } from "../store/tabWatch";
import { useActiveTabId } from "../store/hooks";
import { splitOf } from "../store/splits";
import type { Tab } from "../store/types";
import { CliControlPill } from "./CliControlPill";
import { FindBar } from "./FindBar";
import { POPOVER_MARGIN } from "./layout/controls";
import { NO_TOOLBAR, splitGeometry, toolbarGeometry, type ToolbarGeometry } from "./layout/geometry";
import { patchPage, useFullscreenTab, usePages } from "./layout/pageState";
import { SadTab, StatusBubble } from "./layout/PaneOverlays";
import { useNativePanePromptsPane } from "./layout/nativePaneOverlays";
import { markPaneRootDrawn, usePaneStatusStyle, usePopoversOverCard } from "./layout/paneFeed";
import { useAddressBarInSidebar, useTabLayout } from "./layout/windowLayout";
import { NewTabPage } from "./NewTabPage";
import { EmptyCard } from "./EmptyCard";
import { AutofillPrompt, PasswordPrompt } from "./site/Prompts";
import { SiteControls } from "./site/SitePanelHost";
import { ZOOM_POPOVER_WIDTH, ZoomPopover } from "./site/ZoomHost";
import { SelectionHost } from "./site/SelectionHost";
import { NavigationOverlays } from "./layout/SwipeOverlay";
import { isSmallWindow } from "../store/small";
import { PooledPageProps } from "./PooledPageProps";


export function PageOverlays({
  tabId,
  windowId,
  width,
  geometry,
  toolbar,
  fullscreen,
  newTabShown,
  statusStyle,
  popovers = true,
  cliPill = false,
  peek = false,
  nativePrompts = false,
}: {
  tabId: string;
  windowId: string;
  width: number;
  geometry: ToolbarGeometry;
  toolbar: boolean;
  fullscreen: boolean;
  newTabShown: boolean;
  statusStyle?: Animated.WithAnimatedValue<ViewStyle>;
  popovers?: boolean;
  cliPill?: boolean;
  peek?: boolean;
  nativePrompts?: boolean;
}) {
  const popover = usePages((s) => s.popover[tabId] ?? null);
  const zoom = useTabValue(tabId, (t) => t?.zoom ?? 1);
  const popoverSide = toolbar ? { right: POPOVER_MARGIN } : { left: POPOVER_MARGIN };
  const nativeCli = nativePrompts;
  useNativePanePromptsPane(windowId, tabId, nativePrompts, {
    urlLeft: geometry.urlLeft,
    newTabShown,
    popupSide: toolbar ? "right" : "left",
    ...(nativePrompts && {
      zoom,
      cliPill,
    }),
  });
  return (
    <>
      <FindBar tabId={tabId} />
      <Animated.View pointerEvents="none" style={[StyleSheet.absoluteFill, statusStyle]}>
        <StatusBubble tabId={tabId} windowId={windowId} />
      </Animated.View>
      {!nativePrompts && <SadTab tabId={tabId} nativeAllowed={!peek} />}
      {cliPill && !nativeCli && <CliControlPill tabId={tabId} style={statusStyle} nativeAllowed={!peek} />}
      {popovers && <SiteControls tabId={tabId} open={popover === "siteControls"} {...popoverSide} top={POPOVER_MARGIN} />}
      {popovers && popover === "zoom" && <ZoomPopover tabId={tabId} {...popoverSide} top={POPOVER_MARGIN} nativeAllowed={!peek} />}
      {!nativePrompts && <PasswordPrompt tabId={tabId} right={POPOVER_MARGIN} top={POPOVER_MARGIN} />}
      {!nativePrompts && <AutofillPrompt tabId={tabId} right={POPOVER_MARGIN} top={POPOVER_MARGIN} />}
      <SolaraHostedView kind="panePrompts" windowId={windowId} state={tabId} pointerEvents="box-none" style={StyleSheet.absoluteFill} />
      <SolaraHostedView kind="media.sharePicker" windowId={windowId} state={tabId} pointerEvents="box-none" style={StyleSheet.absoluteFill} />
      {(peek || !windowShellActive(windowId)) && <SolaraHostedView kind="media.castPicker" windowId={windowId} state={tabId} pointerEvents="box-none" style={StyleSheet.absoluteFill} />}
      <NavigationOverlays tabId={tabId} windowId={windowId} geometry={geometry} peek={peek} />
      {!nativePrompts && <SelectionHost tabId={tabId} nativeAllowed={!peek} />}
    </>
  );
}

export function PaneContent({ windowId, tabId, shown, nativeFallback = false }: { windowId: string; tabId: string; shown: boolean; nativeFallback?: boolean }) {
  const [width, setWidth] = useState(0);
  const split = useBrowser((s) => splitOf(s, tabId));
  const focused = useActiveTabId() === tabId;
  const fullscreenTab = useFullscreenTab(windowId);
  const tabLayout = useTabLayout();
  const addressInSidebar = useAddressBarInSidebar();
  const small = useBrowser((s) => isSmallWindow(s.windows[windowId]));
  const showSidebarButton = useBrowser((s) => s.settings.showSidebarButton !== false);
  const peekShown = useBrowser((s) => !!s.peeks[windowId]?.tabId);
  const [nativePrompts] = useState(() => panePromptsNativeIn(windowId));
  const [nativeLayout] = useState(() => windowNativeLayout(windowId));
  const statusStyle = usePaneStatusStyle(tabId);
  const overCard = usePopoversOverCard(windowId);
  const [feedOwner] = useState(() => ({}));
  const drawing = shown && width > 0 && !nativeFallback;
  useLayoutEffect(() => {
    if (!drawing) return;
    markPaneRootDrawn(tabId, feedOwner, true);
    return () => markPaneRootDrawn(tabId, feedOwner, false);
  }, [tabId, drawing]);
  const newTabShown = usePages((s) => !!s.pages[tabId]?.newTabShown);
  const fullscreen = fullscreenTab === tabId;
  const inSplit = !!split && !fullscreen;
  const leading = useMemo(() => {
    if (!split || fullscreen) return true;
    if (nativeLayout) return split.tabIds[0] === tabId;
    const rect = splitGeometry(split, 1000, 1000).panes[tabId];
    return !!rect && rect.x === 0 && rect.y === 0;
  }, [split, fullscreen, tabId, nativeLayout]);
  const toolbar = !addressInSidebar && !small;
  const sidebarButton = leading && tabLayout === "sidebar" && showSidebarButton;
  const geometry = useMemo(() => (!toolbar ? NO_TOOLBAR : toolbarGeometry({ sidebarButton })), [toolbar, sidebarButton]);
  return (
    <View pointerEvents="box-none" style={{ flex: 1 }} onLayout={(e) => setWidth(e.nativeEvent.layout.width)}>
      {nativeLayout && shown && (
        <NativePageContent windowId={windowId} tabId={tabId} inSplit={inSplit} toolbar={toolbar} />
      )}
      {width > 0 && (
        <PageOverlays
          tabId={tabId}
          windowId={windowId}
          width={width}
          geometry={geometry}
          toolbar={toolbar}
          fullscreen={fullscreen}
          newTabShown={newTabShown}
          statusStyle={statusStyle}
          popovers={overCard !== tabId}
          cliPill={!peekShown && (fullscreen || focused || !inSplit)}
          nativePrompts={nativePrompts}
        />
      )}
    </View>
  );
}

const NativePageContent = memo(function NativePageContent({ windowId, tabId, inSplit, toolbar }: { windowId: string; tabId: string; inSplit: boolean; toolbar: boolean }) {
  const own = useTabValue(tabId, paneTab, shallowEqual);
  const emptyCard = useBrowser((s) => s.settings.newTabOpens === "commandBar");
  useEffect(() => {
    if (!own.url) patchPage(tabId, { wasNewTab: true });
  }, [own.url, tabId]);
  return (
    <>
      {tabPool && <PooledPageProps pool={tabPool} tabId={tabId} />}
      {!own.url && !inSplit && (emptyCard ? <EmptyCard windowId={windowId} tabId={tabId} /> : <NewTabPage key={tabId} windowId={windowId} tabId={tabId} toolbar={toolbar} />)}
    </>
  );
});

export function BesidePeekPopovers({ tabId, left, top, room, placements, origin }: { tabId: string; left: number; top: number; room: number; placements?: Record<string, readonly [number, number, number, number]>; origin: { x: number; y: number } }) {
  const popover = usePages((s) => s.popover[tabId] ?? null);
  const fit = (key: string, width: number) => {
    const rect = placements?.[key];
    return rect ? { left: rect[0] - origin.x, top: rect[1] - origin.y } : { left: Math.max(POPOVER_MARGIN, Math.min(left, room - width - POPOVER_MARGIN)), top };
  };
  return (
    <>
      <SiteControls tabId={tabId} open={popover === "siteControls"} {...fit("siteControls", 288)} />
      {popover === "zoom" && <ZoomPopover tabId={tabId} {...fit("zoom", ZOOM_POPOVER_WIDTH)} />}
    </>
  );
}

export const paneTab = (t: Tab | undefined) => ({ exists: !!t, url: t?.url ?? "" });
