import { sidebarWidthOf, SIDEBAR_RAIL_WIDTH } from "../store/sidebarRail";
import { nativeSidebarShell } from "./sidebar/sidebarShell";
import { cancelDownload, keepDownload, pauseDownload, resumeDownload, type Download } from "@solara/solaracore";
import { ContextMenuArea, copyText, fileExists, fileIcon, MouseArea, moveToTrash, openFile, PopoverBubble, popoverBubbleAvailable, revealFile, showMenu, Surface, Symbol, VisualEffect, type MenuItem } from "@solara/shell";
import { memo, useEffect, useRef, useState } from "react";
import { Animated, Image, Pressable, ScrollView, StyleSheet, Text, View, type LayoutChangeEvent } from "react-native";
import { useShortcutHint, withShortcut } from "../lib/commandShortcuts";
import { hex, layout, useTheme } from "../lib/theme";
import { useShallow } from "zustand/react/shallow";
import { useBrowser } from "../store/browser";
import { useSidebarOpen, useWindowId, useWindowUi } from "../store/hooks";
import { downloadsIn, downloadVisibleIn } from "../store/ui";
import { SIDEBAR_FOOTER_DOWNLOADS, useAddressBarInSidebar, useTabLayout } from "./layout/windowLayout";
import { PROFILE_DOTS_HEIGHT, useProfileDotsShown } from "./profiles/ProfileDots";
import { openInternalPage } from "./pages/urls";
import { useSidebarWidth } from "./sidebar/tokens";
import { HoverSlot } from "./HoverSlot";
import { anchorInside, DOWNLOADS_PANEL, downloadsPlacement, type DownloadsPlacement, type Rect, type Size } from "./downloadsPlacement";
import { PANEL, POPOVER_MOTION, PopoverSeparator, usePopoverPresence } from "./layout/controls";
import { IconButton, useHover } from "./primitives";
import { nativeToolbarAvailable, NativeDownloadsView, SolaraHostedView, windowShellActive, type NativeDownloadsEvent } from "@solara/settings";
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

const iconCache = new Map<string, string | null>();
export const FileIcon = memo(function FileIcon({ path, size = 28 }: { path: string; size?: number }) {
  const theme = useTheme();
  const key = `${path}@${size}`;
  const [uri, setUri] = useState(() => iconCache.get(key) ?? null);
  useEffect(() => {
    if (iconCache.has(key)) return setUri(iconCache.get(key) ?? null);
    let live = true;
    void fileIcon(path || "file.bin", size).then((u) => {
      iconCache.set(key, u);
      if (live) setUri(u);
    });
    return () => {
      live = false;
    };
  }, [key]);
  return uri ? (
    <Image source={{ uri }} style={{ width: size, height: size }} />
  ) : (
    <Symbol name="doc" size={size * 0.62} color={theme.icon} style={{ width: size, height: size }} />
  );
});

const HEADER = 24;
const ROW = 40;
const FILE_ICON = 24;
const ROW_BUTTON = 22;
const ROW_BUTTON_BEARING = (ROW_BUTTON - PANEL.iconSize) / 2;
const VISIBLE_ROWS = 8;
const TEXT_BUTTON_PAD = 7;
const INK_INSET = PANEL.inset + 1;
const HEADER_CAP_TOP = 7.5;
const FOOTER_TEXT_DROP = 12;
const CHEVRON_BEARING = 3;
const PAD_TOP = INK_INSET - HEADER_CAP_TOP;
const PAD_BOTTOM = INK_INSET - FOOTER_TEXT_DROP;
const PANEL_CHROME = PAD_TOP + HEADER + StyleSheet.hairlineWidth + PANEL.separatorGap * 2 + PANEL.rowHeight + PAD_BOTTOM;
const PLACE_DEADLINE_MS = 120;

function rowFill(dark: boolean, hovered: boolean, pressed: boolean) {
  if (!hovered && !pressed) return undefined;
  return dark ? `rgba(255,255,255,${pressed ? 0.12 : 0.07})` : `rgba(0,0,0,${pressed ? 0.1 : 0.06})`;
}

