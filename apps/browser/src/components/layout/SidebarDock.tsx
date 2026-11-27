import { addressBarInSidebar } from "./windowLayout";
import { nativeSidebarShell } from "../sidebar/sidebarShell";
import { onWindowEvent, setTrafficLightsCenter, Surface, watchLeftEdge, WindowDragRegion } from "@solara/shell";
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { AccessibilityInfo, Animated, Easing, StyleSheet, View } from "react-native";
import { useShallow } from "zustand/react/shallow";
import { switchOn } from "../../lib/killSwitches";
import { pagesPooledIn } from "../../lib/pagesPool";
import { hex, layout, useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { useWindowId } from "../../store/hooks";
import { sidebarWidthOf } from "../../store/sidebarRail";
import { Sidebar } from "../Sidebar";
import { AreaBoundary } from "../AreaBoundary";
import { dismissHoverIn } from "../sidebar/hover";
import { shellColumnFitsAddressBar } from "../sidebar/NativeSidebar";
import { useSidebarUi } from "../sidebar/state";
import { followPeekHold, peekHeld, watchPeekHolds } from "./peekHold";
import { useShellLayoutPush } from "./shellLayout";
import { useShellModal } from "./shellModal";
import {
  ARC_HIDE_MS,
  devDocks,
  devPeeks,
  dockMoving,
  DOCK_SPRING,
  LIGHTS_CENTER,
  lightsCenter,
  PEEK_BOTTOM,
  PEEK_ORIGIN,
  PEEK_RADIUS,
  peekShown,
  setDockMoving,
  setPeekShown,
  springConfig,
  TOP_STRIP_LIGHTS_CENTER,
  useDockMotion,
  usePeekEdge,
} from "./dockMotion";
import { nativeDockIn, useNativeDock, useNativeDockState } from "./nativeDock";
import { useTabDrag } from "./tabDrag";
import { usePeek } from "./usePeek";

let reduceMotion = false;
AccessibilityInfo.isReduceMotionEnabled().then(
  (on) => (reduceMotion = on),
  () => {},
);
AccessibilityInfo.addEventListener("reduceMotionChanged", (on) => (reduceMotion = on));

const SPRING = springConfig(DOCK_SPRING);
const STRIP_WIDTH = 8;
const HOLD_SLACK = 24;

function useSidebarDock(open: boolean, animate: boolean, arc: boolean, active: boolean): { dock: Animated.Value; away: boolean } {
  const windowId = useWindowId();
  const dock = useRef(new Animated.Value(open ? 1 : 0)).current;
  const was = useRef(open);
  const [away, setAway] = useState(!open);
  const latestOpen = useRef(open);
  latestOpen.current = open;
  const activated = useRef(active);
  useEffect(() => {
    if (!active) return;
    if (!activated.current) {
      activated.current = true;
      dock.setValue(latestOpen.current ? 1 : 0);
      setAway(!latestOpen.current);
    }
    return () => {
      activated.current = false;
      dock.stopAnimation();
      setDockMoving(windowId, false);
    };
  }, [active]);
  useEffect(() => {
    if (!active) {
      was.current = open;
      return;
    }
    if (was.current === open) return;
    was.current = open;
    if (!animate || reduceMotion || !switchOn("sidebarSlide")) {
      dock.stopAnimation();
      dock.setValue(open ? 1 : 0);
      setDockMoving(windowId, false);
      setAway(!open);
      return;
    }
    if (arc && open && peekShown(windowId)) {
      dock.stopAnimation();
      dock.setValue(1);
      setDockMoving(windowId, false);
      setAway(false);
      return;
    }
    if (open) setAway(false);
    setDockMoving(windowId, true);
    if (__DEV__) devDocks[windowId]?.mark();
    (arc && !open
      ? Animated.timing(dock, { toValue: 0, duration: ARC_HIDE_MS, easing: Easing.out(Easing.cubic), useNativeDriver: false })
      : Animated.spring(dock, {
          toValue: open ? 1 : 0,
          ...SPRING,
          restDisplacementThreshold: 0.001,
          restSpeedThreshold: 0.01,
          useNativeDriver: false,
        })
    ).start(({ finished }) => {
      if (!finished) return;
      setDockMoving(windowId, false);
      if (!open) setAway(true);
    });
  }, [open, active]);
  return { dock, away };
}

function useTopStripLights(windowId: string, dock: Animated.Value, on: boolean, travel: number, open: boolean) {
  useEffect(() => {
    if (!on) return;
    const place = (value: number) => {
      if (!dockMoving(windowId)) return;
      const up = Math.round(travel * (1 - value) * 2) / 2;
      void setTrafficLightsCenter(windowId, [TOP_STRIP_LIGHTS_CENTER[0], TOP_STRIP_LIGHTS_CENTER[1] - up]);
    };
    place((dock as unknown as { __getValue(): number }).__getValue());
    const sub = dock.addListener(({ value }) => place(value));
    return () => dock.removeListener(sub);
  }, [windowId, dock, on, travel, open]);
}

type Inset = { top: number; right: number; bottom: number; left: number };
type Edge = number | Animated.AnimatedInterpolation<number>;

function DragGutters({ top, left, inset, nativeColumn }: { top: Edge; left: Edge; inset: Inset; nativeColumn: number }) {
  const gutters = [
    { left: nativeColumn, right: 0, top: 0, height: top },
    { left: nativeColumn, right: 0, bottom: 0, height: inset.bottom },
    ...(nativeColumn ? [] : [{ left: 0, top: 0, bottom: 0, width: left }]),
    { right: 0, top: 0, bottom: 0, width: inset.right },
  ];
  return gutters.map((edge, i) => (
    <Animated.View key={i} style={[{ position: "absolute" }, edge]}>
      <WindowDragRegion style={StyleSheet.absoluteFill} />
    </Animated.View>
  ));
}

export function DockedLayout({
  fullscreen,
  topTabs,
  inset,
  topStrip,
  children,
}: {
  fullscreen: boolean;
  topTabs: boolean;
  inset: Inset;
  topStrip?: { strip: ReactNode; peek: ReactNode };
  children: ReactNode;
}) {
  const windowId = useWindowId();
  const [pooled] = useState(() => pagesPooledIn(windowId));
  const [open, savedWidth, addressBar] = useBrowser(
    useShallow(
      (s) =>
        [
          s.windows[windowId]?.sidebarOpen ?? true,
          sidebarWidthOf(s.windows[windowId], s.settings, nativeSidebarShell(windowId)),
          addressBarInSidebar(s, windowId),
        ] as const,
    ),
  );
  const width = useSidebarUi((u) => u.dragWidth[windowId]) ?? savedWidth;
  const cardTop = inset.top + (addressBar && !topTabs && !open ? layout.toolbarHeight : 0);
  const arc = addressBar && !topTabs && switchOn("sidebarSlide");
  const lights = LIGHTS_CENTER;
  const [nativeDockCapable] = useState(() => nativeDockIn(windowId));
  const nativeDock = nativeDockCapable && shellColumnFitsAddressBar(addressBar);
  const rnDock = useSidebarDock(open, !fullscreen, arc, !nativeDock);
  const shellDock = useNativeDock(windowId, open, nativeDock);
  const { dock, away } = nativeDock ? shellDock : rnDock;
  const peekRight = usePeekEdge(windowId);
  useShellLayoutPush(windowId, dock, { sidebarWidth: width, topTabs, fullscreen, addressBarInSidebar: addressBar, away, peekRight }, nativeDock);
  useShellModal(windowId);
  const left = useMemo(
    () =>
      dock.interpolate({
        inputRange: [0, 1],
        outputRange: [inset.left, width],
      }),
    [dock, width, inset.left],
  );
  const top = useMemo(() => dock.interpolate({ inputRange: [0, 1], outputRange: [layout.cardTop, inset.top] }), [dock, inset.top]);
  const stripY = useMemo(() => dock.interpolate({ inputRange: [0, 1], outputRange: [-inset.top, 0] }), [dock, inset.top]);
  const stripShown = topTabs && (open || !away);
  const moving = useDockMotion((m) => !!m.moving[windowId]);
  useDevDockTrace(windowId, dock, open, away, !nativeDock);
  useTopStripLights(windowId, dock, !nativeDock && topTabs && !fullscreen, inset.top, open);
  return (
    <>
      <Animated.View
        pointerEvents={pooled ? "box-none" : "auto"}
        style={
          fullscreen
            ? { flex: 1 }
            : {
                flex: 1,
                flexDirection: "row",
                paddingTop: topTabs ? top : cardTop,
                paddingRight: inset.right,
                paddingBottom: inset.bottom,
                paddingLeft: topTabs ? inset.left : left,
              }
        }
      >
        {!fullscreen &&
          (pooled ? (
            <DragGutters top={topTabs ? top : cardTop} left={topTabs ? inset.left : left} inset={inset} nativeColumn={nativeDock && !topTabs && open ? width : 0} />
          ) : (
            <WindowDragRegion style={StyleSheet.absoluteFill} />
          ))}
        {children}
      </Animated.View>
      {topStrip &&
        stripShown && (
          <Animated.View
            pointerEvents={fullscreen || moving ? "none" : "auto"}
            style={[{ position: "absolute", left: 0, right: 0 }, fullscreen ? { bottom: "100%" } : { top: 0, transform: [{ translateY: stripY }] }]}
          >
            {topStrip.strip}
          </Animated.View>
        )}
      {topStrip && topTabs && !stripShown && (__DEV__ ? <DevDockPeek windowId={windowId}>{topStrip.peek}</DevDockPeek> : topStrip.peek)}
      {nativeDock && <NativeDockPublisher open={open} arc={arc} fullscreen={fullscreen} topTabs={topTabs} width={width} lights={lights} />}
      {!topTabs &&
        (nativeDock ? (
          <NativeDockedSidebar dock={dock} open={open} away={away} width={width} fullscreen={fullscreen} />
        ) : (
          <SidebarDock dock={dock} open={open} width={width} fullscreen={fullscreen} arc={arc} lights={lights} />
        ))}
    </>
  );
}

function useDevDockTrace(windowId: string, dock: Animated.Value, open: boolean, away: boolean, active: boolean) {
  const latest = useRef({ open, away });
  latest.current = { open, away };
  useLayoutEffect(() => {
    if (!__DEV__ || !active) return;
    let rows: number[][] | null = null;
    let frame = 0;
    let peekMounted = false;
    const record = () => {
      if (!rows || rows.length >= 256) return;
      const value = dock as unknown as { __getValue(): number; _animation?: { _lastVelocity?: number } };
      const progress = value.__getValue();
      const moving = dockMoving(windowId);
      rows.push([performance.now(), progress, moving ? value._animation?._lastVelocity ?? 0 : 0,
        latest.current.open ? 1 : 0, latest.current.away ? 1 : 0,
        -42 * (1 - progress), 6 + 36 * progress,
        TOP_STRIP_LIGHTS_CENTER[1] - Math.round(42 * (1 - progress) * 2) / 2,
        peekMounted ? 1 : 0, moving ? 1 : 0]);
    };
    const tick = () => {
      if (!dockMoving(windowId)) record();
      if (rows && rows.length < 256) frame = requestAnimationFrame(tick);
    };
    const handle = {
      trace: () => {
        cancelAnimationFrame(frame);
        rows = [];
        record();
        frame = requestAnimationFrame(tick);
      },
      samples: () => rows ?? [],
      mark: record,
      mounted: (value: boolean) => { peekMounted = value; },
    };
    devDocks[windowId] = handle;
    const listener = dock.addListener(record);
    return () => {
      cancelAnimationFrame(frame);
      dock.removeListener(listener);
      if (devDocks[windowId] === handle) delete devDocks[windowId];
    };
  }, [windowId, dock, active]);
}

function DevDockPeek({ windowId, children }: { windowId: string; children: ReactNode }) {
  useLayoutEffect(() => {
    if (!__DEV__) return;
    devDocks[windowId]?.mounted(true);
    return () => devDocks[windowId]?.mounted(false);
  }, [windowId]);
  return <>{children}</>;
}

function NativeDockPublisher({
  open,
  arc,
  fullscreen,
  topTabs,
  width,
  lights,
}: {
  open: boolean;
  arc: boolean;
  fullscreen: boolean;
  topTabs: boolean;
  width: number;
  lights: readonly [number, number];
}) {
  const windowId = useWindowId();
  const theme = useTheme();
  const floating = !open && !fullscreen && !topTabs;
  const [held, setHeld] = useState(false);
  useEffect(() => followPeekHold(windowId, floating, setHeld), [windowId, floating]);
  useNativeDockState(windowId, {
    open,
    arc,
    fullscreen,
    topTabs,
    width,
    held,
    slideSwitch: switchOn("sidebarSlide"),
    lights,
    look: { fill: hex(theme.windowTint[0]), border: hex(theme.panelBorder), shadowOpacity: theme.panelShadowOpacity },
  });
  return null;
}

function NativeDockedSidebar({ dock, open, away, width, fullscreen }: { dock: Animated.Value; open: boolean; away: boolean; width: number; fullscreen: boolean }) {
  const windowId = useWindowId();
  const moving = useDockMotion((m) => !!m.moving[windowId]);
  const slideOut = useMemo(() => dock.interpolate({ inputRange: [0, 1], outputRange: [-width, 0] }), [dock, width]);
  const sidebar = useMemo(
    () => (
      <AreaBoundary area="sidebar">
        <Sidebar width={width} />
      </AreaBoundary>
    ),
    [width],
  );
  return (
    <Animated.View
      pointerEvents={fullscreen || moving || !open ? "none" : "box-none"}
      style={{ position: "absolute", left: away || fullscreen ? -10_000 : 0, top: 0, bottom: 0, width, transform: [{ translateX: slideOut }] }}
    >
      {sidebar}
    </Animated.View>
  );
}

function SidebarDock({
  dock,
  open,
  width,
  fullscreen,
  arc,
  lights,
}: {
  dock: Animated.Value;
  open: boolean;
  width: number;
  fullscreen: boolean;
  arc: boolean;
  lights: readonly [number, number];
}) {
  const theme = useTheme();
  const windowId = useWindowId();
  const moving = useDockMotion((m) => !!m.moving[windowId]);
  const edgeOver = useRef(false);
  const peek = usePeek(!open && !moving && !fullscreen, arc, () => edgeOver.current || peekHeld(windowId), () => dismissHoverIn(windowId));
  const latestPeek = useRef(peek);
  latestPeek.current = peek;
  useEffect(() => (peek.live ? watchPeekHolds(() => latestPeek.current.recheck()) : undefined), [peek.live]);
  const holdWidth = PEEK_ORIGIN[0] + width + HOLD_SLACK;
  const holdHeight = useRef(Infinity);
  const inHold = (x: number, y: number) => x >= 0 && x < holdWidth && y >= 0 && y < holdHeight.current;
  const peeking = !open && !fullscreen && peek.live;
  const shown = fullscreen ? "fullscreen" : open ? "docked" : peek.live ? "peek" : "away";
  useLayoutEffect(() => () => dismissHoverIn(windowId), [windowId, shown]);
  const watching = !open && !fullscreen && !moving;
  const draggingTab = useTabDrag((d) => d.windowId === windowId && d.tabIds.length > 0);
  const nativeHold = peeking ? holdWidth : draggingTab ? STRIP_WIDTH : 0;
  useEffect(() => {
    if (!watching) return;
    const sub = onWindowEvent((e) => {
      if (e.type !== "leftEdge" || e.id !== windowId) return;
      edgeOver.current = e.over;
      if (e.over) latestPeek.current.show();
      else latestPeek.current.hide();
    });
    watchLeftEdge(windowId, true, nativeHold);
    return () => {
      sub.remove();
      watchLeftEdge(windowId, false);
      edgeOver.current = false;
    };
  }, [windowId, watching, nativeHold]);
  useEffect(() => setPeekShown(windowId, peek.live, PEEK_ORIGIN[0] + width), [windowId, peek.live, width]);
  if (__DEV__) devPeeks[windowId] = peek;
  useEffect(() => () => setPeekShown(windowId, false), [windowId]);
  const panel = useRef(false);
  if (peeking) panel.current = true;
  const away = fullscreen || (!open && !moving && !peek.live);
  const slideOut = useMemo(() => dock.interpolate({ inputRange: [0, 1], outputRange: [-width, 0] }), [dock, width]);
  const peekIn = useMemo(
    () => peek.slide.interpolate({ inputRange: [0, 1], outputRange: [-12, width] }),
    [peek.slide, width],
  );
  useTrafficLights(windowId, dock, peek.slide, { width, peeking, fullscreen, lights });
  const sidebar = useMemo(
    () => (
      <AreaBoundary area="sidebar">
        <Sidebar width={width} />
      </AreaBoundary>
    ),
    [width],
  );

  const leaveStrip = (e: { nativeEvent: { clientX: number; clientY: number } }) => {
    if (peek.live && !inHold(e.nativeEvent.clientX, e.nativeEvent.clientY)) peek.hide();
  };

  const strip = useRef(false);
  if (!open) strip.current = true;
  const fade = peeking && !arc;
  const panelOn = useRef(new Animated.Value(0)).current;
  useLayoutEffect(() => panelOn.setValue(peeking ? 1 : 0), [panelOn, peeking]);
  const panelOpacity = useMemo(
    () => (arc ? panelOn : Animated.multiply(panelOn, peek.slide)),
    [arc, panelOn, peek.slide],
  );
  const peekStyle = {
    opacity: fade ? peek.slide : 1,
    transform: [{ translateX: peeking ? peekIn : 0 }],
  };

  return (
    <>
      {peeking && (
        <View
          pointerEvents="none"
          onMouseEnter={peek.show}
          onMouseLeave={peek.hide}
          onLayout={(e) => (holdHeight.current = e.nativeEvent.layout.height)}
          style={{ position: "absolute", left: 0, top: 0, bottom: 0, width: holdWidth }}
        />
      )}
      {strip.current && (
        <View
          pointerEvents={!open && !fullscreen ? "auto" : "none"}
          onMouseEnter={peek.show}
          onMouseLeave={leaveStrip}
          style={{
            position: "absolute",
            left: 0,
            top: 0,
            bottom: layout.cardInset,
            width: !open && !fullscreen ? STRIP_WIDTH : 0,
          }}
        />
      )}
      <Animated.View
        pointerEvents={fullscreen || moving || (!open && !peeking) ? "none" : "auto"}
        style={{
          position: "absolute",
          left: away ? -10_000 : peeking ? PEEK_ORIGIN[0] : 0,
          top: peeking ? PEEK_ORIGIN[1] : 0,
          bottom: peeking ? PEEK_BOTTOM : 0,
          width,
          transform: [{ translateX: slideOut }],
        }}
      >
        {panel.current && (
          <Animated.View
            pointerEvents="none"
            style={[StyleSheet.absoluteFill, peekStyle, { opacity: panelOpacity }]}
          >
            <Surface
              fill={hex(theme.windowTint[0])}
              cornerRadius={PEEK_RADIUS}
              borderColor={hex(theme.panelBorder)}
              borderWidth={0.5}
              shadowColor="#000000"
              shadowOpacity={theme.panelShadowOpacity}
              shadowRadius={20}
              shadowOffset={[0, 6]}
              style={StyleSheet.absoluteFill}
            />
          </Animated.View>
        )}
        <Animated.View style={[{ flex: 1 }, peekStyle, peeking ? { borderRadius: PEEK_RADIUS, overflow: "hidden" } : null]}>
          {sidebar}
        </Animated.View>
      </Animated.View>
    </>
  );
}

function useTrafficLights(
  windowId: string,
  dock: Animated.Value,
  slide: Animated.Value,
  o: { width: number; peeking: boolean; fullscreen: boolean; lights: readonly [number, number] },
) {
  const values = useRef({ dock: 1, slide: 0 });
  const apply = useRef<() => void>(() => {});
  const sent = useRef<string | undefined>(undefined);
  apply.current = () => {
    const v = values.current;
    const offset = o.fullscreen || !o.peeking ? 0 : (o.width + 12) * (1 - v.slide) - PEEK_ORIGIN[0];
    const center = lightsCenter(offset, o.peeking && !o.fullscreen ? PEEK_ORIGIN[1] : 0, o.lights);
    const key = center ? center.join(",") : "";
    if (key === sent.current) return;
    sent.current = key;
    void setTrafficLightsCenter(windowId, center);
  };
  useEffect(() => {
    values.current.dock = (dock as unknown as { __getValue(): number }).__getValue();
    const a = dock.addListener(({ value }) => {
      values.current.dock = value;
      apply.current();
    });
    apply.current();
    return () => {
      dock.removeListener(a);
      sent.current = undefined;
      void setTrafficLightsCenter(windowId, null);
    };
  }, [windowId, dock]);
  useEffect(() => {
    if (!o.peeking) return;
    const b = slide.addListener(({ value }) => {
      values.current.slide = value;
      apply.current();
    });
    return () => slide.removeListener(b);
  }, [slide, o.peeking]);
  useEffect(() => apply.current(), [o.width, o.peeking, o.fullscreen, o.lights]);
}
