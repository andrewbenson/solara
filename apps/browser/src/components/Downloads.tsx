import { sidebarWidthOf, SIDEBAR_RAIL_WIDTH } from "../store/sidebarRail";
import { nativeSidebarShell } from "./sidebar/sidebarShell";
import { cancelDownload, keepDownload, pauseDownload, resumeDownload, type Download } from "@solara/solaracore";
import { copyText, fileExists, moveToTrash, openFile, revealFile, showMenu, type MenuItem } from "@solara/shell";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { StyleSheet, View, type LayoutChangeEvent } from "react-native";
import { useShortcutHint, withShortcut } from "../lib/commandShortcuts";
import { layout, useTheme } from "../lib/theme";
import { useShallow } from "zustand/react/shallow";
import { useBrowser } from "../store/browser";
import { useSidebarOpen, useWindowId, useWindowUi } from "../store/hooks";
import { downloadsIn, downloadVisibleIn } from "../store/ui";
import { SIDEBAR_FOOTER_DOWNLOADS, useAddressBarInSidebar, useTabLayout } from "./layout/windowLayout";
import { PROFILE_DOTS_HEIGHT, useProfileDotsShown } from "./profiles/ProfileDots";
import { openInternalPage } from "./pages/urls";
import { useSidebarWidth } from "./sidebar/tokens";
import { anchorInside, DOWNLOADS_PANEL, downloadsPlacement, type DownloadsPlacement, type Rect, type Size } from "./downloadsPlacement";
import { PANEL, usePopoverPresence } from "./layout/controls";
import { onHostedEvent, SolaraHostedView, windowShellActive, type NativeDownloadsEvent } from "@solara/settings";
import { useNativeDownloadsPanel } from "./nativeDownloadsPanel";
import { usePages } from "./layout/pageState";

function formatBytes(n: number) {
  if (n < 0) return "";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1000 && i < units.length - 1) {
    n /= 1000;
    i++;
  }
  return `${n < 10 && i > 0 ? n.toFixed(1) : Math.round(n)} ${units[i]}`;
}

function formatDuration(seconds: number) {
  if (seconds < 60) return `${Math.max(1, Math.round(seconds))} sec left`;
  if (seconds < 3600) return `${Math.round(seconds / 60)} min left`;
  return `${Math.round(seconds / 3600)} hr left`;
}

export const awaitsKeep = (d: Download) => d.state === "downloading" && d.dangerous === true;

export function dangerWarning(d: Download, short = false) {
  if (d.url.startsWith("http:")) return short ? "Blocked: not secure" : "Insecure download blocked";
  return short ? "Blocked: unsafe file type" : "This type of file can harm your computer";
}

export const dangerColor = (dark: boolean) => (dark ? "#FF453A" : "#FF3B30");

export function downloadStatus(d: Download, exists = true) {
  if (d.state === "finished") return exists ? formatBytes(d.total > 0 ? d.total : d.received) : "Deleted";
  if (d.state === "failed") return "Failed to Download";
  if (d.state === "cancelled") return "Cancelled";
  if (awaitsKeep(d)) return dangerWarning(d);
  const progress = d.total > 0 ? `${formatBytes(d.received)} of ${formatBytes(d.total)}` : formatBytes(d.received);
  if (d.paused) return `${progress} — Paused`;
  if (d.speed > 0 && d.total > 0) return `${progress}, ${formatBytes(d.speed)}/s — ${formatDuration((d.total - d.received) / d.speed)}`;
  return progress;
}

const openWhenDone = new Set<string>();

const g = globalThis as { __acDownloadsWatch?: () => void };
g.__acDownloadsWatch?.();
g.__acDownloadsWatch = useBrowser.subscribe((s, prev) => {
  if (s.downloads === prev.downloads || !openWhenDone.size) return;
  for (const d of s.downloads) {
    if (d.state !== "downloading" && openWhenDone.delete(d.id) && d.state === "finished") void openFile(d.path);
  }
});

