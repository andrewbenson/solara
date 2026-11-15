import { tabPool, windowNativeLayout } from "@solara/settings";
import { memo, useEffect, useLayoutEffect, useMemo, useState } from "react";
import { Animated, StyleSheet, View, type ViewStyle } from "react-native";
import { layout } from "../lib/theme";
import { panePromptsNativeIn } from "../lib/pagesPool";
import { useEngineOffers } from "../lib/engines";
import { EngineOfferPrompt } from "./site/EnginePrompt";
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
import { useNativePaneHint, useNativePanePopups, useNativePanePromptsPane } from "./layout/nativePaneOverlays";
import { markPaneRootDrawn, usePaneStatusStyle, usePopoversOverCard } from "./layout/paneFeed";
import { engineOfferMounted } from "./overlayGates";
import { useAddressBarInSidebar, useTabLayout } from "./layout/windowLayout";
import { NewTabPage } from "./NewTabPage";
import { EmptyCard } from "./EmptyCard";
import { InternalPage } from "./pages";
import { AutofillPrompt, BLOCKED_POPUPS_WIDTH, BlockedPopupsPrompt, ExternalAppPrompt, PasswordPrompt, PermissionPrompt } from "./site/Prompts";
import { SiteControls } from "./site/SiteControls";
import { SITE_PANEL } from "./site/SiteControlsParts";
import { ZOOM_POPOVER_WIDTH, ZoomPopover } from "./site/ZoomControls";
import { SelectionPopover } from "./site/SelectionPopover";
import { SharePicker } from "./media/SharePicker";
import { ShareBar } from "./media/ShareBar";
import { CastPicker } from "./media/CastPicker";
import { DeviceChooser } from "./site/DeviceChooser";
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
  useNativePanePopups(nativePrompts, windowId, tabId, popovers && popover === "popups", toolbar ? "right" : "left");
  const nativeCli = nativePrompts;
  const engineOffer = useEngineOffers((offers) => offers[tabId] ?? null);
  useNativePaneHint(nativePrompts, windowId, tabId, {
    zoom,
    cliPill: nativeCli && cliPill,
    engineOffer: engineOffer && { site: engineOffer.site, host: engineOffer.host, canRemember: engineOffer.canRemember },
  });
  return (
    <>
      <FindBar tabId={tabId} />
      <Animated.View pointerEvents="none" style={[StyleSheet.absoluteFill, statusStyle]}>
        <StatusBubble tabId={tabId} windowId={windowId} />
      </Animated.View>
      {!nativePrompts && <SadTab tabId={tabId} nativeAllowed={!peek} />}
      {cliPill && !nativeCli && <CliControlPill tabId={tabId} style={statusStyle} nativeAllowed={!peek} />}
      {!newTabShown && !nativePrompts && <PermissionPrompt tabId={tabId} left={Math.max(POPOVER_MARGIN, Math.min(geometry.urlLeft, width - 308))} top={POPOVER_MARGIN} />}
      {!nativePrompts && <PasswordPrompt tabId={tabId} right={POPOVER_MARGIN} top={POPOVER_MARGIN} />}
      {!nativePrompts && <AutofillPrompt tabId={tabId} right={POPOVER_MARGIN} top={POPOVER_MARGIN} />}
      {!newTabShown && !nativePrompts && <ExternalAppPrompt tabId={tabId} left={Math.max(POPOVER_MARGIN, Math.min(geometry.urlLeft, width - 348))} top={POPOVER_MARGIN} />}
      {engineOfferMounted(engineOffer, newTabShown, nativePrompts) && <EngineOfferPrompt tabId={tabId} left={Math.max(POPOVER_MARGIN, Math.min(geometry.urlLeft, width - 348))} top={POPOVER_MARGIN} />}
      {popovers && <SiteControls tabId={tabId} open={popover === "siteControls"} {...popoverSide} top={POPOVER_MARGIN} />}
      {popovers && popover === "popups" && !nativePrompts && <BlockedPopupsPrompt tabId={tabId} {...popoverSide} top={POPOVER_MARGIN} />}
      {popovers && popover === "zoom" && <ZoomPopover tabId={tabId} {...popoverSide} top={POPOVER_MARGIN} nativeAllowed={!peek} />}
      <SharePicker tabId={tabId} paneWidth={width} nativeAllowed={!peek} />
      {!newTabShown && !nativePrompts && <DeviceChooser tabId={tabId} left={Math.max(POPOVER_MARGIN, Math.min(geometry.urlLeft, width - 348))} top={POPOVER_MARGIN} />}
      <CastPicker tabId={tabId} paneWidth={width} nativeAllowed={!peek} />
      <NavigationOverlays tabId={tabId} windowId={windowId} geometry={geometry} peek={peek} />
      {!nativePrompts && <SelectionPopover tabId={tabId} zoom={zoom} nativeAllowed={!peek} />}
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
  useNativePanePromptsPane(nativePrompts, windowId, tabId, geometry.urlLeft, newTabShown);
  return (
    <View pointerEvents="box-none" style={{ flex: 1 }} onLayout={(e) => setWidth(e.nativeEvent.layout.width)}>
      {nativeLayout && shown && (
        <NativePageContent windowId={windowId} tabId={tabId} fullscreen={fullscreen} inSplit={inSplit} toolbar={toolbar} />
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

const NativePageContent = memo(function NativePageContent({ windowId, tabId, fullscreen, inSplit, toolbar }: { windowId: string; tabId: string; fullscreen: boolean; inSplit: boolean; toolbar: boolean }) {
  const own = useTabValue(tabId, paneTab, shallowEqual);
  const emptyCard = useBrowser((s) => s.settings.newTabOpens === "commandBar");
  useEffect(() => {
    if (!own.url) patchPage(tabId, { wasNewTab: true });
  }, [own.url, tabId]);
  return (
    <>
      {tabPool && <PooledPageProps pool={tabPool} tabId={tabId} visible />}
      {!fullscreen && <ShareBar tabId={tabId} />}
      {!own.url && !inSplit && (emptyCard ? <EmptyCard windowId={windowId} tabId={tabId} /> : <NewTabPage key={tabId} tabId={tabId} toolbar={toolbar} />)}
      <InternalPage tabId={tabId} />
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
      <SiteControls tabId={tabId} open={popover === "siteControls"} {...fit("siteControls", SITE_PANEL.width)} />
      {popover === "popups" && <BlockedPopupsPrompt tabId={tabId} {...fit("popups", BLOCKED_POPUPS_WIDTH)} />}
      {popover === "zoom" && <ZoomPopover tabId={tabId} {...fit("zoom", ZOOM_POPOVER_WIDTH)} />}
    </>
  );
}

export const paneTab = (t: Tab | undefined) => ({ exists: !!t, url: t?.url ?? "" });
