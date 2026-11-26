import { SwipeArea, swipeHaptic, type SwipeAreaHandle, type SwipeEvent } from "@solara/solaracore";
import { SolaraHostedView, sendPaneSwipe, windowShellActive, windowNativeLayout, publishSettingsTopic } from "@solara/settings";
import { memo, useEffect, useRef, useState } from "react";
import { Image, StyleSheet, View } from "react-native";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { NEW_TAB_MARK } from "../primitives";
import { HistoryPopover } from "./HistoryPopover";
import { goBack, goForward, goToHistoryItem, historyItems, openHistoryMenu, useBackState, useHistoryAvailability, useHistoryMenu, type HistoryItem } from "./history";
import { usePage } from "./pageState";
import { NativeLayoutFeed, nativePaneWindows, useNativeLayoutFeed, type NativePanePresentation } from "./nativeLayoutFeed";
import type { ToolbarGeometry } from "./geometry";
import type { PageFrame } from "./nativePaneOverlays";
import {
  CAPSULE_INSET,
  CAPSULE_SIZE,
  CAPSULE_SIZE_CONFIRMED,
  capsuleOffset,
  LIST_ROW,
  listSelection,
  swipeProgress,
} from "./swipeMotion";

const SIZE = CAPSULE_SIZE;
const SIZE_CONFIRMED = CAPSULE_SIZE_CONFIRMED;
const LIST_WIDTH = 200;
const ROW = LIST_ROW;
const LIST_PAD = 8;
const LIST_IDLE_MS = 300;

export const NavigationOverlays = memo(function NavigationOverlays({ tabId, windowId, geometry, peek = false }: { tabId: string; windowId: string; geometry: ToolbarGeometry; peek?: boolean }) {
  return (
    <>
      <SwipeOverlay tabId={tabId} windowId={windowId} nativeAllowed={!peek} />
      <HistoryPopover tabId={tabId} windowId={windowId} anchors={{ back: geometry.back, forward: geometry.forward }} nativeAllowed={!peek} />
    </>
  );
});

type NavigationPresentation = { newTabShown: boolean; backToNewTab: boolean; engineBack: boolean; backToOpener: boolean; theme: { dark: boolean; textPrimary: string; textSecondary: string } };
const navigationFeed = new NativeLayoutFeed<NativePanePresentation<NavigationPresentation>>((entries) => publishSettingsTopic("pane.navigation", { windows: nativePaneWindows(entries) }));

export function SwipeOverlay(props: { tabId: string; windowId: string; nativeAllowed?: boolean }) {
  const [native] = useState(() => windowNativeLayout(props.windowId));
  return native ? <NativeNavigationHistory tabId={props.tabId} windowId={props.windowId} /> : <LegacySwipeOverlay {...props} />;
}

function NativeNavigationHistory({ tabId, windowId }: { tabId: string; windowId: string }) {
  const theme = useTheme();
  const { pageId, action, engineBack } = useBackState(tabId);
  const newTabShown = usePage(pageId, (page) => !!page.newTabShown);
  const backToNewTab = usePage(pageId, (page) => page.backToNewTab);
  const backToOpener = action === "opener";
  useNativeLayoutFeed(navigationFeed, windowId, { windowId, tabId, presentation: { newTabShown, backToNewTab, engineBack, backToOpener, theme: { dark: !!theme.dark, textPrimary: theme.textPrimary, textSecondary: theme.textSecondary } } }, `${windowId}:${tabId}`);
  return null;
}

type Shown = { direction: "back" | "forward"; confirmed: boolean; list: HistoryItem[] | null; selected: number };