function toggleOpenWhenDone(id: string) {
  if (openWhenDone.has(id)) openWhenDone.delete(id);
  else openWhenDone.add(id);
}

export async function downloadMenu(d: Download, windowId: string) {
  const exists = d.state === "finished" && fileExists(d.path);
  const items: MenuItem[] = awaitsKeep(d)
    ? [
        { id: "keep", title: "Keep" },
        { id: "cancel", title: "Discard" },
      ]
    : d.state === "downloading"
      ? [
          { id: "whenDone", title: "Open When Done", checked: openWhenDone.has(d.id) },
          { id: d.paused ? "resume" : "pause", title: d.paused ? "Resume" : "Pause" },
          { id: "cancel", title: "Cancel" },
        ]
      : [
          { id: "open", title: "Open", enabled: exists },
          { id: "reveal", title: "Show in Finder", enabled: exists },
        ];
  items.push(
    { separator: true },
    { id: "copy", title: "Copy Download Link" },
    { id: "page", title: "Show All Downloads" },
    { separator: true },
    ...(exists ? [{ id: "trash", title: "Move to Trash" }] : []),
    { id: "remove", title: "Remove from List", enabled: d.state !== "downloading" },
  );
  const choice = await showMenu(items);
  if (choice === "whenDone") toggleOpenWhenDone(d.id);
  if (choice === "pause") void pauseDownload(d.id);
  if (choice === "resume") void resumeDownload(d.id);
  if (choice === "keep") void keepDownload(d.id);
  if (choice === "cancel") void cancelDownload(d.id);
  if (choice === "open") void openFile(d.path);
  if (choice === "reveal") void revealFile(d.path);
  if (choice === "copy") copyText(d.url);
  if (choice === "page") openInternalPage("downloads", windowId);
  if (choice === "trash") void trashDownload(d);
  if (choice === "remove") useBrowser.getState().removeDownload(d.id);
}

async function trashDownload(d: Download) {
  if (await moveToTrash(d.path)) useBrowser.getState().removeDownload(d.id);
}

const HEADER = 24;
const ROW = 40;
const VISIBLE_ROWS = 8;
const INK_INSET = PANEL.inset + 1;
const HEADER_CAP_TOP = 7.5;
const FOOTER_TEXT_DROP = 12;
const PAD_TOP = INK_INSET - HEADER_CAP_TOP;
const PAD_BOTTOM = INK_INSET - FOOTER_TEXT_DROP;
const PANEL_CHROME = PAD_TOP + HEADER + StyleSheet.hairlineWidth + PANEL.separatorGap * 2 + PANEL.rowHeight + PAD_BOTTOM;
const PLACE_DEADLINE_MS = 120;

type DownloadsAnchor = () => Promise<Rect | null>;
const downloadsAnchors = new Map<string, Set<DownloadsAnchor>>();

export function registerDownloadsAnchor(windowId: string, measure: DownloadsAnchor) {
  const set = downloadsAnchors.get(windowId) ?? new Set<DownloadsAnchor>();
  downloadsAnchors.set(windowId, set);
  set.add(measure);
  return () => {
    set.delete(measure);
    if (!set.size && downloadsAnchors.get(windowId) === set) downloadsAnchors.delete(windowId);
  };
}

function measureInWindow(view: View): Promise<Rect | null> {
  return new Promise((resolve) => view.measureInWindow((x, y, width, height) => resolve(width > 0 && height > 0 ? { x, y, width, height } : null)));
}

async function locateDownloadsButton(windowId: string, origin: Rect): Promise<Rect | null> {
  const rects = await Promise.all([...(downloadsAnchors.get(windowId) ?? [])].map((measure) => measure().catch(() => null)));
  for (const rect of rects) {
    const local = rect && { x: rect.x - origin.x, y: rect.y - origin.y, width: rect.width, height: rect.height };
    if (anchorInside(origin, local)) return local;
  }
  return null;
}

let downloadPresentations = 0;

