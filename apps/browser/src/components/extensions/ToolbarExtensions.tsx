import { terminateCastRoute, type ActionState, type CastRoute } from "@solara/solaracore";
import { showMenu } from "@solara/shell";
import { useEffect, useMemo, useRef, useState } from "react";
import { View } from "react-native";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { toggleCastPicker, useCastRoutes } from "../media/cast";
import { usePages } from "../layout/pageState";
import { dropToolbarAnchor, setToolbarAnchor } from "./bridge";
import {
  activateExtension,
  openManageExtensions,
  openPinDialog,
  openWebStore,
  showExtensionMenu,
  useExtensions,
  useWindowExtensions,
  windowExtensions,
  type Anchor,
} from "./state";

const BUTTON = 28;
const GAP = 2;
const PITCH = BUTTON + GAP;

function useToolbarExtensions(windowId: string, limit: number) {
  const shown = useWindowExtensions(windowId);
  const routes = useCastRoutes(windowId);
  const casting = routes.length > 0;
  return useMemo(() => {
    const all = shown.filter((x) => x.pinned);
    const room = Math.max(0, limit - (casting ? 1 : 0));
    const overflow = all.length > room;
    return { pinned: overflow ? all.slice(0, Math.max(0, room - 1)) : all, overflow, casting, routes };
  }, [shown, routes, casting, limit]);
}

export const extensionsFitting = (room: number) => Math.max(1, Math.floor((room + GAP) / PITCH));

export function useToolbarExtensionsWidth(windowId: string, limit = Infinity): number {
  const { pinned, overflow, casting } = useToolbarExtensions(windowId, limit);
  const count = pinned.length + (overflow ? 1 : 0) + (casting ? 1 : 0);
  return count ? count * PITCH - GAP + 6 : 0;
}

export type NativeExtensionButton = {
  id: string;
  anchor?: string;
  icon: string;
  size: number;
  box: number;
  radius: number;
  color?: string;
  image?: string | null;
  imageSize?: number;
  dimmed?: boolean;
  badge?: { text: string; color: string; textColor: string } | null;
  active?: boolean;
  menu?: boolean;
  tooltip: string;
};

export function useNativeToolbarExtensions(windowId: string, tabId: string, limit = Infinity) {
  const theme = useTheme();
  const { pinned, overflow, routes } = useToolbarExtensions(windowId, limit);
  const browserId = usePages((p) => {
    for (const [id, tab] of Object.entries(p.browsers)) if (tab === tabId) return Number(id);
    return 0;
  });
  const fetched = useExtensions((e) => (browserId ? e.actions[browserId] : undefined));
  const held = useRef<Record<string, ActionState>>({});
  if (fetched) held.current = { ...held.current, ...fetched };
  const popup = useExtensions((e) => (e.popup?.windowId === windowId ? e.popup.extensionId : null));
  const anchors = useRef(new Map<string, Anchor>());
  const owner = useRef({ windowId, tabId });
  owner.current = { windowId, tabId };
  useEffect(
    () => () => {
      for (const [slot, anchor] of anchors.current) dropToolbarAnchor(windowId, tabId, slot, anchor);
      anchors.current.clear();
    },
    [windowId, tabId],
  );
  const buttons: NativeExtensionButton[] = [];
  if (routes.length) {
    buttons.push({
      id: "ext-cast",
      icon: "tv.and.mediabox.fill",
      size: 14,
      box: BUTTON,
      radius: 7,
      color: theme.accent,
      menu: true,
      tooltip: routes.map((r) => (r.description ? `${r.description} on ${r.sink}` : `Casting to ${r.sink}`)).join("\n"),
    });
  }
  for (const ext of pinned) {
    const state = held.current[ext.id];
    const badgeText = state?.badgeText ?? "";
    const fill = state?.badgeColor && state.badgeColor !== "#000000" ? state.badgeColor : "#5F6368";
    buttons.push({
      id: `ext:${ext.id}`,
      anchor: ext.id,
      icon: "puzzlepiece.extension",
      size: 14,
      box: BUTTON,
      radius: 7,
      image: state?.icon || ext.actionIcon || ext.icon || null,
      imageSize: 16,
      dimmed: state ? !state.enabled : false,
      badge: badgeText ? { text: badgeText, color: fill, textColor: state?.badgeTextColor ?? contrastText(fill) } : null,
      active: popup === ext.id,
      menu: true,
      tooltip: state?.title || ext.actionTitle || ext.name,
    });
  }
  if (overflow) buttons.push({ id: "ext-overflow", anchor: "*", icon: "puzzlepiece.extension", size: 14, box: BUTTON, radius: 7, tooltip: "Extensions" });
  const onAnchors = (next: Record<string, [number, number, number, number]>) => {
    const { windowId: w, tabId: t } = owner.current;
    for (const [slot, anchor] of anchors.current) if (!next[slot]) dropToolbarAnchor(w, t, slot, anchor);
    const kept = new Map<string, Anchor>();
    for (const [slot, [x, y, width, height]] of Object.entries(next)) {
      const anchor = { x, y, width, height };
      kept.set(slot, anchor);
      setToolbarAnchor(w, t, slot, anchor);
    }
    anchors.current = kept;
  };
  const anchorOf = (slot: string) => anchors.current.get(slot) ?? { x: 0, y: 0, width: BUTTON, height: BUTTON };
  const onClick = (id: string, kind: "press" | "menu") => {
    if (id === "ext-cast") {
      if (kind === "menu") return void castMenu(windowId, routes);
      return void toggleCastPicker(windowId, tabId);
    }
    if (id === "ext-overflow") return void overflowMenu(windowId, tabId, anchorOf("*"));
    const ext = pinned.find((x) => `ext:${x.id}` === id);
    if (!ext) return false;
    if (kind === "menu") return void showExtensionMenu(windowId, ext);
    void activateExtension(windowId, ext, anchorOf(ext.id), fetched?.[ext.id], tabId);
  };
  return { buttons, onAnchors, onClick };
}

