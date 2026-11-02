import { OutsidePressArea, Surface } from "@solara/shell";
import { useEffect, useLayoutEffect, useRef, useState, type ComponentProps, type ReactNode } from "react";
import { AccessibilityInfo, Animated, Easing, View, type LayoutChangeEvent } from "react-native";
import { hex, useTheme } from "../lib/theme";
import { useBrowser } from "../store/browser";
import { useWindowId, useWindowUi } from "../store/hooks";
import { activeTabId } from "../store/model";
import { useStoreWhile } from "../store/tabWatch";
import { pageOf, usePage } from "./layout/pageState";
import { dismissHover } from "./sidebar/hover";
import { commandBarCentred, useCardAnchors, useUrlAnchors } from "./layout/windowLayout";
import { barWidth } from "./NewTabPage";
import { markPanelFrame } from "../lib/perfMarks";
import { closeNewTabBar } from "./omnibox/newTabBar";
import type { NewTabTarget } from "../store/types";
import { breadcrumb } from "@solara/core";
import { nativeOmniboxAvailable, nativeUrlPrefixWidth, showNativePanel, sidebarAddressBarAvailable } from "@solara/settings";
import { NativeOmniboxBar } from "./omnibox/NativeOmniboxBar";
import { closePanelToHeroBar, type BarDismissal } from "./omnibox/barState";
import { insecureLevel, URL_FIELD, urlTextLeft } from "./Toolbar";
import { peekTabId } from "../store/peek";
import { useTabDeveloperMode } from "./site/developerMode";

const RIGHT_OF_URL = 40;
const ABOVE_PANE = 5.5;
const PANEL_RADIUS = 17;
const MIN_WIDTH = 420;
const WINDOW_MARGIN = 12;
const DROPDOWN_MIN_WIDTH = 350;
const DROPDOWN_PAST_FIELD = 137;
const DROPDOWN_RADIUS = 12;
const PANEL_OPEN_HEIGHT = 107;
const CENTRED_TOP_SHARE = 0.22;

const PANEL_TEXT_LEFT = 48;

const NATIVE_URL_TEXT_SHIFT = { x: 1.5, y: 0.5 };
const GROW_MS = 130;
const GROW_EASING = Easing.out(Easing.exp);

let reduceMotion = false;
AccessibilityInfo.isReduceMotionEnabled().then(
  (on) => (reduceMotion = on),
  () => {},
);
AccessibilityInfo.addEventListener("reduceMotionChanged", (on) => (reduceMotion = on));

type Box = { left: number; top: number; width: number; height: number };

const windowWidths = new Map<string, number>();
const panelStyles = new Map<string, { fill: string; border: string; shadowOpacity: number; radius: number }>();

export function CommandPanel({ windowWidth }: { windowWidth: number }) {
  const windowId = useWindowId();
  windowWidths.set(windowId, windowWidth);
  return (
    <>
      {nativeOmniboxAvailable() ? <NativePanelHost windowId={windowId} windowWidth={windowWidth} /> : null}
      <CommandPanelBody windowWidth={windowWidth} />
    </>
  );
}

type PanelGeometry = { left: number; top: number; width: number; from: Box | null };

function toolbarPanelGeometry(anchor: { left: number; top: number; width: number }, insecure: boolean, hasField: boolean, windowWidth: number, text: string, native: boolean): PanelGeometry {
  const room = (left: number, fallback: number) => (windowWidth > 0 ? windowWidth - left - WINDOW_MARGIN : fallback);
  const shift = native ? NATIVE_URL_TEXT_SHIFT : { x: 0, y: 0 };
  const aligned = Math.max(WINDOW_MARGIN, anchor.left + urlTextLeft(insecure, native) - PANEL_TEXT_LEFT + shift.x);
  const lead = native && !insecure ? schemeLead(text) : 0;
  const left = lead && aligned - lead >= WINDOW_MARGIN ? aligned - lead : aligned;
  const top = Math.max(0.5, anchor.top - ABOVE_PANE) + shift.y;
  const covering = anchor.left + anchor.width + RIGHT_OF_URL - left;
  const width = Math.min(Math.max(covering, MIN_WIDTH), room(left, covering));
  const from = hasField ? { left: anchor.left, top: anchor.top + URL_FIELD.top, width: anchor.width, height: URL_FIELD.height } : null;
  return { left, top, width, from };
}