export function DownloadsButton({ windowId }: { windowId: string }) {
  const theme = useTheme();
  const [token] = useState(() => ++downloadPresentations);
  const open = useBrowser((s) => !!s.windowUi[windowId]?.downloadsOpen);
  const hint = useShortcutHint("downloads");
  const view = useRef<View>(null);
  useEffect(() => {
    const node = view.current;
    if (!node) return;
    return registerDownloadsAnchor(windowId, () => measureInWindow(node));
  }, [windowId]);
  useLayoutEffect(() => onHostedEvent("downloadsButton", windowId, (name, payload) => {
    if (name !== "press" || payload.token !== token) return;
    const s = useBrowser.getState();
    s.setDownloadsOpen(windowId, !s.windowUi[windowId]?.downloadsOpen);
  }), [windowId, token]);
  return (
    <View ref={view} collapsable={false} style={{ width: SIDEBAR_FOOTER_DOWNLOADS.size, height: SIDEBAR_FOOTER_DOWNLOADS.size }}>
      <SolaraHostedView kind="downloadsButton" windowId={windowId}
        state={JSON.stringify({ open, token, tooltip: open ? null : withShortcut("Downloads", hint), theme: { icon: theme.icon, toolbarHover: theme.toolbarHover, toolbarPressed: theme.toolbarPressed } })}
        style={StyleSheet.absoluteFill} />
    </View>
  );
}

export function DownloadsPopover() {
  const windowId = useWindowId();
  const { shown, closing, onClosed } = usePopoverPresence(useWindowUi().downloadsOpen);
  return shown ? <DownloadsPanel windowId={windowId} closing={closing} onClosed={onClosed} /> : null;
}

function DownloadsPanel({ windowId, closing, onClosed }: { windowId: string; closing: boolean; onClosed: () => void }) {
  const [inShell] = useState(() => windowShellActive(windowId));
  const liveIds = useBrowser(useShallow((s) => downloadsIn(s, windowId).map((d) => d.id)));
  const liveClearable = useBrowser((s) => downloadsIn(s, windowId).some((d) => d.state !== "downloading"));
  const shownList = useRef({ ids: liveIds, clearable: liveClearable });
  if (!closing) shownList.current = { ids: liveIds, clearable: liveClearable };
  const { ids, clearable } = shownList.current;
  const topStrip = useTabLayout() === "top";
  const addressBar = useAddressBarInSidebar();
  const setOpen = (value: boolean) => useBrowser.getState().setDownloadsOpen(windowId, value);
  const { root, placement: p, onLayout } = useDownloadsPlacement(windowId, closing, { topStrip, footer: addressBar, footerBottom: PROFILE_DOTS_HEIGHT + 2 });
  const placed = p !== null;
  const closed = useRef(onClosed);
  closed.current = onClosed;
  useEffect(
    () =>
      usePages.subscribe((s, prev) => {
        if (s.popover === prev.popover) return;
        const tabs = useBrowser.getState().tabs;
        if (Object.entries(s.popover).some(([tabId, popover]) => popover && !prev.popover[tabId] && tabs[tabId]?.windowId === windowId)) setOpen(false);
      }),
    [windowId],
  );
  useEffect(() => {
    if (!placed) {
      if (closing) closed.current();
      return;
    }
  }, [closing, placed]);

  const listMax = p ? Math.max(ROW, Math.min(VISIBLE_ROWS * ROW, p.room - PANEL_CHROME)) : VISIBLE_ROWS * ROW;

  return (
    <View ref={root} collapsable={false} onLayout={onLayout} pointerEvents={inShell || closing ? "none" : "auto"} style={StyleSheet.absoluteFill}>
      {p && <NativeDownloadsPanel windowId={windowId} inShell={inShell} ids={ids} clearable={clearable} listMax={listMax} placement={p} closing={closing} onClose={() => setOpen(false)} onClosed={() => closed.current()} />}
    </View>
  );
}

