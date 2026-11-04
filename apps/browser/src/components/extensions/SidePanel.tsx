import { unwrapPageEvent, WebView, type OpenWindowRequest } from "@solara/solaracore";
import { toEngineUrl } from "@solara/core";
import { focusPageIfUnclaimed, hostedKinds, onHostedEvent, setWindowShellLayout, SolaraHostedView } from "@solara/settings";
import { Hairline } from "@solara/shell";
import { useEffect, useMemo, useRef, useState } from "react";
import { Animated, Easing, Image, PanResponder, StyleSheet, Text, View } from "react-native";
import { layout, useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { setWindowSidebar, sidePanelWidthOf } from "../../store/sidebarRail";
import { shownPageId } from "../../store/peek";
import { useWindowId } from "../../store/hooks";
import { useWindowShell } from "../layout/ShellBackdrop";
import { current, nextFrame } from "../layout/shellLayout";
import { openFromPage, pageProfileId } from "../layout/openFromPage";
import { IconButton } from "../primitives";
import { closeSidePanel, findExtension, showExtensionMenu, useExtensions, type SidePanel } from "./state";

const MIN_WIDTH = 320;
const MAX_WIDTH = 600;
const HEADER = 40;

function rubberBand(width: number): number {
  const band = (over: number) => 36 * (1 - Math.exp(-over / 90));
  if (width > MAX_WIDTH) return MAX_WIDTH + band(width - MAX_WIDTH);
  if (width < MIN_WIDTH) return MIN_WIDTH - band(MIN_WIDTH - width);
  return width;
}
const clamp = (w: number) => Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, w));

let refocusing = false;
function refocusActivePageOnPanelLoss() {
  if (refocusing) return;
  refocusing = true;
  onHostedEvent("extensionSidePanel", null, (name, _payload, windowId) => {
    if (name !== "focusLost") return;
    const tabId = shownPageId(useBrowser.getState(), windowId);
    if (tabId) void focusPageIfUnclaimed(windowId, tabId);
  });
}

export function ExtensionSidePanel() {
  const windowId = useWindowId();
  const panel = useExtensions((e) => e.sidePanels[windowId]);
  const savedWidth = useBrowser((s) => sidePanelWidthOf(s.windows[windowId], s.settings));
  const [dragWidth, setDragWidth] = useState<number | null>(null);
  const appear = useRef(new Animated.Value(0)).current;
  const [shown, setShown] = useState(panel);
  const [native] = useState(() => hostedKinds().includes("extensionSidePanel"));
  if (native) refocusActivePageOnPanelLoss();

  useEffect(() => {
    if (panel) setShown(panel);
    Animated.timing(appear, { toValue: panel ? 1 : 0, duration: 200, easing: Easing.out(Easing.cubic), useNativeDriver: false }).start(({ finished }) => {
      if (finished && !panel) setShown(undefined);
    });
  }, [!!panel]);
  useEffect(() => {
    if (panel) setShown(panel);
  }, [panel?.url, panel?.extensionId]);

  const width = dragWidth ?? savedWidth;
  useShellRoom(windowId, appear, shown ? width + layout.cardInset - 1 : 0);
  const start = useRef(width);
  const settling = useRef<Animated.CompositeAnimation | null>(null);
  const settle = useMemo(
    () => (raw: number) => {
      const target = clamp(raw);
      const finish = () => {
        setWindowSidebar(windowId, { sidePanelWidth: target });
        setDragWidth(null);
      };
      if (raw === target) return finish();
      const value = new Animated.Value(raw);
      value.addListener(({ value: v }) => setDragWidth(v));
      const animation = Animated.timing(value, { toValue: target, duration: 260, easing: Easing.out(Easing.back(1.2)), useNativeDriver: false });
      settling.current = animation;
      animation.start(({ finished }) => {
        value.removeAllListeners();
        if (settling.current === animation) settling.current = null;
        if (finished) finish();
      });
    },
    [windowId],
  );
  const responder = useMemo(
    () =>
      PanResponder.create({
        onStartShouldSetPanResponder: () => true,
        onPanResponderGrant: () => {
          settling.current?.stop();
          start.current = sidePanelWidthOf(useBrowser.getState().windows[windowId], useBrowser.getState().settings);
          setDragWidth(start.current);
        },
        onPanResponderMove: (_, g) => setDragWidth(rubberBand(start.current - g.dx)),
        onPanResponderRelease: (_, g) => settle(rubberBand(start.current - g.dx)),
        onPanResponderTerminate: () => setDragWidth(null),
        onPanResponderTerminationRequest: () => false,
      }),
    [windowId],
  );

  if (!shown) return null;
  const room = width + layout.cardInset - 1;
  if (native)
    return (
      <Animated.View style={{ width: appear.interpolate({ inputRange: [0, 1], outputRange: [0, room] }), overflow: "hidden" }}>
        <Animated.View style={{ position: "absolute", top: 0, bottom: 0, right: 0, width: room, opacity: appear }}>
          <NativePanelCard windowId={windowId} panel={shown} width={width} onResize={(w, ended) => {
            if (ended) return settle(w);
            settling.current?.stop();
            setDragWidth(w);
          }} />
        </Animated.View>
      </Animated.View>
    );
  return (
    <Animated.View style={{ width: appear.interpolate({ inputRange: [0, 1], outputRange: [0, room] }), overflow: "hidden" }}>
      <Animated.View style={{ position: "absolute", top: 0, bottom: 0, right: 0, width: width, opacity: appear }}>
        <PanelCard key={`${shown.extensionId}|${shown.pageProfile}|${shown.url}|${shown.opened}`} windowId={windowId} panel={shown} />
        <View
          {...responder.panHandlers}
          onDoubleClick={() => setWindowSidebar(windowId, { sidePanelWidth: 360 })}
          style={{ position: "absolute", top: 0, bottom: 0, left: -3, width: 7, cursor: "col-resize" }}
        />
      </Animated.View>
    </Animated.View>
  );
}