type UrlAnchor = NonNullable<ReturnType<typeof useUrlAnchors.getState>[string]>;

function dropdownGeometry(anchor: UrlAnchor, windowWidth: number): PanelGeometry {
  const shown = anchor.left >= 0;
  const left = shown ? anchor.left : WINDOW_MARGIN;
  const room = windowWidth > 0 ? windowWidth - left - WINDOW_MARGIN : DROPDOWN_MIN_WIDTH;
  const width = Math.min(Math.max(DROPDOWN_MIN_WIDTH, anchor.width + DROPDOWN_PAST_FIELD), room);
  const from = shown && anchor.sidebar ? { left, top: anchor.top, width: anchor.width, height: anchor.sidebar.height } : null;
  return { left, top: anchor.top, width, from };
}

const dropdownIsNative = (kind: string | undefined) => kind === "small" || sidebarAddressBarAvailable();
const nativeDropdown = (windowId: string) => dropdownIsNative(useBrowser.getState().windows[windowId]?.kind);

function nativePanelGeometry(windowId: string, anchor: UrlAnchor, insecure: boolean, windowWidth: number, text: string) {
  if (!anchor.sidebar) return toolbarPanelGeometry(anchor, insecure, true, windowWidth, text, true);
  return nativeDropdown(windowId) ? { ...dropdownGeometry(anchor, windowWidth), radius: DROPDOWN_RADIUS, variant: "sidebar" } : null;
}

function nativePanelJson(windowId: string, tabId: string, text: string, open: boolean): string | null {
  const anchor = useUrlAnchors.getState()[windowId];
  const tab = useBrowser.getState().tabs[tabId];
  const style = panelStyles.get(windowId);
  if (!anchor || !tab?.url || !style) return null;
  const geometry = nativePanelGeometry(windowId, anchor, !!insecureLevel(pageOf(tabId)), windowWidths.get(windowId) ?? 0, text);
  return geometry ? JSON.stringify({ open, tabId, text, ...style, ...geometry }) : null;
}

export function showNativePanelNow(windowId: string, text: string) {
  if (!nativeOmniboxAvailable()) return;
  const s = useBrowser.getState();
  const tabId = activeTabId(s, windowId);
  if (!tabId || commandBarCentred(s, windowId)) return;
  const json = nativePanelJson(windowId, tabId, text, true);
  if (json) showNativePanel(windowId, json);
}

function NativePanelHost({ windowId, windowWidth }: { windowId: string; windowWidth: number }) {
  const theme = useTheme();
  const { panel } = useWindowUi();
  const tabId = useBrowser((s) => activeTabId(s, windowId));
  const url = useBrowser((s) => (tabId ? (s.tabs[tabId]?.url ?? "") : ""));
  const insecure = usePage(tabId, (p) => !!insecureLevel(p));
  const anchor = useUrlAnchors((s) => s[windowId]);
  const centred = useBrowser((s) => commandBarCentred(s, windowId));
  const peeking = useBrowser((s) => !!peekTabId(s, windowId));
  const developer = useTabDeveloperMode(tabId);
  const dropdown = useBrowser((s) => dropdownIsNative(s.windows[windowId]?.kind));
  panelStyles.set(windowId, { fill: theme.panel, border: theme.panelBorder, shadowOpacity: theme.panelShadowOpacity, radius: PANEL_RADIUS });
  if (!tabId || !anchor || (anchor.sidebar ? !dropdown : !url)) return null;
  const open = panel.open && !panel.newTab && !centred;
  const text = open ? panel.initialText : url;
  const ready = !panel.open && !centred && !peeking && !developer;
  const geometry = nativePanelGeometry(windowId, anchor, insecure, windowWidth, text);
  const json = JSON.stringify({ open, ready, tabId, text, ...panelStyles.get(windowId), ...geometry });
  const onCancel = () => useBrowser.getState().closePanel(windowId);
  const onDone = (reason?: BarDismissal) => closePanelToHeroBar(windowId, tabId, reason);
  return <NativeOmniboxBar variant={anchor.sidebar ? "sidebar" : "panel"} tabId={tabId} initialText={text} panel={json} idle={!open} onCancel={onCancel} onDone={onDone} />;
}