function NativeDownloadsPanel({ windowId, inShell, ids, clearable, listMax, placement, closing, onClose, onClosed }: { windowId: string; inShell: boolean; ids: string[]; clearable: boolean; listMax: number; placement: DownloadsPlacement; closing: boolean; onClose: () => void; onClosed: () => void }) {
  const { state, onEvent } = useDownloadsListFeed(windowId, ids, clearable, listMax, onClose);
  const [token] = useState(() => ++downloadPresentations);
  const { width, left, top, bottom, arrow, arrowX } = placement;
  const json = `{"list":${state},"placement":${JSON.stringify({ width, left, top, bottom, arrow, arrowX })},"closing":${closing},"token":${token}}`;
  const latest = useRef({ closing, onClose, onClosed, onEvent });
  latest.current = { closing, onClose, onClosed, onEvent };
  const handle = (e: NativeDownloadsEvent | { kind: "dismiss" | "closed"; token?: number }) => {
    if ((e as { token?: number }).token !== token) return;
    if (e.kind === "closed") { if (latest.current.closing) latest.current.onClosed(); }
    else if (!latest.current.closing) {
      if (e.kind === "dismiss") latest.current.onClose();
      else latest.current.onEvent(e as NativeDownloadsEvent);
    }
  };
  useNativeDownloadsPanel(windowId, inShell ? json : null, handle);
  useLayoutEffect(() => onHostedEvent("downloadsPanel", windowId, (name, payload) => {
    if (inShell) return;
    if (name === "action") handle(payload as NativeDownloadsEvent);
    else if (name === "dismiss" || name === "closed") handle({ kind: name, token: payload.token as number });
  }), [windowId, inShell, token]);
  return inShell ? null : <SolaraHostedView kind="downloadsPanel" windowId={windowId} state={json} style={StyleSheet.absoluteFill} />;
}

function useDownloadsListFeed(windowId: string, ids: string[], clearable: boolean, listMax: number, onClose: () => void) {
  const theme = useTheme();
  const downloads = useBrowser((s) => s.downloads);
  const last = useRef(new Map<string, Download>());
  const rows = ids
    .map((id) => {
      const d = downloads.find((x) => x.id === id) ?? last.current.get(id);
      if (d) last.current.set(id, d);
      return d;
    })
    .filter((d): d is Download => !!d)
    .map((d) => ({ id: d.id, url: d.url, filename: d.filename, path: d.path, state: d.state, received: d.received, total: d.total, speed: d.speed, paused: !!d.paused, dangerous: !!d.dangerous }));
  const state = JSON.stringify({
    rows,
    clearable,
    listMax,
    dark: !!theme.dark,
    theme: { textPrimary: theme.textPrimary, textSecondary: theme.textSecondary, textTertiary: theme.textTertiary, toolbarHover: theme.toolbarHover, toolbarPressed: theme.toolbarPressed, icon: theme.icon, iconDisabled: theme.iconDisabled, rowHover: theme.rowHover, accent: theme.accent },
  });
  const onEvent = (e: NativeDownloadsEvent) => {
    const d = e.id ? useBrowser.getState().downloads.find((x) => x.id === e.id) : undefined;
    if (e.kind === "clear") {
      onClose();
      return useBrowser.getState().clearDownloads(windowId);
    }
    if (e.kind === "viewAll") {
      onClose();
      return openInternalPage("downloads", windowId);
    }
    if (!d || !ids.includes(d.id) || !downloadVisibleIn(d, useBrowser.getState().windows[windowId])) return;
    if (e.kind === "open") void openFile(d.path);
    else if (e.kind === "reveal") void revealFile(d.path);
    else if (e.kind === "pause") void pauseDownload(d.id);
    else if (e.kind === "resume") void resumeDownload(d.id);
    else if (e.kind === "keep") void keepDownload(d.id);
    else if (e.kind === "cancel") void cancelDownload(d.id);
    else if (e.kind === "menu") void downloadMenu(d, windowId);
  };
  return { state, onEvent };
}

