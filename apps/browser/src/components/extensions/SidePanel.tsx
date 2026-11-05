import { unwrapPageEvent, type OpenWindowRequest } from "@solara/solaracore";
import { toEngineUrl } from "@solara/core";
import { focusPageIfUnclaimed, onHostedEvent, setWindowShellLayout, SolaraHostedView } from "@solara/settings";
import { useEffect, useMemo, useRef, useState } from "react";
import { Animated, Easing, StyleSheet } from "react-native";
import { layout, useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { setWindowSidebar, sidePanelWidthOf } from "../../store/sidebarRail";
import { shownPageId } from "../../store/peek";
import { useWindowId } from "../../store/hooks";
import { useWindowShell } from "../layout/ShellBackdrop";
import { current, nextFrame } from "../layout/shellLayout";
import { openFromPage, pageProfileId } from "../layout/openFromPage";
import { closeSidePanel, findExtension, showExtensionMenu, useExtensions, type SidePanel } from "./state";

const MIN_WIDTH = 320;
const MAX_WIDTH = 600;

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
  refocusActivePageOnPanelLoss();

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
  if (!shown) return null;
  const room = width + layout.cardInset - 1;
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
