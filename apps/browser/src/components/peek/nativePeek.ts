import { breadcrumb } from "@solara/core";
import { hex, type Theme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { MAX_SPLIT_PANES, splitOf } from "../../store/splits";
import { pageOf } from "../layout/pageState";
import { toolbarPalette } from "../layout/toolbarColors";
import { insecureLevel } from "../Toolbar";
import { dismissPeek, finishPeek, openPeekAsTab, openPeekInSplit, registerPeekMotion } from "./actions";

export type NativePeekEvent = { kind: "dismiss" | "openAsTab" | "openInSplit"; tabId?: string } | { kind: "closed"; tabId: string };

export type NativePeekControl = { close(): void; expand(done: () => void): void };

export function nativePeekState(
  windowId: string,
  theme: Theme,
  card: { x: number; y: number },
  fullscreen: boolean,
  reduceMotion: boolean,
  loading: number | null,
): string {
  const s = useBrowser.getState();
  const peek = s.peeks[windowId];
  const tab = peek ? s.tabs[peek.tabId] : undefined;
  if (!peek || !tab) return "";
  const host = tab.url ? breadcrumb(tab.url).host : "";
  const palette = toolbarPalette(theme, null);
  return JSON.stringify({
    tabId: peek.tabId,
    dark: !!theme.dark,
    host,
    title: tab.customTitle || tab.title || "",
    favicon: tab.favicon ?? null,
    insecure: !!insecureLevel(pageOf(peek.tabId)),
    loading,
    splitFull: (splitOf(s, peek.sourceId)?.tabIds.length ?? 0) >= MAX_SPLIT_PANES,
    fullscreen,
    from: peek.from ? { x: peek.from.x - card.x, y: peek.from.y - card.y } : null,
    reduceMotion,
    palette,
    panel: hex(theme.panel),
    card: hex(theme.card),
    accent: hex(theme.accent),
  });
}

export function onNativePeekEvent(windowId: string, event: NativePeekEvent) {
  if (event.tabId && useBrowser.getState().peeks[windowId]?.tabId !== event.tabId) return;
  if (event.kind === "closed") return finishPeek(windowId, event.tabId);
  if (event.kind === "dismiss") return dismissPeek(windowId);
  if (event.kind === "openAsTab") return openPeekAsTab(windowId);
  openPeekInSplit(windowId);
}

export function registerNativePeek(windowId: string, control: NativePeekControl) {
  return registerPeekMotion(windowId, () => control.close(), (done) => control.expand(done));
}