function useDownloadsPlacement(windowId: string, closing: boolean, fallback: { topStrip: boolean; footer: boolean; footerBottom: number }) {
  const root = useRef<View>(null);
  const [placement, setPlacement] = useState<DownloadsPlacement | null>(null);
  const [viewport, setViewport] = useState<Size | null>(null);
  const latest = useRef({ closing, fallback });
  latest.current = { closing, fallback };
  const ticket = useRef(0);
  const locate = () => {
    const node = root.current;
    if (!node) return;
    const mine = ++ticket.current;
    void measureInWindow(node).then(async (origin) => {
      if (!origin || mine !== ticket.current || latest.current.closing) return;
      const anchor = await locateDownloadsButton(windowId, origin);
      if (mine === ticket.current && !latest.current.closing) setPlacement(downloadsPlacement(origin, anchor, latest.current.fallback));
    });
  };
  useEffect(() => {
    if (!closing) locate();
  }, [closing, fallback.topStrip, fallback.footer]);
  useEffect(() => {
    if (placement || !viewport) return;
    const timer = setTimeout(() => setPlacement((placed) => placed ?? downloadsPlacement(viewport, null, latest.current.fallback)), PLACE_DEADLINE_MS);
    return () => clearTimeout(timer);
  }, [placement, viewport]);
  const onLayout = (e: LayoutChangeEvent) => {
    const { width, height } = e.nativeEvent.layout;
    setViewport({ width, height });
    if (!latest.current.closing) locate();
  };
  return { root, placement, onLayout };
}

export function DownloadMagnet() {
  const windowId = useWindowId();
  const sidebarOpen = useSidebarOpen();
  const sidebarWidth = useSidebarWidth(windowId);
  const topStrip = useTabLayout() === "top";
  const addressBar = useAddressBarInSidebar();
  const iconsOnly = useBrowser((s) => sidebarWidthOf(s.windows[windowId], s.settings, nativeSidebarShell(windowId)) === SIDEBAR_RAIL_WIDTH);
  const railDots = useProfileDotsShown();
  const [flight, setFlight] = useState<{ id: string; path: string } | null>(null);
  const [size, setSize] = useState({ width: 0, height: 0 });
  const seen = useRef<Set<string> | null>(null);

  useEffect(() => {
    seen.current = new Set(useBrowser.getState().downloads.map((d) => d.id));
    return useBrowser.subscribe((s, prev) => {
      if (s.downloads === prev.downloads) return;
      const fresh = s.downloads.find((d) => !seen.current!.has(d.id));
      s.downloads.forEach((d) => seen.current!.add(d.id));
      if (!fresh || s.ui.focusedWindowId !== windowId || !downloadVisibleIn(fresh, s.windows[windowId])) return;
      setFlight({ id: fresh.id, path: fresh.path || fresh.filename });
      setTimeout(() => setFlight((f) => (f?.id === fresh.id ? null : f)), 700);
    });
  }, [windowId]);

  const sidebar = !topStrip && sidebarOpen ? sidebarWidth : 0;
  const footer = { x: layout.sidebarInset + SIDEBAR_FOOTER_DOWNLOADS.size / 2, y: size.height - SIDEBAR_FOOTER_DOWNLOADS.bottom - SIDEBAR_FOOTER_DOWNLOADS.size / 2 };
  const railFooter = { x: sidebarWidth / 2, y: footer.y - (railDots ? PROFILE_DOTS_HEIGHT : 0) };
  const target = topStrip ? { x: size.width - 25, y: 21 } : addressBar ? footer : sidebarOpen ? (iconsOnly ? railFooter : { x: sidebarWidth - 24, y: 27 }) : { x: 24, y: 24 };
  const start = { x: sidebar + (size.width - sidebar) / 2, y: size.height * 0.45 };
  const state = JSON.stringify({ flight: flight && size.width > 0 ? { ...flight, start: [start.x, start.y], target: [target.x, target.y] } : null });
  return (
    <View pointerEvents="none" style={StyleSheet.absoluteFill} onLayout={(e) => setSize(e.nativeEvent.layout)}>
      <SolaraHostedView kind="downloadMagnet" windowId={windowId} state={state} pointerEvents="none" style={StyleSheet.absoluteFill} />
    </View>
  );
}