export function ToolbarPopupAnchor(props: { windowId: string; tabId: string; top: number; right: number }) {
  return <EmptyAnchor key={`${props.windowId}|${props.tabId}`} {...props} />;
}

function EmptyAnchor({ windowId, tabId, top, right }: { windowId: string; tabId: string; top: number; right: number }) {
  const { ref, measure } = useAnchor(windowId, tabId, "*");
  return <View ref={ref} pointerEvents="none" style={{ position: "absolute", top, right, width: BUTTON, height: BUTTON }} onLayout={() => void measure()} />;
}

function useAnchor(windowId: string, tabId: string, slot: string) {
  const ref = useRef<View>(null);
  const [owner] = useState(() => ({ windowId, tabId, slot }));
  const mine = useRef<Anchor | null>(null);
  useEffect(
    () => () => {
      if (mine.current) dropToolbarAnchor(owner.windowId, owner.tabId, owner.slot, mine.current);
      mine.current = null;
    },
    [owner],
  );
  const measure = () =>
    new Promise<Anchor>((resolve) => {
      const view = ref.current;
      if (!view) return resolve({ x: 0, y: 0, width: BUTTON, height: BUTTON });
      view.measureInWindow((x, y, width, height) => {
        const anchor = { x, y, width, height };
        if (ref.current) {
          mine.current = anchor;
          setToolbarAnchor(owner.windowId, owner.tabId, owner.slot, anchor);
        }
        resolve(anchor);
      });
    });
  return { ref, measure };
}

function contrastText(hex: string) {
  const n = parseInt(hex.slice(1, 7), 16);
  const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  return 0.299 * r + 0.587 * g + 0.114 * b > 160 ? "#000000" : "#FFFFFF";
}

async function castMenu(windowId: string, routes: CastRoute[]) {
  const choice = await showMenu([
    ...routes.map((r) => ({ id: `stop:${r.id}`, title: `Stop Casting to ${r.sink}`, symbol: "stop.circle" })),
    { separator: true as const },
    { id: "open", title: "Cast…", symbol: "tv.and.mediabox" },
  ]);
  if (choice === "open") void toggleCastPicker(windowId);
  else if (choice?.startsWith("stop:")) void terminateCastRoute(choice.slice(5));
}

async function overflowMenu(windowId: string, tabId: string, anchor: Anchor) {
  const enabled = windowExtensions(useBrowser.getState(), windowId);
  const choice = await showMenu([
    ...enabled.map((x) => ({ id: `open:${x.id}`, title: x.name, symbol: x.pinned ? "pin.fill" : undefined })),
    ...(enabled.length ? [{ separator: true as const }] : []),
    { id: "pin", title: "Pin Extensions…", symbol: "pin" },
    { id: "manage", title: "Manage Extensions…", symbol: "puzzlepiece.extension" },
    { id: "add", title: "Add Extension…", symbol: "plus" },
  ]);
  if (choice === "pin") return openPinDialog(windowId);
  if (choice === "manage") return openManageExtensions(windowId);
  if (choice === "add") return openWebStore(windowId);
  const ext = choice?.startsWith("open:") ? enabled.find((x) => x.id === choice.slice(5)) : undefined;
  if (ext) void activateExtension(windowId, ext, anchor, undefined, tabId);
}
