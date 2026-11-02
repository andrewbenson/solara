import { displayUrl } from "@solara/core";
import { publishSettingsTopic, windowShellActive } from "@solara/settings";
import { useLayoutEffect, useState } from "react";
import type { LayoutChangeEvent } from "react-native";
import { hex, useTheme } from "../../lib/theme";
import { useIsSleeping } from "../../lib/tabLifecycle";
import { useBrowser } from "../../store/browser";
import { useIsBookmarked, useTab } from "../../store/hooks";
import { activeTabId, bookmarkProfileId, plural } from "../../store/model";
import { folderIn, folderLabel, folderMembers } from "../../store/tileFolders";
import { useShallow } from "zustand/react/shallow";
import { awayFromPin } from "../../store/organize";
import { openInSplit } from "../layout/splitActions";
import { useArtwork } from "../media/artwork";
import { mediaTheme, playerState } from "../media/nativeMedia";
import { togglePictureInPicture, useMedia, useSession } from "../media/state";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { openLiveItem } from "../../live/engine";
import { useLive } from "../../live/store";
import { useLiveColors } from "../live/colors";
import { calendarPreviewAction, useCalendarPreviewState } from "../live/CalendarPreview";
import type { CalendarEvent } from "../../live/meetings";
import { clickTab, tabTitle } from "./actions";
import { returnFocusToPage, useGroupRows } from "./GroupPanel";
import { cardHoverProps, dismissHover, holdHover } from "./hover";
import { useFolderPanel } from "./tileFolderUi";
import type { Anchor, Hover } from "./state";

const TOPIC = "sidebar.hoverCard";
const cards: Record<string, object> = {};
let queued = false;

export type NativeCardKind = "tab" | "group" | "live" | "player" | "calendar" | "folder";

export const FOLDER_PEEK_ROWS = 8;

function publish() {
  if (queued) return;
  queued = true;
  queueMicrotask(() => {
    queued = false;
    publishSettingsTopic(TOPIC, { windows: cards });
  });
}

function setCard(windowId: string, card: object | null) {
  if (card) cards[windowId] = card;
  else if (cards[windowId]) delete cards[windowId];
  else return;
  publish();
}

export function bareHost(url: string): string {
  try {
    const { protocol, hostname } = new URL(url);
    if ((protocol === "http:" || protocol === "https:") && hostname) return hostname.replace(/^www\./, "");
  } catch {}
  return displayUrl(url);
}

export function useNativeHoverCardActive(windowId: string): boolean {
  const [active] = useState(() => windowShellActive(windowId));
  return active;
}

export function nativeCardKind(active: boolean, hover: Hover | null, dia: boolean, player: boolean, calendar: boolean): NativeCardKind | null {
  if (!active || !hover) return null;
  if (dia) return "tab";
  if (hover.kind === "tab" && player) return "player";
  if (hover.kind === "tab" && !player && calendar) return "calendar";
  if (hover.kind === "group") return "group";
  if (hover.kind === "live") return "live";
  if (hover.kind === "folder") return "folder";
  return null;
}

const frame = (anchor: Anchor) => [anchor.x, anchor.y, anchor.width, anchor.height];

type Button = { action: string; icon: string; label: string };

function useTabCard(windowId: string, id: string | null, anchor: Anchor | null, sidebarWidth: number, windowHeight: number) {
  const theme = useTheme();
  const tab = useBrowser((s) => (id ? s.tabs[id] : undefined));
  const isActive = useBrowser((s) => !!id && activeTabId(s, windowId) === id);
  const bookmarked = useIsBookmarked(tab?.url ?? "");
  const video = useMedia((m) => !!id && (!!m.sessions[id]?.hasVideo || !!m.pipOpen[id]));
  const pip = useMedia((m) => !!id && !!m.pipOpen[id]);
  const sleeping = useIsSleeping(id ?? "");
  if (!id || !tab || !anchor) return null;
  const buttons: Button[] = [{ action: "pin", icon: tab.pinned ? "pin.slash" : "pin", label: tab.pinned ? "Unpin" : "Pin" }];
  if (tab.url) buttons.push({ action: "bookmark", icon: bookmarked ? "bookmark.fill" : "bookmark", label: bookmarked ? "Remove Bookmark" : "Bookmark" });
  if (!isActive && !tab.pinned) buttons.push({ action: "split", icon: "rectangle.split.2x1", label: "Open in Split View" });
  if (video) buttons.push({ action: "pip", icon: pip ? "pip.exit" : "pip.enter", label: pip ? "Exit Picture in Picture" : "Picture in Picture" });
  if (awayFromPin(tab)) buttons.push({ action: "back", icon: "arrow.uturn.backward", label: "Back to Pinned URL" });
  return {
    kind: "tab",
    tabId: id,
    title: tabTitle(tab),
    host: tab.url ? bareHost(tab.url) : null,
    sleeping,
    buttons,
    anchor: frame(anchor),
    sidebarWidth,
    windowHeight,
    look: {
      fill: theme.dark ? "#262626" : hex(theme.panel),
      border: theme.dark ? "#404040" : hex(theme.panelBorder),
      primary: theme.dark ? "rgba(255,255,255,0.86)" : theme.textPrimary,
      secondary: theme.dark ? "rgba(255,255,255,0.585)" : theme.textSecondary,
      tertiary: theme.textTertiary,
      hover: theme.toolbarHover,
      pressed: theme.toolbarPressed,
      shadowOpacity: theme.panelShadowOpacity,
    },
  };
}