function CommandPanelBody({ windowWidth }: { windowWidth: number }) {
  const theme = useTheme();
  const windowId = useWindowId();
  const { panel } = useWindowUi();
  const activeId = useBrowser((s) => (panel.open ? activeTabId(s, windowId) : undefined));
  const hasField = useStoreWhile(useBrowser, panel.open, (s) => !!(activeId && s.tabs[activeId]?.url));
  const insecure = usePage(activeId, (p) => !!insecureLevel(p));
  const anchor = useUrlAnchors((s) => (panel.open ? s[windowId] : undefined));
  const centred = useBrowser((s) => panel.open && !panel.newTab && commandBarCentred(s, windowId));
  const card = useCardAnchors((s) => (panel.newTab || centred ? s[windowId] : undefined));
  useEffect(() => {
    if (panel.open) dismissHover();
  }, [panel.open]);
  if (!panel.open || !activeId) return null;
  if (panel.newTab) return card ? <CentredBar windowId={windowId} tabId={activeId} target={panel.newTab} card={card} /> : null;

  const onCancel = () => useBrowser.getState().closePanel(windowId);
  const onDone = (reason?: BarDismissal) => closePanelToHeroBar(windowId, activeId, reason);
  const surface = (radius: number) => panelSurface(theme, radius);

  if (centred && card) {
    return (
      <Grow from={null} frame={centredFrame(card)} openHeight={PANEL_OPEN_HEIGHT} radius={PANEL_RADIUS} surface={surface(PANEL_RADIUS)}>
        <OutsidePressArea onOutsidePress={onCancel}>
          <NativeOmniboxBar key={activeId} variant="panel" floating tabId={activeId} initialText={panel.initialText} onCancel={onCancel} onDone={onDone} />
        </OutsidePressArea>
      </Grow>
    );
  }
  if (!anchor) return null;

  if (anchor.sidebar) {
    if (nativeOmniboxAvailable() && nativeDropdown(windowId)) return null;
    const { left, width, from } = dropdownGeometry(anchor, windowWidth);
    return (
      <Grow from={from} frame={{ left, top: anchor.top, width }} openHeight={anchor.sidebar.height} radius={DROPDOWN_RADIUS} surface={surface(DROPDOWN_RADIUS)}>
        <OutsidePressArea onOutsidePress={onCancel}>
          <NativeOmniboxBar key={activeId} variant="sidebar" tabId={activeId} initialText={panel.initialText} onCancel={onCancel} onDone={onDone} />
        </OutsidePressArea>
      </Grow>
    );
  }

  const native = nativeOmniboxAvailable();
  if (native && hasField) return null;
  const { left, top, width, from } = toolbarPanelGeometry(anchor, insecure, hasField, windowWidth, panel.initialText, native);
  return (
    <Grow from={from} frame={{ left, top, width }} openHeight={PANEL_OPEN_HEIGHT} radius={PANEL_RADIUS} surface={surface(PANEL_RADIUS)}>
      <OutsidePressArea onOutsidePress={onCancel}>
        <NativeOmniboxBar key={activeId} variant="panel" tabId={activeId} initialText={panel.initialText} onCancel={onCancel} onDone={onDone} />
      </OutsidePressArea>
    </Grow>
  );
}

function schemeLead(text: string) {
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(text)) return 0;
  const host = breadcrumb(text).host;
  const at = host ? text.indexOf(host, text.indexOf("://") + 3) : -1;
  return at > 0 ? nativeUrlPrefixWidth(text.slice(0, at), text) : 0;
}