function useShellRoom(windowId: string, appear: Animated.Value, room: number) {
  const shell = useWindowShell();
  const full = useRef(room);
  full.current = room;
  const push = useRef(nextFrame(() => void setWindowShellLayout(windowId, { sidePanel: full.current * current(appear) }))).current;
  const showing = room > 0;
  useEffect(() => {
    if (!shell || !showing) return;
    const sub = appear.addListener(push);
    return () => appear.removeListener(sub);
  }, [shell, showing]);
  useEffect(() => () => void requestAnimationFrame(() => void setWindowShellLayout(windowId, { sidePanel: 0 })), []);
  useEffect(() => {
    if (shell) push();
  }, [shell, room]);
}

function NativePanelCard({ windowId, panel, width, onResize }: { windowId: string; panel: SidePanel; width: number; onResize: (width: number, ended: boolean) => void }) {
  const { extensionId, profile, pageProfile, url, opened } = panel;
  const theme = useTheme();
  const ext = useExtensions((e) => e.lists[profile]?.find((x) => x.id === extensionId));
  const key = `${extensionId}|${pageProfile}|${url}|${opened}`;
  const live = useRef({ key, onResize });
  live.current = { key, onResize };
  useEffect(
    () =>
      onHostedEvent("extensionSidePanel", windowId, (name, payload) => {
        if (payload.key !== live.current.key) return;
        if (name === "menu") {
          const found = findExtension(profile, extensionId);
          if (found) void showExtensionMenu(windowId, found);
        } else if (name === "close") closeSidePanel(windowId);
        else if (name === "windowClose") closeSidePanel(windowId, extensionId);
        else if (name === "openWindow") {
          const [request] = unwrapPageEvent("onOpenWindow", payload.request as OpenWindowRequest) as [OpenWindowRequest];
          openFromPage(request, { windowId, profileId: pageProfileId(windowId, pageProfile) });
        } else if (name === "resize") live.current.onResize(Number(payload.width), !!payload.ended);
        else if (name === "resetWidth") setWindowSidebar(windowId, { sidePanelWidth: 360 });
      }),
    [windowId, profile, extensionId, pageProfile],
  );
  const state = JSON.stringify({
    key,
    pageProfile,
    url: toEngineUrl(url),
    title: ext?.actionTitle || ext?.name || "Extension",
    icon: ext?.actionIcon || ext?.icon || null,
    width,
    look: {
      card: theme.card,
      text: theme.textPrimary,
      icon: theme.icon,
      hover: theme.toolbarHover,
      pressed: theme.toolbarPressed,
      hairline: theme.dark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.08)",
      radius: layout.cardRadius,
    },
  });
  return <SolaraHostedView kind="extensionSidePanel" windowId={windowId} state={state} style={StyleSheet.absoluteFill} />;
}

function PanelCard({ windowId, panel }: { windowId: string; panel: SidePanel }) {
  const { extensionId, profile, pageProfile, url } = panel;
  const theme = useTheme();
  const ext = useExtensions((e) => e.lists[profile]?.find((x) => x.id === extensionId));
  const title = ext?.actionTitle || ext?.name || "Extension";
  const icon = ext?.actionIcon || ext?.icon;
  return (
    <View style={{ flex: 1, borderRadius: layout.cardRadius, overflow: "hidden", backgroundColor: theme.card }}>
      <View style={{ height: HEADER, flexDirection: "row", alignItems: "center", paddingLeft: 12, paddingRight: 5, gap: 8 }}>
        {icon ? <Image source={{ uri: icon }} style={{ width: 16, height: 16 }} /> : null}
        <Text numberOfLines={1} style={{ flex: 1, fontSize: 13, fontWeight: "500", color: theme.textPrimary }}>
          {title}
        </Text>
        <IconButton
          icon="ellipsis"
          size={13}
          tooltip="More"
          onPress={() => {
            const found = findExtension(profile, extensionId);
            if (found) void showExtensionMenu(windowId, found);
          }}
        />
        <IconButton icon="xmark" size={12} weight="medium" tooltip="Close Side Panel" onPress={() => closeSidePanel(windowId)} />
      </View>
      <Hairline color={theme.dark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.08)"} style={{ height: 1 }} />
      <View style={{ flex: 1, backgroundColor: "#FFFFFF" }}>
        <WebView
          style={StyleSheet.absoluteFill}
          url={url}
          profile={pageProfile}
          standalone
          extensionHost="sidePanel"
          pageBackgroundColor="#FFFFFF"
          onWindowClose={() => closeSidePanel(windowId, extensionId)}
          onOpenWindow={(request) => openFromPage(request, { windowId, profileId: pageProfileId(windowId, pageProfile) })}
        />
      </View>
    </View>
  );
}
