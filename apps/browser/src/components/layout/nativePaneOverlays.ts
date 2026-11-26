import { resolveExternalApp, type AutofillPromptAnswer, type PasswordPromptAnswer, type PermissionResult } from "@solara/solaracore";
import { publishSettingsTopic } from "@solara/settings";
import { useCallback, useEffect, useRef, useState } from "react";
import type { View } from "react-native";
import { webviews } from "../../lib/webviews";
import type { Theme } from "../../lib/theme";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { pageOf, patchPage, usePage } from "./pageState";
import { answerBlockedPopups, openOneBlockedPopup, type BlockedPopupsAnswer } from "../site/Prompts";
import { answerPermission } from "../site/permissions";
import { cliCommand, cliProduct, useCliIndicator } from "../../lib/cliControl";
import { mediaTheme } from "../media/nativeMedia";
import { acceptEngineOffer, stayOnPage } from "../../lib/engines";

const VERSION = 1;
const passwordPromptKey = (prompt: { origin: string; username: string; state: string }) => `${prompt.origin}|${prompt.username}|${prompt.state === "update" ? "update" : "save"}`;
export type PaneHistoryEvent = { kind: "open"; index: number; metaKey: boolean; shiftKey: boolean; altKey: boolean; middle: boolean } | { kind: "fullHistory" | "dismiss" };
export type PaneClick = { metaKey: boolean; shiftKey: boolean; altKey: boolean };
const handlers = new Map<string, { current: ((event: never) => void) | null }>();
const windows: Record<string, Record<string, Record<string, object>>> = {};
let queued = false;

function publish() {
  if (queued) return;
  queued = true;
  queueMicrotask(() => {
    queued = false;
    publishSettingsTopic("pane.overlays", { v: VERSION, windows });
  });
}

function setOverlay(windowId: string, tabId: string, kind: string, state: object | null) {
  const tabs = (windows[windowId] ??= {});
  const entry = (tabs[tabId] ??= {});
  if (state) entry[kind] = state;
  else delete entry[kind];
  if (!Object.keys(entry).length) delete tabs[tabId];
  if (!Object.keys(tabs).length) delete windows[windowId];
  publish();
}

addNativeSettingsHandlers({
  "pane.sadTab": (_windowId: string, tabId: string, action: string) => {
    if (action === "reload") {
      patchPage(tabId, { crashed: null });
      return void webviews.get(tabId)?.reload();
    }
    if (action === "exit" || action === "wait") {
      patchPage(tabId, { unresponsive: false });
      return void webviews.get(tabId)?.resolveUnresponsive(action === "exit");
    }
  },
  "pane.history": (windowId: string, tabId: string, event: PaneHistoryEvent) => handlers.get(`history:${windowId}:${tabId}`)?.current?.(event as never),
  "pane.password": (_windowId: string, tabId: string, action: PasswordPromptAnswer, username: string, key?: string) => {
    const shown = pageOf(tabId).passwordPrompt;
    if (shown && key !== undefined && passwordPromptKey(shown) !== key) return;
    patchPage(tabId, { passwordPrompt: null });
    void webviews.get(tabId)?.resolvePasswordPrompt(action, action === "save" || action === "update" ? { username } : undefined);
  },
  "pane.autofill": (_windowId: string, tabId: string, id: number, action: AutofillPromptAnswer) => {
    if (pageOf(tabId).autofillPrompt?.id === id) patchPage(tabId, { autofillPrompt: null });
    void webviews.get(tabId)?.resolveAutofillPrompt(id, action);
  },
  "pane.externalApp": (_windowId: string, tabId: string, id: string, open: boolean, remember: boolean) => {
    if (pageOf(tabId).externalApp?.id === id) patchPage(tabId, { externalApp: null });
    void resolveExternalApp(id, open, remember);
  },
  "pane.engineOffer": (_windowId: string, tabId: string, action: string, remember: boolean) => {
    if (action === "webkit") void acceptEngineOffer(tabId);
    else stayOnPage(tabId, action === "stay" && remember);
  },
  "pane.permission": (_windowId: string, tabId: string, id: string, result: PermissionResult) => answerPermission(tabId, id, result),
  "pane.popups": (_windowId: string, tabId: string, action: string, id: string) => {
    if (action === "row") openOneBlockedPopup(tabId, id);
    else answerBlockedPopups(tabId, action as BlockedPopupsAnswer);
  },
});

export function useNativePaneHandler<Event>(kind: "history" | "selection", active: boolean, windowId: string, tabId: string, handler: (event: Event) => void) {
  const ref = useRef(handler);
  ref.current = handler;
  useEffect(() => {
    if (!active) return;
    const key = `${kind}:${windowId}:${tabId}`;
    const entry = ref as { current: ((event: never) => void) | null };
    handlers.set(key, entry);
    return () => void (handlers.get(key) === entry && handlers.delete(key));
  }, [kind, active, windowId, tabId]);
}

export function usePageFrame() {
  const [frame, setFrame] = useState<PageFrame | null>(null);
  const ref = useRef<View>(null);
  const onLayout = useCallback(
    () => ref.current?.measureInWindow((x, y, width, height) => setFrame((f) => (f && f.join() === [x, y, width, height].join() ? f : [x, y, width, height]))),
    [],
  );
  return { frame, ref, onLayout };
}