function useGroupCard(windowId: string, id: string | null, anchor: Anchor | null, windowHeight: number) {
  const theme = useTheme();
  const exists = useBrowser((s) => !!id && !!s.groups[id]);
  const rows = useGroupRows(id ?? "", windowId);
  if (!id || !anchor || !exists) return null;
  return {
    kind: "group",
    groupId: id,
    rows: rows.map((r) => ({ id: r.id, title: r.title, url: r.url, usedAt: r.usedAt ?? 0, favicon: r.favicon, icon: r.icon, profileId: r.profileId })),
    anchor: frame(anchor),
    windowHeight,
    dark: theme.dark,
    theme: { textPrimary: theme.textPrimary, textSecondary: theme.textSecondary, textTertiary: theme.textTertiary, placeholder: theme.placeholder },
  };
}

const NO_IDS: string[] = [];

function useFolderCard(windowId: string, id: string | null, anchor: Anchor | null) {
  const theme = useTheme();
  const members = useBrowser(useShallow((s) => (id ? folderMembers(s, windowId, id) : NO_IDS)));
  const label = useBrowser((s) => (id ? folderLabel(folderIn(s, windowId, id)) : ""));
  const tabs = useBrowser(useShallow((s) => members.slice(0, FOLDER_PEEK_ROWS).map((m) => s.tabs[m])));
  const open = useFolderPanel((u) => !!id && u.open?.windowId === windowId && u.open.folderId === id);
  if (!id || !anchor || open || !members.length) return null;
  const more = members.length - FOLDER_PEEK_ROWS;
  return {
    kind: "folder",
    folderId: id,
    title: `${label} · ${plural(members.length, "tab")}`,
    rows: tabs.flatMap((t) => (t ? [{ id: t.id, title: tabTitle(t), url: t.url, favicon: t.favicon, icon: t.customIcon, profileId: t.profileId }] : [])),
    more: more > 0 ? `and ${more} more` : null,
    anchor: frame(anchor),
    dark: !!theme.dark,
    shadowOpacity: theme.panelShadowOpacity,
    theme: { panel: hex(theme.panel), panelBorder: hex(theme.panelBorder), textSecondary: theme.textSecondary, textTertiary: theme.textTertiary, textTab: theme.textTab, rowHover: theme.rowHover },
  };
}

function usePlayerCard(id: string | null, anchor: Anchor | null, edge: number) {
  const theme = useTheme();
  const session = useSession(id ?? undefined);
  const tab = useTab(id ?? "");
  const artwork = useArtwork(id ?? "", session?.artwork);
  if (!id || !anchor || !session || !tab) return null;
  return { kind: "player", state: JSON.stringify(playerState(session, tab, artwork, mediaTheme(theme))), anchor: frame(anchor), edge };
}

function liveItem(id: string): [string, string] {
  const [, folderId = "", itemId = ""] = id.split("|");
  return [folderId, itemId];
}

function useLiveCard(id: string | null, anchor: Anchor | null) {
  const theme = useTheme();
  const colors = useLiveColors();
  const [folderId, itemId] = id ? liveItem(id) : ["", ""];
  const exists = useLive((s) => !!id && !!s.items[folderId]?.some((i) => i.id === itemId));
  if (!id || !anchor || !exists) return null;
  return {
    kind: "live",
    id,
    anchor: frame(anchor),
    look: {
      dark: theme.dark,
      panel: hex(theme.panel),
      panelBorder: hex(theme.panelBorder),
      shadowOpacity: theme.panelShadowOpacity,
      textPrimary: theme.textPrimary,
      textSecondary: theme.textSecondary,
      divider: theme.divider,
      rowHover: theme.rowHover,
      accent: theme.accent,
      toolbarHover: theme.toolbarHover,
      toolbarPressed: theme.toolbarPressed,
      urlPill: theme.urlPill,
      success: colors.success,
      failure: colors.failure,
      pending: colors.pending,
      draft: colors.draft,
      conflict: colors.conflict,
      ciTrack: colors.ciTrack,
    },
  };
}