const progressTrack = (dark: boolean) => (dark ? "#717782" : "#CED7E7");

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

export function DownloadsButton({ windowId }: { windowId: string }) {
  const open = useBrowser((s) => !!s.windowUi[windowId]?.downloadsOpen);
  const hint = useShortcutHint("downloads");
  const view = useRef<View>(null);
  useEffect(() => {
    const node = view.current;
    if (!node) return;
    return registerDownloadsAnchor(windowId, () => measureInWindow(node));
  }, [windowId]);
  return (
    <View ref={view} collapsable={false}>
      <IconButton
        icon="arrow.down.circle"
        size={16}
        box={SIDEBAR_FOOTER_DOWNLOADS.size}
        radius={10}
        active={open}
        tooltip={open ? undefined : withShortcut("Downloads", hint)}
        onPress={() => {
          const s = useBrowser.getState();
          s.setDownloadsOpen(windowId, !s.windowUi[windowId]?.downloadsOpen);
        }}
      />
    </View>
  );
}

export function DownloadsPopover() {
  const windowId = useWindowId();
  const { shown, closing, onClosed } = usePopoverPresence(useWindowUi().downloadsOpen);
  return shown ? <DownloadsPanel windowId={windowId} closing={closing} onClosed={onClosed} /> : null;
}

function DownloadsPanel({ windowId, closing, onClosed }: { windowId: string; closing: boolean; onClosed: () => void }) {
  const theme = useTheme();
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
  const appear = useRef(new Animated.Value(0)).current;
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
    if (inShell) return;
    const motion = closing ? POPOVER_MOTION.close : POPOVER_MOTION.open;
    Animated.timing(appear, { toValue: closing ? 0 : 1, duration: motion.duration, easing: motion.easing, useNativeDriver: true }).start(
      ({ finished }) => finished && closing && closed.current(),
    );
  }, [closing, placed]);

  const upward = p?.bottom !== undefined;
  const arrowRoom = p && p.arrow !== "none" ? DOWNLOADS_PANEL.arrowHeight : 0;
  const listMax = p ? Math.max(ROW, Math.min(VISIBLE_ROWS * ROW, p.room - PANEL_CHROME)) : VISIBLE_ROWS * ROW;

  if (inShell) {
    return (
      <View ref={root} collapsable={false} onLayout={onLayout} pointerEvents="none" style={StyleSheet.absoluteFill}>
        {p && <ShellDownloadsPanel windowId={windowId} ids={ids} clearable={clearable} listMax={listMax} placement={p} closing={closing} onClose={() => setOpen(false)} onClosed={() => closed.current()} />}
      </View>
    );
  }

  return (
    <View ref={root} collapsable={false} onLayout={onLayout} pointerEvents={closing ? "none" : "auto"} style={StyleSheet.absoluteFill}>
      <Pressable style={StyleSheet.absoluteFill} onPress={() => setOpen(false)} />
      {p ? (
        <Animated.View
          style={{
            position: "absolute",
            left: p.left,
            ...(upward ? { bottom: p.bottom } : { top: p.top }),
            width: p.width,
            opacity: appear,
            transformOrigin: `${p.arrowX}px ${upward ? "bottom" : "top"}`,
            transform: [
              { scale: appear.interpolate({ inputRange: [0, 1], outputRange: [0.94, 1] }) },
              { translateY: appear.interpolate({ inputRange: [0, 1], outputRange: upward ? [4, 0] : [-4, 0] }) },
            ],
          }}
        >
          <PanelBackground placement={p} />
          {nativeToolbarAvailable() ? (
            <View style={{ marginTop: upward ? 0 : arrowRoom, marginBottom: upward ? arrowRoom : 0 }}>
              <NativeDownloadsList windowId={windowId} ids={ids} clearable={clearable} listMax={listMax} onClose={() => setOpen(false)} />
            </View>
          ) : (
          <View style={{ marginTop: upward ? 0 : arrowRoom, marginBottom: upward ? arrowRoom : 0, paddingTop: PAD_TOP, paddingBottom: PAD_BOTTOM }}>
            <View style={{ flexDirection: "row", alignItems: "center", paddingLeft: PANEL.inset, paddingRight: PANEL.inset - TEXT_BUTTON_PAD, height: HEADER }}>
              <Text style={{ flex: 1, fontSize: PANEL.subtitleSize, fontWeight: "600", letterSpacing: 0.4, color: theme.textSecondary }}>
                RECENT DOWNLOADS
              </Text>
              {clearable && (
                <TextButton
                  title="Clear"
                  onPress={() => {
                    setOpen(false);
                    useBrowser.getState().clearDownloads(windowId);
                  }}
                />
              )}
            </View>
            {ids.length === 0 ? (
              <View style={{ height: PANEL.rowHeight, paddingHorizontal: PANEL.inset, justifyContent: "center" }}>
                <Text style={{ fontSize: PANEL.titleSize, color: theme.textSecondary }}>No downloads yet</Text>
              </View>
            ) : (
              <ScrollView style={{ maxHeight: listMax }} contentContainerStyle={{ paddingHorizontal: PANEL.rowInset }}>
                {ids.map((id) => (
                  <DownloadRowItem key={id} id={id} windowId={windowId} />
                ))}
              </ScrollView>
            )}
            <PopoverSeparator />
            <FooterButton
              title="View all downloads"
              onPress={() => {
                setOpen(false);
                openInternalPage("downloads", windowId);
              }}
            />
          </View>
          )}
        </Animated.View>
      ) : null}
    </View>
  );
}

