import { dropNativeMeasuredWidth, setNativeMeasuredWidths } from "./measuredWidths";
import { WindowLayoutAnchorFeed, type WindowLayoutAnchors } from "@solara/settings";
import { nativeSidebarShell } from "../sidebar/sidebarShell";
import { create } from "zustand";
import { switchOn } from "../../lib/killSwitches";
import { ARC_LIGHTS_CENTER, LIGHTS_CENTER, lightsCenter, TOP_STRIP_LIGHTS_CENTER } from "./dockMotion";
import { layout } from "../../lib/theme";
import { useBrowser, type BrowserState } from "../../store/browser";
import { useWindowId } from "../../store/hooks";
import { sidebarWidthOf, SIDEBAR_RAIL_WIDTH } from "../../store/sidebarRail";

export function useTabLayout(): "sidebar" | "top" {
  const windowId = useWindowId();
  return useBrowser((s) => s.windows[windowId]?.tabLayout ?? s.settings.tabLayout);
}

export function addressBarInSidebar(s: BrowserState, windowId: string): boolean {
  const w = s.windows[windowId];
  return (
    !!w &&
    s.settings.addressBar === "sidebar" &&
    sidebarWidthOf(s.windows[windowId], s.settings, nativeSidebarShell(windowId)) !== SIDEBAR_RAIL_WIDTH &&
    (w.sidebarOpen || switchOn("sidebarSlide")) &&
    (w.tabLayout ?? s.settings.tabLayout) === "sidebar"
  );
}

export function commandBarCentred(s: BrowserState, windowId: string): boolean {
  return s.settings.commandBarPlacement === "centred" && !!s.windows[windowId] && s.windows[windowId]!.kind !== "small";
}

export function useAddressBarInSidebar(): boolean {
  const windowId = useWindowId();
  return useBrowser((s) => addressBarInSidebar(s, windowId));
}

export function openingLightsCenter(s: BrowserState, windowId: string): [number, number] | null {
  const w = s.windows[windowId];
  if (!w) return null;
  const open = w.sidebarOpen ?? true;
  if ((w.tabLayout ?? s.settings.tabLayout) === "top") return open ? [...TOP_STRIP_LIGHTS_CENTER] : lightsCenter(layout.sidebarWidth);
  return lightsCenter(open ? 0 : sidebarWidthOf(s.windows[windowId], s.settings, nativeSidebarShell(windowId)), 0, addressBarInSidebar(s, windowId) ? ARC_LIGHTS_CENTER : LIGHTS_CENTER);
}

export const SIDEBAR_FIELD = { top: 46, height: layout.rowHeight, radius: 10 } as const;
export const SIDEBAR_FOOTER_DOWNLOADS = { bottom: 3 + (41 - 3 - 34) / 2, size: 34 } as const;
export function listTopGap(addressBar: boolean): number {
  return addressBar ? 6 : layout.pinnedTop - layout.sidebarHeader;
}

export const SIDEBAR_HEADER_WITH_FIELD = SIDEBAR_FIELD.top + SIDEBAR_FIELD.height;

type UrlAnchor = { left: number; top: number; width: number; sidebar?: { height: number } };

export const useUrlAnchors = create<Record<string, UrlAnchor>>()(() => ({}));

export function setUrlAnchor(windowId: string, anchor: UrlAnchor) {
  if (nativeWindowAnchorFeed.active(windowId)) return;
  writeUrlAnchor(windowId, anchor);
}

function writeUrlAnchor(windowId: string, anchor: UrlAnchor) {
  const current = useUrlAnchors.getState()[windowId];
  if (current && current.left === anchor.left && current.top === anchor.top && current.width === anchor.width && current.sidebar?.height === anchor.sidebar?.height) return;
  useUrlAnchors.setState({ [windowId]: anchor });
}

type CardAnchor = { left: number; top: number; width: number; height: number };

export const useNativeWindowBounds = create<Record<string, readonly [number, number, number, number]>>()(() => ({}));

export const useCardAnchors = create<Record<string, CardAnchor>>()(() => ({}));

export const nativeWindowAnchorFeed = new WindowLayoutAnchorFeed();
export const useNativePopoverAnchors = create<Record<string, Record<string, readonly [number, number, number, number]>>>()(() => ({}));

export function setCardAnchor(windowId: string, anchor: CardAnchor) {
  if (nativeWindowAnchorFeed.active(windowId)) return;
  writeCardAnchor(windowId, anchor);
}

function writeCardAnchor(windowId: string, anchor: CardAnchor) {
  const current = useCardAnchors.getState()[windowId];
  if (current && current.left === anchor.left && current.top === anchor.top && current.width === anchor.width && current.height === anchor.height) return;
  useCardAnchors.setState({ [windowId]: anchor });
}

export const useToolbarExtensionsWidths = create<Record<string, number>>()(() => ({}));

export function setToolbarExtensionsWidth(windowId: string, width: number) {
  if (useToolbarExtensionsWidths.getState()[windowId] === width) return;
  useToolbarExtensionsWidths.setState({ [windowId]: width });
}

export function applyNativeWindowAnchors(batch: WindowLayoutAnchors) {
  const popovers = Object.fromEntries(Object.entries(batch.anchors).filter(([name]) => name.startsWith("peekPopover:")).map(([name, rect]) => [name.slice("peekPopover:".length), rect]));
  const old = useNativePopoverAnchors.getState()[batch.windowId];
  if (JSON.stringify(old) !== JSON.stringify(popovers)) useNativePopoverAnchors.setState({ [batch.windowId]: popovers });
  setNativeMeasuredWidths({ [`profile-name|${batch.profileTitle}`]: batch.profileNameWidth, [`window-strip|${batch.windowId}`]: batch.stripAvailableWidth });
  const bounds = batch.anchors.window;
  if (bounds && JSON.stringify(useNativeWindowBounds.getState()[batch.windowId]) !== JSON.stringify(bounds)) useNativeWindowBounds.setState({ [batch.windowId]: bounds });
  const content = batch.anchors.content;
  if (content) writeCardAnchor(batch.windowId, { left: content[0], top: content[1], width: content[2], height: content[3] });
  const url = batch.anchors.url;
  if (url) writeUrlAnchor(batch.windowId, { left: url[0], top: url[1], width: url[2], ...(batch.sidebar ? { sidebar: { height: url[3] } } : {}) });
  else dropUrlAnchor(batch.windowId);
}

function dropUrlAnchor(windowId: string) {
  useUrlAnchors.setState((state) => {
    const next = { ...state };
    delete next[windowId];
    return next;
  }, true);
}

export function dropNativeWindowAnchors(windowId: string) {
  useNativeWindowBounds.setState((state) => {
    const next = { ...state };
    delete next[windowId];
    return next;
  }, true);
  useNativePopoverAnchors.setState((state) => {
    const next = { ...state };
    delete next[windowId];
    return next;
  }, true);
  dropNativeMeasuredWidth(`window-strip|${windowId}`);
  dropUrlAnchor(windowId);
  useCardAnchors.setState((state) => {
    const next = { ...state };
    delete next[windowId];
    return next;
  }, true);
}