function LegacySwipeOverlay({ tabId, windowId, nativeAllowed = true }: { tabId: string; windowId: string; nativeAllowed?: boolean }) {
  const theme = useTheme();
  const newTabMark = Image.resolveAssetSource(NEW_TAB_MARK)?.uri ?? null;
  const [inShell] = useState(() => nativeAllowed && windowShellActive(windowId));
  const pageView = useRef<View>(null);
  const pageFrame = useRef<PageFrame | null>(null);
  const measurePage = () => pageView.current?.measureInWindow((x, y, width, height) => (pageFrame.current = [x, y, width, height]));
  const send = (message: object) => sendPaneSwipe(windowId, tabId, message);
  const history = useHistoryAvailability(tabId);
  const sizeRef = useRef({ width: 0, height: 0 });
  const [shown, setShown] = useState<Shown | null>(null);
  const area = useRef<SwipeAreaHandle>(null);

  const g = useRef({
    active: false,
    direction: "back" as "back" | "forward",
    confirmed: false,
    width: SIZE,
    items: null as Promise<HistoryItem[]> | null,
    list: null as HistoryItem[] | null,
    listY: 0,
    selected: 0,
    idle: undefined as ReturnType<typeof setTimeout> | undefined,
  }).current;
  const resetValues = (direction: "back" | "forward") => {
    clearTimeout(g.idle);
    Object.assign(g, { active: true, direction, confirmed: false, width: SIZE, list: null, listY: 0, selected: 0 });
    if (!inShell || pageFrame.current) send({ op: "show", direction, ...(inShell ? { frame: pageFrame.current } : {}), theme: { dark: !!theme.dark, textPrimary: theme.textPrimary, textSecondary: theme.textSecondary }, profileId: useBrowser.getState().tabs[tabId]?.profileId ?? "", newTabMark });
  };

  const setConfirmed = (confirmed: boolean) => {
    if (g.confirmed === confirmed) return;
    g.confirmed = confirmed;
    if (confirmed) swipeHaptic("levelChange");
    if (!g.list) g.width = confirmed ? SIZE_CONFIRMED : SIZE;
    send({ op: "confirm", confirmed });
    setShown((s) => (s ? { ...s, confirmed } : s));
  };

  const presentList = async () => {
    const gesture = g.items;
    const items = (await gesture) ?? [];
    if (g.items !== gesture || !g.active || g.list || !g.confirmed || items.length < 2) return;
    const { height } = sizeRef.current;
    const fit = Math.max(2, Math.floor((height / 2 + ROW / 2 - LIST_PAD - 8) / ROW));
    const list = items.slice(0, fit);
    g.list = list;
    g.selected = 0;
    g.listY = lastDy.current;
    swipeHaptic("generic");
    g.width = LIST_WIDTH;
    const favicons = faviconsFor(tabId, list);
    send({ op: "list", items: list.map((item) => ({ title: item.title, url: item.url, favicon: favicons.get(item.url) ?? null, newTab: item.offset === "newTab" })) });
    setShown((s) => (s ? { ...s, list, selected: 0 } : s));
  };

  const select = (dy: number) => {
    const { index, nudge } = listSelection(dy - g.listY, g.list!.length);
    send({ op: "select", index, nudge });
    if (index === g.selected) return;
    g.selected = index;
    swipeHaptic("alignment");
    setShown((s) => (s ? { ...s, selected: index } : s));
  };

  const dismiss = (delay = 0) => {
    clearTimeout(g.idle);
    g.active = false;
    send({ op: "dismiss", delay: delay / 1000 });
    setShown(null);
  };

  const lastDy = useRef(0);
  const onSwipe = (e: SwipeEvent) => {
    lastDy.current = e.dy;
    if (e.phase === "began" || e.phase === "swipe") {
      resetValues(e.direction);
      g.items = historyItems(tabId, e.direction === "back" ? -1 : 1);
      setShown({ direction: e.direction, confirmed: false, list: null, selected: 0 });
    }
    if (!g.active) return;
    if (e.phase === "swipe") {
      send({ op: "move", x: CAPSULE_INSET });
      setConfirmed(true);
      navigate(e.direction, null);
      return dismiss(120);
    }
    if (e.phase === "cancelled") return dismiss();
    if (e.phase === "ended") {
      const target = g.list ? (g.list[g.selected] ?? null) : null;
      if (target || g.confirmed) navigate(e.direction, target);
      return dismiss();
    }

    const progress = swipeProgress(e.distance);
    if (g.list) select(e.dy);
    else setConfirmed(progress >= 1);
    send({ op: "move", x: capsuleOffset(progress, g.width) });

    clearTimeout(g.idle);
    if (g.confirmed && !g.list) g.idle = setTimeout(() => void presentList(), LIST_IDLE_MS);
  };

  const navigate = (direction: "back" | "forward", item: HistoryItem | null) => {
    if (item) return void goToHistoryItem(tabId, item);
    if (direction === "back") goBack(tabId);
    else goForward(tabId);
  };

  useEffect(() => () => {
    clearTimeout(g.idle);
    if (g.active) sendPaneSwipe(windowId, tabId, { op: "dismiss", delay: 0 });
    g.active = false;
    g.items = null;
  }, [windowId, tabId]);
  useSwipeDevHandle(tabId, area);

  return (
    <>
      <SwipeArea
        ref={area}
        style={StyleSheet.absoluteFill}
        canSwipeBack={history.back}
        canSwipeForward={history.forward}
        allowsVerticalMotion={!!shown?.list}
        coversPage
        onSwipe={onSwipe}
        onLayout={(e) => void (sizeRef.current = { width: e.nativeEvent.layout.width, height: e.nativeEvent.layout.height })}
      />
      {inShell && <View ref={pageView} pointerEvents="none" collapsable={false} onLayout={measurePage} style={StyleSheet.absoluteFill} />}
      {!inShell && <SolaraHostedView kind="swipeCapsule" windowId={windowId} state={JSON.stringify({ tabId, newTabMark })} pointerEvents="none" style={StyleSheet.absoluteFill} />}
    </>
  );
}

function faviconsFor(tabId: string, items: HistoryItem[]) {
  const profileId = useBrowser.getState().tabs[tabId]?.profileId ?? "";
  const urls = new Set(items.map((i) => i.url));
  return new Map((useBrowser.getState().history[profileId] ?? []).filter((h) => urls.has(h.url)).map((h) => [h.url, h.favicon]));
}

const devPanes = new Map<string, React.RefObject<SwipeAreaHandle | null>[]>();
function useSwipeDevHandle(tabId: string, area: React.RefObject<SwipeAreaHandle | null>) {
  useEffect(() => {
    if (!__DEV__) return;
    devPanes.set(tabId, [...(devPanes.get(tabId) ?? []), area]);
    return () => {
      const rest = (devPanes.get(tabId) ?? []).filter((a) => a !== area);
      if (rest.length) devPanes.set(tabId, rest);
      else devPanes.delete(tabId);
    };
  }, [tabId]);
}
const devPane = (tabId: string) => [...(devPanes.get(tabId) ?? [])].reverse().find((a) => a.current)?.current ?? null;
if (__DEV__) {
  const g = globalThis as { acSwipe?: Record<string, unknown> };
  g.acSwipe = { ...g.acSwipe, pane: devPane, history: { items: historyItems, open: openHistoryMenu, menu: useHistoryMenu, go: goToHistoryItem } };
}