function ShellDownloadsPanel({ windowId, ids, clearable, listMax, placement, closing, onClose, onClosed }: { windowId: string; ids: string[]; clearable: boolean; listMax: number; placement: DownloadsPlacement; closing: boolean; onClose: () => void; onClosed: () => void }) {
  const { state, onEvent } = useDownloadsListFeed(windowId, ids, clearable, listMax, onClose);
  const { width, left, top, bottom, arrow, arrowX } = placement;
  useNativeDownloadsPanel(windowId, `{"list":${state},"placement":${JSON.stringify({ width, left, top, bottom, arrow, arrowX })},"closing":${closing}}`, (e) => {
    if (e.kind === "dismiss") onClose();
    else if (e.kind === "closed") onClosed();
    else onEvent(e);
  });
  return null;
}

function NativeDownloadsList({ windowId, ids, clearable, listMax, onClose }: { windowId: string; ids: string[]; clearable: boolean; listMax: number; onClose: () => void }) {
  const { state, onEvent } = useDownloadsListFeed(windowId, ids, clearable, listMax, onClose);
  const [height, setHeight] = useState<number | null>(null);
  return (
    <View style={{ height: height ?? undefined, minHeight: 1 }}>
      <NativeDownloadsView style={StyleSheet.absoluteFill} state={state} onDownloadsEvent={(e) => onEvent(e.nativeEvent)} onDownloadsHeight={(e) => setHeight(e.nativeEvent.height)} />
    </View>
  );
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
    if (!d) return;
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

function PanelBackground({ placement }: { placement: DownloadsPlacement }) {
  const theme = useTheme();
  const edge = hex(theme.dark ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.12)");
  const tint = theme.dark ? "rgba(38,36,37,0.3)" : "rgba(252,251,252,0.3)";
  if (popoverBubbleAvailable) {
    return (
      <PopoverBubble
        material="popover"
        dark={theme.dark}
        cornerRadius={PANEL.radius}
        arrowEdge={placement.arrow}
        arrowX={placement.arrowX}
        arrowWidth={DOWNLOADS_PANEL.arrowWidth}
        arrowHeight={DOWNLOADS_PANEL.arrowHeight}
        tint={hex(tint)}
        edgeColor={edge}
        edgeWidth={0.5}
        shadowOpacity={theme.dark ? 0.45 : 0.16}
        shadowRadius={18}
        shadowOffsetY={8}
        style={StyleSheet.absoluteFill}
      />
    );
  }
  const arrowRoom = placement.arrow === "none" ? 0 : DOWNLOADS_PANEL.arrowHeight;
  return (
    <Surface
      cornerRadius={PANEL.radius}
      borderColor={edge}
      borderWidth={0.5}
      shadowColor="#000000"
      shadowOpacity={theme.dark ? 0.45 : 0.16}
      shadowRadius={18}
      shadowOffset={[0, 8]}
      style={{ ...StyleSheet.absoluteFillObject, top: placement.arrow === "top" ? arrowRoom : 0, bottom: placement.arrow === "bottom" ? arrowRoom : 0 }}
    >
      <VisualEffect material="popover" cornerRadius={PANEL.radius} style={StyleSheet.absoluteFill} />
      <View style={{ ...StyleSheet.absoluteFillObject, borderRadius: PANEL.radius, backgroundColor: tint }} />
    </Surface>
  );
}

function TextButton({ title, onPress }: { title: string; onPress: () => void }) {
  const theme = useTheme();
  const { hovered, hoverProps } = useHover();
  return (
    <View {...hoverProps}>
      <Pressable onPress={onPress}>
        <View style={{ height: 22, paddingHorizontal: TEXT_BUTTON_PAD, borderRadius: 6, justifyContent: "center", backgroundColor: hovered ? theme.toolbarHover : undefined }}>
          <Text style={{ fontSize: 12, color: theme.textSecondary }}>{title}</Text>
        </View>
      </Pressable>
    </View>
  );
}

function FooterButton({ title, onPress }: { title: string; onPress: () => void }) {
  const theme = useTheme();
  const { hovered, hoverProps } = useHover();
  return (
    <View {...hoverProps} style={{ paddingHorizontal: PANEL.rowInset }}>
      <Pressable onPress={onPress}>
        {({ pressed }) => (
          <View
            style={{
              height: PANEL.rowHeight,
              paddingHorizontal: PANEL.rowPadding,
              borderRadius: PANEL.rowRadius,
              flexDirection: "row",
              alignItems: "center",
              backgroundColor: rowFill(theme.dark, hovered, pressed),
            }}
          >
            <Text style={{ flex: 1, fontSize: PANEL.titleSize, color: hovered ? theme.textPrimary : theme.textSecondary }}>{title}</Text>
            <Symbol name="chevron.right" size={9} weight="semibold" color={theme.textTertiary} style={{ width: 12, height: 12, marginRight: -CHEVRON_BEARING }} />
          </View>
        )}
      </Pressable>
    </View>
  );
}

function RowButton({ icon, onPress, tooltip }: { icon: string; onPress: () => void; tooltip: string }) {
  return <IconButton icon={icon} size={PANEL.iconSize} box={ROW_BUTTON} radius={6} onPress={onPress} tooltip={tooltip} />;
}

const DownloadRowItem = memo(function DownloadRowItem({ id, windowId }: { id: string; windowId: string }) {
  const live = useBrowser((s) => s.downloads.find((x) => x.id === id));
  const last = useRef(live);
  if (live) last.current = live;
  return last.current ? <DownloadRow d={last.current} windowId={windowId} /> : null;
});

function DownloadRow({ d, windowId }: { d: Download; windowId: string }) {
  const theme = useTheme();
  const { hovered, hoverProps } = useHover();
  const exists = d.state !== "finished" || fileExists(d.path);
  const shown = useRef(exists);
  shown.current = exists;
  const [, recheck] = useState(0);
  const finishedPath = d.state === "finished" ? d.path : null;
  useEffect(() => {
    if (finishedPath === null) return;
    const check = () => {
      if (fileExists(finishedPath) !== shown.current) recheck((n) => n + 1);
    };
    check();
    return useBrowser.subscribe((s, prev) => {
      if (s.downloads !== prev.downloads) check();
    });
  }, [finishedPath]);
  const progress = d.total > 0 ? d.received / d.total : 0;
  const done = d.state === "finished" && exists;
  const blocked = awaitsKeep(d);
  return (
    <View {...hoverProps}>
      <MouseArea path={done ? d.path : null}>
        <ContextMenuArea onContextMenu={() => void downloadMenu(d, windowId)}>
          <Pressable onPress={() => done && void openFile(d.path)}>
            {({ pressed }) => (
              <View
                style={{
                  flexDirection: "row",
                  alignItems: "center",
                  gap: PANEL.iconGap,
                  paddingHorizontal: PANEL.rowPadding,
                  height: ROW,
                  borderRadius: PANEL.rowRadius,
                  backgroundColor: rowFill(theme.dark, hovered, pressed && done),
                }}
              >
                <View style={{ opacity: exists ? 1 : 0.45 }}>
                  <FileIcon path={d.path || d.filename} size={FILE_ICON} />
                </View>
                <View style={{ flex: 1 }}>
                  <Text
                    numberOfLines={1}
                    style={{
                      fontSize: PANEL.titleSize,
                      lineHeight: PANEL.titleLine,
                      color: exists ? theme.textPrimary : theme.textSecondary,
                      textDecorationLine: exists ? "none" : "line-through",
                    }}
                  >
                    {d.filename || "Preparing…"}
                  </Text>
                  {d.state === "downloading" && !blocked ? (
                    <View style={{ height: 3, borderRadius: 1.5, marginTop: 3, marginBottom: 2, backgroundColor: progressTrack(theme.dark) }}>
                      <View
                        style={{ width: `${Math.max(progress, 0.03) * 100}%`, height: 3, borderRadius: 1.5, backgroundColor: d.paused ? theme.textTertiary : theme.accent }}
                      />
                    </View>
                  ) : null}
                  <Text numberOfLines={1} style={{ fontSize: PANEL.subtitleSize, lineHeight: PANEL.subtitleLine, color: blocked ? dangerColor(!!theme.dark) : theme.textSecondary }}>
                    {blocked ? dangerWarning(d, true) : downloadStatus(d, exists)}
                  </Text>
                </View>
                {blocked ? (
                  <View style={{ flexDirection: "row", marginRight: -TEXT_BUTTON_PAD }}>
                    <TextButton title="Keep" onPress={() => void keepDownload(d.id)} />
                    <TextButton title="Discard" onPress={() => void cancelDownload(d.id)} />
                  </View>
                ) : d.state === "downloading" ? (
                  <View style={{ flexDirection: "row", marginRight: -ROW_BUTTON_BEARING }}>
                    <RowButton
                      icon={d.paused ? "play.circle.fill" : "pause.circle.fill"}
                      onPress={() => void (d.paused ? resumeDownload(d.id) : pauseDownload(d.id))}
                      tooltip={d.paused ? "Resume" : "Pause"}
                    />
                    <RowButton icon="xmark.circle.fill" onPress={() => void cancelDownload(d.id)} tooltip="Cancel" />
                  </View>
                ) : done ? (
                  <HoverSlot
                    hovered={hovered}
                    width={ROW_BUTTON}
                    style={{ marginRight: -ROW_BUTTON_BEARING }}
                    hover={<RowButton icon="magnifyingglass.circle.fill" onPress={() => void revealFile(d.path)} tooltip="Show in Finder" />}
                  />
                ) : null}
              </View>
            )}
          </Pressable>
        </ContextMenuArea>
      </MouseArea>
    </View>
  );
}

export function DownloadMagnet() {
  const windowId = useWindowId();
  const sidebarOpen = useSidebarOpen();
  const sidebarWidth = useSidebarWidth(windowId);
  const topStrip = useTabLayout() === "top";
  const addressBar = useAddressBarInSidebar();
  const iconsOnly = useBrowser((s) => sidebarWidthOf(s.settings, nativeSidebarShell(windowId)) === SIDEBAR_RAIL_WIDTH);
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
