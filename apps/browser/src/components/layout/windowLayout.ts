import { dropNativeMeasuredWidth, setNativeMeasuredWidths } from "./measuredWidths";
import { WindowLayoutAnchorFeed, windowLayoutPreferences, windowShellActive, type WindowLayoutAnchors, type WindowLayoutPreferences } from "@solara/settings";
import { nativeSidebarShell } from "../sidebar/sidebarShell";
import { useState, useSyncExternalStore } from "react";
import { useShallow } from "zustand/react/shallow";
import { create } from "zustand";
import { switchOn } from "../../lib/killSwitches";
import { LIGHTS_CENTER, TOP_STRIP_LIGHTS_CENTER } from "./dockMotion";
import { layout } from "../../lib/theme";
import { useBrowser, type BrowserState } from "../../store/browser";
import { useWindowId } from "../../store/hooks";
import { nativeOwnsWorkspace } from "../../store/nativeStore";
import { sidebarUsesIconRail, sidebarWidthOf } from "../../store/sidebarRail";

const useNativePreferences = create<Record<string, WindowLayoutPreferences>>()(() => ({}));

export function applyWindowLayoutPreferences(windowId: string, json: string) {
  const next = JSON.parse(json) as WindowLayoutPreferences;
  const previous = useNativePreferences.getState()[windowId];
  if (!previous || next.generation > previous.generation || next.generation === previous.generation && next.revision > previous.revision) {
    if (previous?.generation === next.generation && previous.paneTabIds.length === next.paneTabIds.length
      && previous.paneTabIds.every((id, index) => id === next.paneTabIds[index])) next.paneTabIds = previous.paneTabIds;
    if (previous?.generation === next.generation && previous.split && next.split
      && JSON.stringify(previous.split) === JSON.stringify(next.split)) next.split = previous.split;
    useNativePreferences.setState({ [windowId]: next });
  }
}

export function endWindowLayoutPreferences(windowId: string, generation: number) {
  if (useNativePreferences.getState()[windowId]?.generation !== generation) return;
  useNativePreferences.setState((state) => {
    const next = { ...state };
    delete next[windowId];
    return next;
  }, true);
}

export function useTabLayout(): "sidebar" | "top" {
  return useWindowLayoutPreferences().topTabs ? "top" : "sidebar";
}

const noWindowPreferenceSubscription = () => () => {};

export function useWindowLayoutPreferences() {
  const windowId = useWindowId();
  const native = useNativeWindowPreferences(windowId, (value) => value && ({
    topTabs: value.topTabs,
    sidebarOpen: value.sidebarOpen,
    sidebarWidth: value.sidebarWidth,
    savedSidebarWidth: value.savedSidebarWidth,
    addressBar: value.addressBar && (value.sidebarOpen || switchOn("sidebarSlide")),
  }));
  const fallback = useWindowReplicaFallback(windowId, (s) => ({
    topTabs: (s.windows[windowId]?.tabLayout ?? s.settings.tabLayout) === "top",
    sidebarOpen: s.windows[windowId]?.sidebarOpen ?? true,
    sidebarWidth: sidebarWidthOf(s.windows[windowId], s.settings, nativeSidebarShell(windowId)),
    savedSidebarWidth: sidebarWidthOf(s.windows[windowId], s.settings, false),
    addressBar: addressBarInSidebar(s, windowId),
  }));
  return native ?? fallback ?? { topTabs: false, sidebarOpen: true, sidebarWidth: layout.sidebarWidth, savedSidebarWidth: layout.sidebarWidth, addressBar: false };
}

export function useWindowReplicaFallback<T>(windowId: string, select: (state: BrowserState) => T): T | null {
  const [hasShell] = useState(() => windowShellActive(windowId));
  const readsReplica = !hasShell || !nativeOwnsWorkspace();
  const selectFallback = useShallow(select);
  return useSyncExternalStore(
    readsReplica ? useBrowser.subscribe : noWindowPreferenceSubscription,
    () => readsReplica ? selectFallback(useBrowser.getState()) : null,
  );
}

export function useNativeWindowPreferences<T>(windowId: string, select: (value: WindowLayoutPreferences | null) => T): T {
  const [initial] = useState(() => windowLayoutPreferences(windowId));
  return useNativePreferences(useShallow((state) => {
    const latest = state[windowId];
    const current = latest && (!initial || latest.generation > initial.generation
      || latest.generation === initial.generation && latest.revision >= initial.revision) ? latest : initial;
    return select(current);
  }));
}

export function addressBarInSidebar(s: BrowserState, windowId: string): boolean {
  const w = s.windows[windowId];
  return (
    !!w &&
    s.settings.addressBar === "sidebar" &&
    (!w.sidebarOpen || !sidebarUsesIconRail(w, s.settings, nativeSidebarShell(windowId))) &&
    (w.sidebarOpen || switchOn("sidebarSlide")) &&
    (w.tabLayout ?? s.settings.tabLayout) === "sidebar"
  );
}

export function commandBarCentred(s: BrowserState, windowId: string): boolean {
  return s.settings.commandBarPlacement === "centred" && !!s.windows[windowId] && s.windows[windowId]!.kind !== "small";
}

export function useAddressBarInSidebar(): boolean {
  return useWindowLayoutPreferences().addressBar;
}

export function openingLightsCenter(s: BrowserState, windowId: string): [number, number] | null {
  const w = s.windows[windowId];
  if (!w) return null;
  if ((w.tabLayout ?? s.settings.tabLayout) === "top") return [...TOP_STRIP_LIGHTS_CENTER];
  return [...LIGHTS_CENTER];
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
