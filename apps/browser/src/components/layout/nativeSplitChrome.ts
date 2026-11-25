import { useUrlEdit } from "../site/developerMode";
import { publishSettingsTopic, windowNativeLayout, windowPagesPoolActive, type ToolbarClick } from "@solara/settings";
import { useEffect, type RefObject } from "react";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import type { Theme } from "../../lib/theme";
import { hideToast, useToasts } from "./splitActions";
import type { Rect } from "./geometry";

const VERSION = 1;
export const nativeSplitPanes = windowPagesPoolActive();
const themes: Record<string, object> = {};
const pageTops: Record<string, Record<string, number>> = {};
let themeQueued = false;
let toastsStarted = false;
const actions = new Map<string, () => void>();

function publishThemes() {
  if (themeQueued) return;
  themeQueued = true;
  queueMicrotask(() => {
    themeQueued = false;
    const windows: Record<string, object> = {};
    for (const [windowId, entry] of Object.entries(themes)) {
      if (windowNativeLayout(windowId)) {
        const { theme } = entry as { theme: object };
        windows[windowId] = { theme };
      } else windows[windowId] = { ...entry, pageTops: pageTops[windowId] ?? {} };
    }
    publishSettingsTopic("split.theme", { v: VERSION, windows });
  });
}

export function useNativeSplitChrome(windowId: string, shell: boolean, theme: Theme, fullscreenTab: string | null, peek: boolean, toolbar: boolean, small: boolean) {
  const { dark, accent, textPrimary, textSecondary, textTertiary, icon, toolbarHover, toolbarPressed, urlPill, rowHover, rowSelected, placeholder, selection, ntpBarBorder, card } = theme;
  useEffect(() => {
    if (!shell) return;
    startToasts();
    const tokens = { accent, textPrimary, textSecondary, textTertiary, icon, toolbarHover, toolbarPressed, urlPill, rowHover, rowSelected, placeholder, selection, ntpBarBorder, card };
    themes[windowId] = { theme: { dark, ...tokens }, fullscreenTab, covered: peek, toolbar, small };
    publishThemes();
  }, [shell, windowId, dark, accent, textPrimary, textSecondary, textTertiary, icon, toolbarHover, toolbarPressed, urlPill, rowHover, rowSelected, placeholder, selection, ntpBarBorder, card, fullscreenTab, peek, toolbar, small]);
  useEffect(
    () => () => {
      if (!shell) return;
      delete themes[windowId];
      publishThemes();
    },
    [shell, windowId],
  );
}

export function useNativePageTops(windowId: string, shell: boolean, tops: Record<string, number>) {
  const key = JSON.stringify(tops);
  useEffect(() => {
    if (!shell || windowNativeLayout(windowId)) return;
    pageTops[windowId] = JSON.parse(key);
    publishThemes();
  }, [shell, windowId, key]);
  useEffect(
    () => () => {
      delete pageTops[windowId];
    },
    [windowId],
  );
}

function startToasts() {
  if (toastsStarted) return;
  toastsStarted = true;
  const publish = (toasts: ReturnType<typeof useToasts.getState>["toasts"]) => {
    const windows: Record<string, object> = {};
    actions.clear();
    for (const [windowId, toast] of Object.entries(toasts)) {
      if (!toast) continue;
      if (toast.action) actions.set(`${windowId}:${toast.id}`, toast.action.run);
      windows[windowId] = { id: toast.id, title: toast.title, message: toast.message ?? null, icon: toast.icon ?? null, action: toast.action?.title ?? null, sticky: !!toast.sticky };
    }
    publishSettingsTopic("split.toast", { v: VERSION, windows });
  };
  const publishNotices = (notices: ReturnType<typeof useToasts.getState>["notices"]) => {
    const windows: Record<string, object> = {};
    for (const [windowId, notice] of Object.entries(notices)) {
      if (notice) windows[windowId] = { id: notice.id, title: notice.title, message: notice.message, icon: notice.icon ?? null, action: null, sticky: true };
    }
    publishSettingsTopic("split.notice", { v: VERSION, windows });
  };
  useToasts.subscribe((s, prev) => {
    if (s.toasts !== prev.toasts) publish(s.toasts);
    if (s.notices !== prev.notices) publishNotices(s.notices);
  });
  publish(useToasts.getState().toasts);
  publishNotices(useToasts.getState().notices);
}

export type SplitToolbarHandlers = { onClick: (c: ToolbarClick) => Promise<unknown> | unknown; onAnchors: (anchors: Record<string, [number, number, number, number]>) => void };

const toolbars: Record<string, Record<string, string>> = {};
const toolbarHandlers = new Map<string, RefObject<SplitToolbarHandlers>>();
let toolbarsQueued = false;

function publishToolbars() {
  if (toolbarsQueued) return;
  toolbarsQueued = true;
  queueMicrotask(() => {
    toolbarsQueued = false;
    publishSettingsTopic("split.toolbar", { v: VERSION, windows: toolbars });
  });
}

export function feedSplitToolbar(windowId: string, tabId: string, json: string | null, handlers: RefObject<SplitToolbarHandlers>) {
  toolbarHandlers.set(`${windowId}:${tabId}`, handlers);
  const panes = (toolbars[windowId] ??= {});
  if (json === null) delete panes[tabId];
  else panes[tabId] = json;
  publishToolbars();
}

export function dropSplitToolbar(windowId: string, tabId: string, handlers: RefObject<SplitToolbarHandlers>) {
  if (toolbarHandlers.get(`${windowId}:${tabId}`) !== handlers) return;
  toolbarHandlers.delete(`${windowId}:${tabId}`);
  const panes = toolbars[windowId];
  if (!panes) return;
  delete panes[tabId];
  if (Object.keys(panes).length === 0) delete toolbars[windowId];
  publishToolbars();
}

addNativeSettingsHandlers({
  "toolbar.presentURL": (tabId: string, request: number) => useUrlEdit.setState({ tabId, request }),
  "split.toolbarClick": (windowId: string, tabId: string, click: ToolbarClick) => {
    void toolbarHandlers.get(`${windowId}:${tabId}`)?.current?.onClick(click);
  },
  "split.toolbarAnchors": (windowId: string, tabId: string, anchors: Record<string, [number, number, number, number]>) => {
    toolbarHandlers.get(`${windowId}:${tabId}`)?.current?.onAnchors(anchors);
  },
  "split.toast": (windowId: string, id: number, event: string) => {
    if (event === "action") actions.get(`${windowId}:${id}`)?.();
    hideToast(windowId, id);
  },
  "split.devResult": (run: number, json: string) => {
    const g = globalThis as { __splitDev?: Record<number, object> };
    (g.__splitDev ??= {})[run] = JSON.parse(json);
  },
});

export type NativeDropFrame = { shown: boolean; grown: boolean; px: number; target: { tabId: string; side: string } | null; panes: [string, Rect][] };

let lastDrop = "";

export function publishNativeDrop(windowId: string, frame: NativeDropFrame) {
  if (windowNativeLayout(windowId)) return;
  const message = {
    v: VERSION,
    windowId,
    shown: frame.shown,
    grown: frame.grown,
    px: frame.px,
    target: frame.target ? [frame.target.tabId, frame.target.side] : null,
    panes: frame.panes.map(([tabId, r]) => [tabId, r.x, r.y, r.width, r.height]),
  };
  const key = JSON.stringify(message);
  if (key === lastDrop) return;
  lastDrop = key;
  publishSettingsTopic("split.drag", message);
}
