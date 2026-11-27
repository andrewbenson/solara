import { WebView, type PageEngine } from "@solara/solaracore";
import { littleSolaraShellActive, nativeToolbarAvailable, tabPool, windowPaneRootsActive, windowShellActive } from "@solara/settings";
import { memo, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { StyleSheet, View, type NativeSyntheticEvent, type ViewProps } from "react-native";
import { requireNativeViewManager } from "expo-modules-core";
import { useShallow } from "zustand/react/shallow";
import { isQuitting } from "../lib/native";
import { layout, useTheme } from "../lib/theme";
import { opaqueCard } from "../lib/opaqueCard";
import { handOff, takeHandOff, wantsPage } from "../lib/tabPages";
import { noteGone } from "../lib/tabLifecycle";
import { usePrewarm } from "../lib/preload";
import { pagesPooledIn } from "../lib/pagesPool";
import { persistEngine } from "../lib/engines";
import { tabEngine } from "../store/engines";
import { webviewRef } from "../lib/webviews";
import { useBrowser } from "../store/browser";
import { setPageProgress } from "../store/pageProgress";
import { shallowEqual, useProfilesValue, useStoreWhile, useTabValue } from "../store/tabWatch";
import { useActiveTabId, useWindowId } from "../store/hooks";
import { activeTabId, engineProfile, isIncognitoProfile, wake } from "../store/model";
import { needsPage } from "../store/pageSession";
import { removeTabs } from "../store/tabs";
import { splitOf } from "../store/splits";
import type { SplitView, Tab } from "../store/types";
import { BOOKMARKS_BAR_HEIGHT, bookmarksBarShown, useBookmarksBarMode, type BookmarksBarMode } from "./bookmarks/bookmarksBarPolicy";
import { NativeBookmarksBar } from "./bookmarks/NativeBookmarksBar";
import { POPOVER_MARGIN } from "./layout/controls";
import { NO_TOOLBAR, splitGeometry, toolbarGeometry, type Rect, type ToolbarGeometry } from "./layout/geometry";
import { patchPage, useFullscreenTab, usePages } from "./layout/pageState";
import { useTabDrag } from "./layout/tabDrag";
import { useNativePanePromptsTheme } from "./layout/nativePaneOverlays";
import { useFormColors } from "./settings/controls";
import { DropTargets, SplitDividers, SplitToast } from "./layout/SplitChrome";
import { SplitEmptyState } from "./layout/SplitEmptyState";
import { useWindowShell } from "./layout/ShellBackdrop";
import { dropPaneStatusStyle, dropPopoversOverCard, publishPaneStatusStyle, publishPopoversOverCard, usePaneRootDrawn } from "./layout/paneFeed";
import { nativeSplitPanes, useNativeSplitChrome } from "./layout/nativeSplitChrome";
import { SplitToolbarFeed } from "./layout/NativeSplitToolbars";
import { pagerFor } from "./layout/profilePager";
import { dockMoving, useDockMotion, usePeekEdge } from "./layout/dockMotion";
import { FrozenPage } from "./layout/frozenPage";
import { holderOf } from "../store/pinShare";
import { setCardAnchor, setUrlAnchor, useCardAnchors, useNativePopoverAnchors, useAddressBarInSidebar, useToolbarExtensionsWidths } from "./layout/windowLayout";
import { notePageEventHandled, acceptPageReport, currentPageContext, followNavigation, newPageSession, pageEventHandlers, releasePageSession } from "./pageEvents";
import { NewTabPage } from "./NewTabPage";
import { EmptyCard } from "./EmptyCard";
import { SmallWindowCard } from "./SmallWindowCard";
import { InternalPage } from "./pages";
import { ShareBar } from "./media/ShareBar";
import { Toolbar, ToolbarBackdrop, urlFieldRight } from "./Toolbar";
import { WindowToolbar } from "./WindowToolbar";
import { useToolbarSidebarToggle } from "./layout/nativeToolbarPresentation";
import { isSmallWindow } from "../store/small";
import { useNativeWindowAnchors } from "./layout/shellLayout";
import { NativePeekMount } from "./peek/NativePeekMount";
import { PeekOverlay } from "./peek/PeekOverlay";
import { PooledPageProps } from "./PooledPageProps";
import { dismissPeek } from "./peek/actions";
import { useContentServices } from "./ContentServices";
import { PageOverlays, BesidePeekPopovers, paneTab } from "./PaneContent";


export function LegacyContentCard() {
  const windowId = useWindowId();
  const activeId = useActiveTabId();
  const split = useBrowser((s) => splitOf(s, activeId));
  const fullscreenTab = useFullscreenTab(windowId);
  const addressInSidebar = useAddressBarInSidebar();
  const small = useBrowser((s) => isSmallWindow(s.windows[windowId]));
  const showSidebarButton = useToolbarSidebarToggle(windowId);
  const barMode = useBookmarksBarMode(windowId);
  const [size, setSize] = useState({ width: 0, height: 0 });
  const [measuredOrigin, setOrigin] = useState<{ x: number; y: number } | null>(null);
  const nativeAnchors = useNativeWindowAnchors(windowId);
  const nativePopovers = useNativePopoverAnchors((state) => nativeAnchors ? state[windowId] : undefined);
  const nativeContent = useCardAnchors((state) => nativeAnchors ? state[windowId] : undefined);
  const origin = useMemo(() => nativeContent ? { x: nativeContent.left, y: nativeContent.top } : measuredOrigin, [nativeContent, measuredOrigin]);
  const container = useRef<View>(null);
  useContentServices();
  const peekId = useBrowser((s) => s.peeks[windowId]?.tabId);
  const peekFullscreen = !!peekId && fullscreenTab === peekId;
  const shell = useWindowShell();
  const [paneRoots] = useState(() => windowPaneRootsActive(windowId));
  const [pooled] = useState(() => pagesPooledIn(windowId));
  const cardTheme = useTheme();
  useNativePanePromptsTheme(true, windowId, cardTheme, useFormColors());
  useNativeSplitChrome(windowId, shell, cardTheme, fullscreenTab ?? null, !!peekId, !addressInSidebar && !small, small);
  useEffect(() => {
    if (fullscreenTab && peekId && !peekFullscreen) dismissPeek(windowId);
  }, [fullscreenTab, peekId, peekFullscreen, windowId]);

  const mountedMemo = useRef<{ tabIds?: string[]; tabs?: object; ids: string[]; seen: (Tab | undefined)[]; wants: boolean[] }>({ ids: [], seen: [], wants: [] });
  const mounted = useBrowser(
    useShallow((s) => {
      const tabIds = s.windows[windowId]?.tabIds;
      const memo = mountedMemo.current;
      if (memo.tabIds === tabIds && memo.tabs === s.tabs) return memo.ids;
      if (tabIds && memo.tabIds === tabIds) {
        let same = true;
        const seen = memo.seen.slice();
        const wants = memo.wants.slice();
        for (let i = 0; i < tabIds.length; i++) {
          const t = s.tabs[tabIds[i]!];
          if (t === seen[i]) continue;
          seen[i] = t;
          const want = wantsPage(t);
          if (want !== wants[i]) same = false;
          wants[i] = want;
        }
        if (same) {
          mountedMemo.current = { ...memo, tabs: s.tabs, seen, wants };
          return memo.ids;
        }
      }
      const seen = (tabIds ?? []).map((id) => s.tabs[id]);
      const wants = seen.map((t) => wantsPage(t));
      const ids = (tabIds ?? []).filter((_, i) => wants[i]);
      mountedMemo.current = { tabIds, tabs: s.tabs, ids, seen, wants };
      return ids;
    }),
  );

  const kept = pooled ? NO_TABS : mounted;
  const mountedIds = useMemo(() => new Set(kept), [kept]);

  const { panes, dividers } = useMemo(() => {
    const full: Rect = { x: 0, y: 0, width: size.width, height: size.height };
    if (fullscreenTab) {
      const under = split?.tabIds.includes(fullscreenTab) ? splitGeometry(split, size.width, size.height).panes : {};
      return { panes: { ...under, [fullscreenTab]: full }, dividers: [] };
    }
    if (split) return splitGeometry(split, size.width, size.height);
    return { panes: activeId ? { [activeId]: full } : {}, dividers: [] };
  }, [split, activeId, fullscreenTab, size.width, size.height]);

  useEffect(() => {
    const s = useBrowser.getState();
    for (const id of Object.keys(panes)) {
      const t = s.tabs[id];
      if (!t || !needsPage(t)) continue;
      const holder = holderOf(s, id);
      s.updateTab(id, holder ? { pageIn: holder.id, unloaded: undefined } : wake(t));
    }
  }, [panes]);

  const pagerPages = pagerFor(windowId).state((st) => st.pages);
  const leaving = useTabDrag((d) => (d.windowId === windowId && d.tabIds.length && (d.outside || !!(d.lifted ?? d.onPage)) ? d.tabIds : null));
  const successor = useMemo(() => {
    if (!leaving) return undefined;
    const s = useBrowser.getState();
    const next = activeTabId(removeTabs(s, leaving, false), windowId);
    return next && next !== activeTabId(s, windowId) ? next : undefined;
  }, [leaving, windowId]);
  const warm = useBrowser(
    useShallow((s) => {
      const w = s.windows[windowId];
      const ids = !w || !pagerPages ? [] : pagerPages.map((p) => (p.id === w.profileId ? undefined : w.activeTabIds[p.id])).filter((id): id is string => !!id);
      return successor && s.tabs[successor]?.windowId === windowId && !ids.includes(successor) ? [...ids, successor] : ids;
    }),
  );
  const warmSplits = useBrowser(useShallow((s) => warm.map((id) => splitOf(s, id)).filter((v): v is SplitView => !!v)));
  const warmPanes = useMemo(() => {
    const out: Record<string, Rect> = {};
    if (pooled) return out;
    for (const id of warm) out[id] = { x: 0, y: 0, width: size.width, height: size.height };
    for (const v of warmSplits) Object.assign(out, splitGeometry(v, size.width, size.height).panes);
    return out;
  }, [pooled, warm, warmSplits, size.width, size.height]);

  const shownMemo = useRef<{ mounted?: string[]; panes?: object; tabs?: object; keys: string[]; ids: string[]; found: (Tab | undefined)[] }>({ keys: [], ids: [], found: [] });
  const shown = useBrowser(
    useShallow((s) => {
      const memo = shownMemo.current;
      if (memo.mounted === kept && memo.panes === panes) {
        if (memo.tabs === s.tabs) return memo.keys;
        let same = true;
        let found = memo.found;
        for (let i = 0; i < memo.ids.length && same; i++) {
          const t = s.tabs[memo.ids[i]!];
          const was = found[i];
          if (t === was) continue;
          if (!t || !was || t.createdAt !== was.createdAt || t.profileId !== was.profileId) same = false;
          else {
            if (found === memo.found) found = found.slice();
            found[i] = t;
          }
        }
        if (same) {
          shownMemo.current = { ...memo, tabs: s.tabs, found };
          return memo.keys;
        }
      }
      const ids = [...new Set([...kept, ...Object.keys(panes)])];
      const found = ids.map((id) => s.tabs[id]);
      const keys = found
        .filter((t): t is Tab => !!t)
        .sort((a, b) => a.createdAt - b.createdAt)
        .map((t) => `${t.id}|${t.profileId}`);
      shownMemo.current = { mounted: kept, panes, tabs: s.tabs, keys, ids, found };
      return keys;
    }),
  );

  const geometryFor = (rect: Rect | undefined): ToolbarGeometry => {
    if (addressInSidebar || small) return NO_TOOLBAR;
    const leading = !!rect && rect.x === 0 && rect.y === 0;
    return toolbarGeometry({ sidebarButton: leading && showSidebarButton });
  };

  const focusedRect = activeId ? panes[activeId] : undefined;
  useEffect(() => {
    if (nativeAnchors || !origin || !focusedRect || addressInSidebar || small) return;
    const g = geometryFor(focusedRect);
    const place = (extensionsWidth = 0) =>
      setUrlAnchor(windowId, {
        left: origin.x + focusedRect.x + g.urlLeft,
        top: origin.y + focusedRect.y,
        width: focusedRect.width - g.urlLeft - urlFieldRight(!!split, extensionsWidth),
      });
    place(useToolbarExtensionsWidths.getState()[windowId]);
    return useToolbarExtensionsWidths.subscribe((w, prev) => {
      if (w[windowId] !== prev[windowId]) place(w[windowId]);
    });
  }, [nativeAnchors, origin, focusedRect?.x, focusedRect?.y, focusedRect?.width, addressInSidebar, !!split, showSidebarButton]);

  useEffect(() => {
    if (!nativeAnchors && origin && size.width > 0) setCardAnchor(windowId, { left: origin.x, top: origin.y, width: size.width, height: size.height });
  }, [nativeAnchors, origin, size.width, size.height, windowId]);

  const settled = useRef<{ width: number; height: number } | null>(null);
  const measure = (width: number, height: number) => {
    setSize({ width, height });
    if (!nativeAnchors) container.current?.measureInWindow((x, y) => setOrigin({ x, y }));
  };
  useEffect(
    () =>
      useDockMotion.subscribe((m) => {
        if (m.moving[windowId] || !settled.current) return;
        const { width, height } = settled.current;
        settled.current = null;
        measure(width, height);
      }),
    [windowId],
  );

  const windowToolbar = !split && !fullscreenTab && !addressInSidebar && !small;
  const peekEdge = usePeekEdge(windowId);
  const activeRect = activeId ? panes[activeId] : undefined;
  const popoversOverCard = peekEdge !== undefined && addressInSidebar && !small && !fullscreenTab && origin && activeRect ? activeId : undefined;
  const [feedOwner] = useState(() => ({}));
  useLayoutEffect(() => {
    if (paneRoots) publishPopoversOverCard(windowId, feedOwner, popoversOverCard);
  }, [paneRoots, windowId, popoversOverCard]);
  useEffect(() => () => dropPopoversOverCard(windowId, feedOwner), [windowId]);

  return (
    <View
      nativeID="solara-page-content"
      ref={container}
      pointerEvents={pooled ? "box-none" : "auto"}
      style={{ flex: 1 }}
      onLayout={(e) => {
        const { width, height } = e.nativeEvent.layout;
        if (size.width > 0 && dockMoving(windowId) && !split) settled.current = { width, height };
        else measure(width, height);
      }}
    >
      {size.width > 0 &&
        shown.map((key) => {
          const tabId = key.slice(0, key.indexOf("|"));
          const rect = panes[tabId];
          return (
            <TabPane
              key={key}
              tabId={tabId}
              windowId={windowId}
              rect={rect}
              fills={!!rect && rect.x === 0 && rect.y === 0 && rect.width === size.width && rect.height === size.height}
              fullWidth={size.width}
              fullHeight={size.height}
              focused={tabId === activeId}
              inActiveSplit={!!split?.tabIds.includes(tabId)}
              fullscreen={tabId === fullscreenTab}
              covered={!!fullscreenTab && tabId !== fullscreenTab}
              geometry={geometryFor(rect)}
              toolbar={!addressInSidebar && !small}
              small={small}
              mounted={mountedIds.has(tabId)}
              warm={warmPanes[tabId]}
              barMode={barMode}
              windowToolbar={windowToolbar}
              popovers={tabId !== popoversOverCard}
              peekShown={!!peekId}
              nativePane={shell && nativeSplitPanes && !!split?.tabIds.includes(tabId)}
              paneRoots={paneRoots}
              pooled={pooled}
            />
          );
        })}
      {size.width > 0 && windowToolbar && activeId && panes[activeId] && (
        <WindowToolbar windowId={windowId} tabId={activeId} geometry={geometryFor(panes[activeId])} />
      )}
      {size.width > 0 && !split && !fullscreenTab && (
        <FrozenPage windowId={windowId} tabId={activeId} top={(!addressInSidebar && !small ? layout.toolbarHeight : 0) + (barMode === "always" && !small ? BOOKMARKS_BAR_HEIGHT : 0)} />
      )}
      {shell && nativeSplitPanes && split && size.width > 0 &&
        split.tabIds.map((tabId) => <SplitToolbarFeed key={tabId} tabId={tabId} windowId={windowId} geometry={geometryFor(panes[tabId])} focused={tabId === activeId} />)}
      {split && !fullscreenTab && !shell && <SplitDividers split={split} dividers={dividers} width={size.width} height={size.height} />}
      {size.width > 0 && popoversOverCard && origin && activeRect && peekEdge !== undefined && (
        <BesidePeekPopovers
          tabId={popoversOverCard}
          left={Math.max(activeRect.x, peekEdge - origin.x) + POPOVER_MARGIN}
          top={activeRect.y + POPOVER_MARGIN}
          room={size.width}
          placements={nativePopovers}
          origin={origin}
        />
      )}
      {!fullscreenTab && <DropTargets panes={panes} origin={origin} windowId={windowId} native={shell} />}
      {(!fullscreenTab || peekFullscreen) && !small && pooled && <NativePeekMount windowId={windowId} origin={origin} fullscreen={peekFullscreen} />}
      {(!fullscreenTab || peekFullscreen) && !small && !pooled && (
        <PeekOverlay
          windowId={windowId}
          width={size.width}
          height={size.height}
          origin={origin}
          fullscreen={peekFullscreen}
          page={(tabId, sourceId, width) => <PeekPage tabId={tabId} sourceId={sourceId} windowId={windowId} width={width} fullscreen={peekFullscreen} pooled={pooled} />}
        />
      )}
      {!shell && <SplitToast windowId={windowId} />}
    </View>
  );
}

const TabPane = memo(function TabPane({
  tabId,
  windowId,
  rect,
  fills,
  fullWidth,
  fullHeight,
  focused,
  inActiveSplit,
  fullscreen,
  covered,
  geometry,
  toolbar,
  small,
  mounted,
  warm,
  barMode,
  windowToolbar,
  popovers,
  peekShown,
  nativePane,
  paneRoots,
  pooled,
}: {
  tabId: string;
  windowId: string;
  rect: Rect | undefined;
  fills: boolean;
  fullWidth: number;
  fullHeight: number;
  focused: boolean;
  inActiveSplit: boolean;
  fullscreen: boolean;
  covered: boolean;
  geometry: ToolbarGeometry;
  toolbar: boolean;
  small: boolean;
  mounted: boolean;
  warm: Rect | undefined;
  barMode: BookmarksBarMode;
  windowToolbar: boolean;
  popovers: boolean;
  peekShown: boolean;
  nativePane: boolean;
  paneRoots: boolean;
  pooled: boolean;
}) {
  const theme = useTheme();
  const visible = !!rect;
  const live = visible || !!warm;
  const overlays = !paneRoots || !usePaneRootDrawn(tabId);
  const [feedOwner] = useState(() => ({}));
  const own = useTabValue(tabId, paneTab, shallowEqual);
  const isNewTab = !own.url;
  const emptyCard = useBrowser((s) => isNewTab && s.settings.newTabOpens === "commandBar");
  const newTabShown = useStoreWhile(usePages, live, (s) => !!s.pages[tabId]?.newTabShown);
  const inSomeSplit = useStoreWhile(useBrowser, !!warm, (s) => !!warm && !!splitOf(s, tabId));
  const inSplit = visible ? inActiveSplit : inSomeSplit;
  const frame = rect ?? warm ?? { x: 0, y: 0, width: fullWidth, height: fullHeight };
  useEffect(() => {
    if (visible && isNewTab && !mounted) patchPage(tabId, { wasNewTab: true });
  }, [visible, isNewTab, mounted]);
  const prewarmed = usePrewarm(!pooled && visible && isNewTab && !emptyCard && !mounted && !small && !inSplit);
  const bookmarksBar = bookmarksBarShown(barMode, own.exists ? own : undefined) && !fullscreen && !inSplit && !small;
  const bookmarksHeight = bookmarksBar ? BOOKMARKS_BAR_HEIGHT : 0;
  const toolbarVisible = toolbar && !fullscreen;
  const [presentation, setPresentation] = useState<LegacyToolbarFrame | null>(null);
  const shownTop = (toolbarVisible ? layout.toolbarHeight : 0) + bookmarksHeight;
  const frameSource = toolbarVisible && visible && !covered;
  const current = frameSource && presentation?.tabId === tabId ? presentation : { top: shownTop, viewport: shownTop, onFrame: false, strip: false };
  const statusStyle = current.top === current.viewport ? undefined : { transform: [{ translateY: current.viewport - current.top }] };
  const nativeRailChrome = current.onFrame;
  useLayoutEffect(() => {
    if (paneRoots) publishPaneStatusStyle(tabId, feedOwner, statusStyle);
  }, [paneRoots, tabId, feedOwner, current.top, current.viewport]);
  useEffect(() => () => dropPaneStatusStyle(tabId, feedOwner), [tabId]);

  const [nativeSmall] = useState(() => small && littleSolaraShellActive(windowId));

  const cardFill = visible && !fullscreen && !nativePane && !pooled && !(windowToolbar && nativeRailChrome) ? theme.card : undefined;

  return (
    <SmallWindowCard
      nativeSmall={nativeSmall}
      windowId={windowId}
      tabId={tabId}
      fill={visible ? cardFill ?? null : null}
      radius={fullscreen ? 0 : layout.cardRadius}
      pointerEvents={!visible || covered ? "none" : pooled ? "box-none" : "auto"}
      onTouchStart={() => {
        if (visible && !focused) useBrowser.getState().activate(tabId);
      }}
      style={{
        position: "absolute",
        ...(fills ? { left: 0, top: 0, right: 0, bottom: 0 } : { left: frame.x, top: frame.y, width: frame.width, height: frame.height }),
        borderRadius: nativeSmall ? undefined : fullscreen ? 0 : layout.cardRadius,
        overflow: nativeSmall ? undefined : "hidden",
        opacity: covered ? 0 : 1,
        backgroundColor: nativeSmall ? undefined : cardFill,
      }}
    >
      {toolbarVisible && visible && !nativePane && !windowToolbar && (
        <View pointerEvents="box-none" style={toolbarFrame}>
          <Toolbar tabId={tabId} geometry={geometry} windowId={windowId} inSplit={inSplit} focused={focused || !inSplit} />
        </View>
      )}
      {toolbarVisible && visible && !nativePane && windowToolbar && !windowShellActive(windowId) && !current.strip && (
        <View pointerEvents="none" style={toolbarFrame}>
          <ToolbarBackdrop tabId={tabId} windowId={windowId} />
        </View>
      )}
      {visible && <LegacyToolbarGeometry windowId={windowId} tabId={tabId} onToolbarFrame={(e) => setPresentation(e.nativeEvent)} style={geometryFeedFrame} />}
      <View pointerEvents={pooled ? "box-none" : "auto"} style={[pageGroupFrame, { top: current.top - bookmarksHeight }, windowToolbar && nativeRailChrome && visible && !nativePane && !pooled ? { backgroundColor: theme.card, borderRadius: layout.cardRadius } : null]}>
        {bookmarksBar && <NativeBookmarksBar placeholder={!visible} />}
        <View pointerEvents={pooled ? "box-none" : "auto"} style={{ height: Math.max(0, frame.height - current.viewport) }}>
          {visible && !fullscreen && <ShareBar tabId={tabId} />}
          <View pointerEvents={pooled ? "box-none" : "auto"} style={{ flex: 1 }}>
            {pooled && tabPool && <PooledPageProps pool={tabPool} tabId={tabId} />}
            {!pooled && (mounted || prewarmed) && <TabWebView tabId={tabId} visible={visible && !newTabShown && !isNewTab} warm={!!warm && !newTabShown && !isNewTab} />}
            {visible && isNewTab && !small && !nativePane && (inSplit ? <SplitEmptyState tabId={tabId} focused={focused} /> : emptyCard ? <EmptyCard windowId={windowId} tabId={tabId} /> : <NewTabPage key={tabId} windowId={windowId} tabId={tabId} toolbar={toolbar} />)}
            {visible && <InternalPage tabId={tabId} />}
            {visible && overlays && (
              <PageOverlays
                tabId={tabId}
                windowId={windowId}
                width={frame.width}
                geometry={geometry}
                toolbar={toolbar}
                fullscreen={fullscreen}
                newTabShown={newTabShown}
                statusStyle={statusStyle}
                popovers={popovers}
                cliPill={!peekShown && (fullscreen || focused || !inSplit)}
              />
            )}
          </View>
        </View>
      </View>
    </SmallWindowCard>
  );
});

const pageGroupFrame = { position: "absolute", left: 0, right: 0 } as const;
const toolbarFrame = { ...pageGroupFrame, top: 0, height: layout.toolbarHeight };
const geometryFeedFrame = { position: "absolute", width: 0, height: 0 } as const;
type LegacyToolbarFrame = { tabId: string; top: number; viewport: number; onFrame: boolean; strip: boolean };
const LegacyToolbarGeometry = requireNativeViewManager<ViewProps & {
  windowId: string;
  tabId: string;
  onToolbarFrame(e: NativeSyntheticEvent<LegacyToolbarFrame>): void;
}>("SolaraAutoHide");

function PeekPage({ tabId, sourceId, windowId, width, fullscreen, pooled }: { tabId: string; sourceId: string; windowId: string; width: number; fullscreen: boolean; pooled: boolean }) {
  return (
    <>
      {!pooled && <TabWebView tabId={tabId} visible warm={false} peekOf={sourceId} />}
      <PageOverlays tabId={tabId} windowId={windowId} width={width} geometry={NO_TOOLBAR} toolbar={false} fullscreen={fullscreen} newTabShown={false} cliPill peek />
    </>
  );
}

const NO_TABS: string[] = [];
const webViewTab = (t: Tab | undefined) => ({ navigation: t?.navigation, adoptId: t?.adoptId, profileId: t?.profileId ?? "", shownUrl: t?.url ?? "" });


type TabWebViewProps = { tabId: string; visible: boolean; warm: boolean; peekOf?: string };

const TabWebView = memo(function TabWebView(props: TabWebViewProps) {
  const engine = useBrowser((s) => tabEngine(s, props.tabId));
  return <EngineWebView key={engine} engine={engine} {...props} />;
});

function EngineWebView({ tabId, visible, warm, peekOf, engine }: TabWebViewProps & { engine: PageEngine }) {
  const { navigation, adoptId, profileId, shownUrl } = useTabValue(tabId, webViewTab, shallowEqual);
  const neighbour = useStoreWhile(useBrowser, warm, (s) => warm && s.windows[s.tabs[tabId]?.windowId ?? ""]?.profileId !== profileId);
  const tab = () => useBrowser.getState().tabs[tabId];
  const store = () => useBrowser.getState();
  const ref = useMemo(() => webviewRef(tabId), [tabId]);
  const pageColor = useProfilesValue(profileId, (profiles) => (isIncognitoProfile(profileId) ? "incognito" : (profiles[profileId]?.color ?? "plum")));
  const theme = useTheme();
  const backdrop = useMemo(() => opaqueCard(theme), [theme.card, theme.windowTint[0], theme.windowTint[1]]);

  const [session] = useState(() => newPageSession(tabId, engine, peekOf, takeHandOff(tabId, engine)));
  session.profileId = profileId;
  session.adoptId = adoptId;
  session.peekOf = peekOf;
  const handlers = useMemo(() => pageEventHandlers(session), [session]);

  const contextKey = usePages((s) => {
    const page = s.pages[tabId];
    return `${!!page?.wasNewTab}|${page?.newTabShown?.url ?? ""}`;
  });
  const pageContext = useMemo(() => currentPageContext(tabId), [navigation?.seq, contextKey]);
  const seq = navigation?.seq;
  useEffect(() => {
    followNavigation(session, navigation);
  }, [seq]);
  useEffect(() => {
    persistEngine(tabId, engine);
    return () => {
      releasePageSession(session);
      if (session.factsOwner === "js") noteGone(tabId);
    };
  }, []);
  const mountedProfile = useRef(profileId);
  useLayoutEffect(
    () => () => {
      const t = tab();
      const sameEngine = tabEngine(store(), tabId) === engine;
      if (wantsPage(t) && sameEngine && engineProfile(t.profileId) === engineProfile(mountedProfile.current) && !isQuitting()) handOff(tabId, engineProfile(t.profileId), engine);
      else setPageProgress(tabId, 0);
    },
    [],
  );

  return (
    <WebView
      ref={ref}
      engine={engine}
      style={StyleSheet.absoluteFill}
      url={navigation?.url ?? (adoptId ? tab()?.url : undefined)}
      profile={engineProfile(profileId)}
      adoptId={adoptId}
      transferKey={tabId}
      pageContext={pageContext}
      temporary={peekOf !== undefined}
      temporarySource={peekOf}
      visible={visible}
      warm={warm}
      neighbour={neighbour}
      pageColor={pageColor}
      contentsBackgroundColor={backdrop}
      shownUrl={shownUrl}
      acceptStoreReport={(report) => acceptPageReport(session, report)}
      onStoreEventHandled={(report) => notePageEventHandled(session, report)}
      {...handlers}
    />
  );
}