type OverlayClaim = { state: object | null };
const overlayClaims: Record<string, OverlayClaim[]> = {};
const overlaySlot = (windowId: string, tabId: string, kind: string) => `${windowId}|${tabId}|${kind}`;

export function useNativePaneOverlay(active: boolean, windowId: string, tabId: string, kind: string, state: object | null) {
  const key = state && JSON.stringify(state);
  const claim = useRef<OverlayClaim>({ state: null }).current;
  useEffect(() => {
    if (!active) return;
    claim.state = state;
    const claims = (overlayClaims[overlaySlot(windowId, tabId, kind)] ??= []);
    if (!claims.includes(claim)) claims.push(claim);
    if (claims.at(-1) === claim) setOverlay(windowId, tabId, kind, state);
  }, [active, windowId, tabId, kind, key]);
  useEffect(() => {
    if (!active) return;
    const slot = overlaySlot(windowId, tabId, kind);
    return () => {
      const left = (overlayClaims[slot] ?? []).filter((c) => c !== claim);
      if (left.length) overlayClaims[slot] = left;
      else delete overlayClaims[slot];
      setOverlay(windowId, tabId, kind, left.at(-1)?.state ?? null);
    };
  }, [active, windowId, tabId, kind]);
}

export type PageFrame = [number, number, number, number];

const promptWindows: Record<string, { theme?: object; panes: Record<string, Record<string, unknown>> }> = {};

function setPaneHint(windowId: string, tabId: string, hint: Record<string, unknown>) {
  const panes = (promptWindows[windowId] ??= { panes: {} }).panes;
  panes[tabId] = { ...panes[tabId], ...hint };
  publishPrompts();
}
let promptsQueued = false;

function publishPrompts() {
  if (promptsQueued) return;
  promptsQueued = true;
  queueMicrotask(() => {
    promptsQueued = false;
    publishSettingsTopic("pane.prompts", { v: VERSION, windows: promptWindows });
  });
}

export function useNativePanePromptsTheme(active: boolean, windowId: string, theme: Theme, form: { accent: string; control: string; controlBorder: string }) {
  const { dark, textPrimary, textSecondary, panel, panelBorder, panelShadowOpacity, goButton, goButtonText, toolbarHover, rowHover, icon } = theme;
  const prompt = {
    dark: !!dark,
    theme: { textPrimary, textSecondary, toolbarHover, rowHover, icon, accent: form.accent },
    control: form.control,
    controlBorder: form.controlBorder,
    goButton,
    goButtonText,
  };
  const cliShown = useCliIndicator((s) => s.shown);
  const cli = { shown: cliShown, command: cliCommand(), product: cliProduct(), theme: mediaTheme(theme) };
  const key = JSON.stringify({ dark, textPrimary, textSecondary, icon, panel, panelBorder, panelShadowOpacity, goButton, goButtonText, prompt, cli });
  useEffect(() => {
    if (!active) return;
    (promptWindows[windowId] ??= { panes: {} }).theme = JSON.parse(key);
    publishPrompts();
  }, [active, windowId, key]);
  useEffect(
    () => () => {
      if (!active) return;
      delete promptWindows[windowId];
      publishPrompts();
    },
    [active, windowId],
  );
}

export function useNativePanePromptsPane(active: boolean, windowId: string, tabId: string, urlLeft: number, newTabShown: boolean) {
  useEffect(() => {
    if (!active) return;
    setPaneHint(windowId, tabId, { urlLeft, newTabShown });
  }, [active, windowId, tabId, urlLeft, newTabShown]);
  useEffect(
    () => () => {
      if (!active || !promptWindows[windowId]) return;
      delete promptWindows[windowId].panes[tabId];
      publishPrompts();
    },
    [active, windowId, tabId],
  );
}

export function useNativePaneHint(active: boolean, windowId: string, tabId: string, hint: Record<string, unknown>) {
  const key = JSON.stringify(hint);
  useEffect(() => {
    if (active) setPaneHint(windowId, tabId, JSON.parse(key));
  }, [active, windowId, tabId, key]);
}

export function useNativePanePopups(active: boolean, windowId: string, tabId: string, open: boolean, side: "left" | "right") {
  const popups = usePage(tabId, (p) => p.popups);
  const key = active && open && popups.length ? JSON.stringify({ side, list: popups.map(({ id, url, origin }) => ({ id, url, origin })) }) : "";
  useEffect(() => {
    if (!active) return;
    setPaneHint(windowId, tabId, { popups: key ? JSON.parse(key) : null });
  }, [active, windowId, tabId, key]);
}

export function useNativeSadTab(active: boolean, windowId: string, tabId: string, mode: "crashed" | "unresponsive" | null, frame: PageFrame | null, theme: Theme) {
  const { dark, textPrimary, textSecondary, panel, panelBorder, panelShadowOpacity, goButton, goButtonText } = theme;
  useNativePaneOverlay(active, windowId, tabId, "sadTab", mode && frame ? { mode, frame, dark, textPrimary, textSecondary, panel, panelBorder, panelShadowOpacity, goButton, goButtonText } : null);
}