const calendarTimed: Record<string, CalendarEvent[]> = {};

export function NativeCalendarCard({ windowId, tabId, anchor }: { windowId: string; tabId: string; anchor: Anchor }) {
  const theme = useTheme();
  const { state, timed } = useCalendarPreviewState(tabId);
  calendarTimed[windowId] = timed;
  const dark = !!theme.dark;
  const key = JSON.stringify({
    kind: "calendar",
    tabId,
    anchor: frame(anchor),
    look: { dark, panel: hex(theme.panel), panelBorder: hex(theme.panelBorder), shadowOpacity: theme.panelShadowOpacity },
    state: JSON.stringify({ card: "calendarPreview", dark, nowColor: dark ? "#E5534B" : "#D1242F", ...state }),
  });
  useLayoutEffect(() => setCard(windowId, JSON.parse(key)), [windowId, key]);
  useLayoutEffect(
    () => () => {
      delete calendarTimed[windowId];
      setCard(windowId, null);
    },
    [windowId],
  );
  return null;
}

export function useNativeHoverCard(windowId: string, kind: NativeCardKind | null, target: Hover | null, sidebarWidth: number, windowHeight: number, edge: number) {
  const live = target && kind ? target : null;
  const anchor = live?.anchor ?? null;
  const tab = useTabCard(windowId, kind === "tab" ? (live?.id ?? null) : null, anchor, sidebarWidth, windowHeight);
  const group = useGroupCard(windowId, kind === "group" ? (live?.id ?? null) : null, anchor, windowHeight);
  const liveCard = useLiveCard(kind === "live" ? (live?.id ?? null) : null, anchor);
  const player = usePlayerCard(kind === "player" ? (live?.id ?? null) : null, anchor, edge);
  const folder = useFolderCard(windowId, kind === "folder" ? (live?.id ?? null) : null, anchor);
  const card = tab ?? group ?? liveCard ?? player ?? folder;
  const key = kind === "calendar" && live ? "calendar" : card && JSON.stringify(card);
  useLayoutEffect(() => {
    if (key !== "calendar") setCard(windowId, key ? JSON.parse(key) : null);
  }, [windowId, key]);
  useLayoutEffect(() => () => setCard(windowId, null), [windowId]);
}

addNativeSettingsHandlers({
  [TOPIC]: (windowId: string, id: string, event: string, extra?: { clickAt?: number; frame?: number[]; tabId?: string; url?: string; action?: string; eventId?: string }) => {
    if (event === "enter") return cardHoverProps.onMouseEnter();
    if (event === "leave") return cardHoverProps.onMouseLeave();
    if (event === "hold") return holdHover(true);
    if (event === "release") return holdHover(false);
    if (event === "close") return dismissHover();
    if (event === "focusPage") return returnFocusToPage(windowId);
    if (event === "choose") {
      if (!extra?.tabId) return;
      dismissHover();
      return clickTab(windowId, extra.tabId);
    }
    if (event === "open") {
      if (!extra?.url) return;
      dismissHover();
      return void useBrowser.getState().newTab(windowId, { url: extra.url });
    }
    if (event === "openItem") {
      const [folderId, itemId] = liveItem(id);
      const item = useLive.getState().items[folderId]?.find((i) => i.id === itemId);
      if (!item) return;
      dismissHover();
      return void openLiveItem(windowId, folderId, item);
    }
    if (event === "calendar") {
      if (!extra?.action) return;
      return calendarPreviewAction(id, windowId, calendarTimed[windowId] ?? [], { kind: extra.action, id: extra.eventId });
    }
    if (event === "layout") {
      const [x = 0, y = 0, width = 0, height = 0] = extra?.frame ?? [];
      return cardHoverProps.onLayout({ nativeEvent: { layout: { x, y, width, height } } } as LayoutChangeEvent);
    }
    const s = useBrowser.getState();
    const tab = s.tabs[id];
    if (!tab) return;
    switch (event) {
      case "pin":
        return s.togglePin(id);
      case "bookmark":
        return s.toggleBookmark(bookmarkProfileId(s, s.windows[windowId]), { url: tab.url, title: tabTitle(tab), favicon: tab.favicon });
      case "split":
        dismissHover();
        return openInSplit(id);
      case "pip":
        return void togglePictureInPicture(id, { clickAt: extra?.clickAt ?? 0, control: 0 });
      case "back":
        dismissHover();
        return s.returnToPinnedUrl(id);
    }
  },
});