function panelSurface(theme: ReturnType<typeof useTheme>, radius: number) {
  return {
    fill: hex(theme.panel),
    cornerRadius: radius,
    borderColor: hex(theme.panelBorder),
    borderWidth: 0.5,
    shadowColor: "#000000",
    shadowOpacity: theme.panelShadowOpacity,
    shadowRadius: 24,
    shadowOffset: [0, 10] as [number, number],
  };
}

function centredFrame(card: Box) {
  const width = barWidth(card.width);
  const left = card.left + (card.width - width) / 2;
  const top = card.top + Math.max(WINDOW_MARGIN, Math.round(card.height * CENTRED_TOP_SHARE));
  return { left, top, width };
}

function CentredBar({ windowId, tabId, target, card }: { windowId: string; tabId: string; target: NewTabTarget; card: Box }) {
  const theme = useTheme();
  const onCancel = () => useBrowser.getState().closePanel(windowId);
  const onDone = () => closeNewTabBar(windowId);
  return (
    <Grow
      from={null}
      frame={centredFrame(card)}
      openHeight={PANEL_OPEN_HEIGHT}
      radius={PANEL_RADIUS}
      surface={panelSurface(theme, PANEL_RADIUS)}
    >
      <OutsidePressArea onOutsidePress={onCancel}>
        <NativeOmniboxBar key={`newTab:${target.kind}`} variant="panel" floating tabId={tabId} opensTab={target} onCancel={onCancel} onDone={onDone} />
      </OutsidePressArea>
    </Grow>
  );
}

function Grow({
  from,
  frame,
  openHeight,
  radius,
  surface,
  children,
}: {
  from: Box | null;
  frame: { left: number; top: number; width: number };
  openHeight: number;
  radius: number;
  surface: Omit<ComponentProps<typeof Surface>, "style">;
  children: ReactNode;
}) {
  const fade = !!from && reduceMotion;
  const [progress] = useState(() => new Animated.Value(from ? 0 : 1));
  const start = useRef(fade ? null : from);
  const [height, setHeight] = useState<number | null>(null);
  const onLayout = (e: LayoutChangeEvent) => {
    const measured = e.nativeEvent.layout.height;
    if (height === null && measured >= (from?.height ?? 0)) setHeight(measured);
  };
  useLayoutEffect(() => markPanelFrame("mount"), []);
  useEffect(() => {
    if (!from || height === null) return;
    markPanelFrame("growStart");
    Animated.timing(progress, { toValue: 1, duration: GROW_MS, easing: GROW_EASING, useNativeDriver: true }).start(({ finished }) => finished && markPanelFrame("growEnd"));
  }, [height === null]);

  const box = start.current;
  let outer: object = fade ? { opacity: progress } : {};
  let inner: object = {};
  if (box) {
    const h = height ?? openHeight;
    const at = (v: number) => progress.interpolate({ inputRange: [0, 1], outputRange: [v, 1] });
    const shift = (v: number) => progress.interpolate({ inputRange: [0, 1], outputRange: [v, 0] });
    const scaleX = at(box.width / frame.width);
    const scaleY = at(box.height / h);
    const x = shift(box.left + box.width / 2 - (frame.left + frame.width / 2));
    const y = shift(box.top + box.height / 2 - (frame.top + h / 2));
    outer = { transform: [{ translateX: x }, { translateY: y }, { scaleX }, { scaleY }] };
    inner = {
      transform: [
        { scaleX: Animated.divide(1, scaleX) },
        { scaleY: Animated.divide(1, scaleY) },
        { translateX: Animated.multiply(x, -1) },
        { translateY: Animated.multiply(y, -1) },
      ],
    };
  }
  return (
    <Animated.View onLayout={onLayout} style={[{ position: "absolute", ...frame }, outer]}>
      <Surface {...surface} style={{ position: "absolute", top: 0, left: 0, right: 0, bottom: 0 }} />
      <View style={box ? { overflow: "hidden", borderRadius: radius } : undefined}>
        <Animated.View style={inner}>{children}</Animated.View>
      </View>
    </Animated.View>
  );
}
