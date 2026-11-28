import { displayUrl, type Suggestion } from "@solara/core";
import { onBookmarkProjectionChanged, newTabSources, type NewTabMenuChoice } from "@solara/settings";
import { pickFiles, readDocument, showMenu, startDictation } from "@solara/shell";
import { useEffect, useRef, useState, type RefObject } from "react";
import { findNodeHandle } from "react-native";
import { claimFocusTag } from "../../lib/focusClaims";
import { perfProbeEnabled } from "../../lib/perfProbe";
import type { Theme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { activeTabId, viewTabIds } from "../../store/model";
import { journeyBarCommitted, journeyBarFocused, journeyKeystroke, journeyNavigate, journeySuggestions, journeyQueryInvalidated } from "../../lib/perfMarks";
import { sampleOmniboxLatency } from "../../lib/perfMarks";
import { currentBarActions } from "./actions";
import { useOmniboxDriver } from "./devDriver";
import { runOmniboxFallback, type NativeActionOwnership } from "./nativeActions";
import { openFromBar, switchFromBar, type Disposition } from "./open";
import { clipboardPasteAction, pasteMenuItem, pasteTarget } from "./paste";
import { runBarAction, runBarExtension } from "./runBar";
import { startWorkspaceSources } from "./workspaceSources";

export { openFromBar };

const benchOffline = readDocument("bench-offline") !== null;

const PUBLISH_DELAY_MS = 50;

export function themeTokens(theme: Theme): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(theme)) if (typeof value === "string") out[key] = value;
  return out;
}

function debounced(run: () => void) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  return {
    schedule: () => {
      clearTimeout(timer);
      timer = setTimeout(run, PUBLISH_DELAY_MS);
    },
    cancel: () => clearTimeout(timer),
  };
}

export function usePublishSources(windowId: string, profileId: string) {
  useEffect(() => {
    if (!profileId) return;
    let actions = "";
    const offWorkspace = startWorkspaceSources(windowId, profileId, useBrowser, newTabSources);
    const publishActions = debounced(() => {
      const next = JSON.stringify(currentBarActions(windowId));
      if (next === actions) return;
      actions = next;
      void newTabSources.setActions(windowId, JSON.parse(next) as unknown[]);
    });
    publishActions.schedule();
    const off = useBrowser.subscribe(publishActions.schedule);
    const bookmarks = onBookmarkProjectionChanged(publishActions.schedule);
    return () => {
      off();
      offWorkspace();
      bookmarks.remove();
      publishActions.cancel();
    };
  }, [windowId, profileId]);
}

export function useThemeTokens(theme: Theme): Record<string, string> {
  const [tokens] = useState(() => new Map<Theme, Record<string, string>>());
  let found = tokens.get(theme);
  if (!found) tokens.set(theme, (found = themeTokens(theme)));
  return found;
}

export type NativeBarHandle = {
  focus(): Promise<void>;
  applyMenu(choice: NewTabMenuChoice): Promise<void>;
  type(text: string): Promise<void>;
  clear(): Promise<void>;
  key(key: string, mods?: { metaKey?: boolean; altKey?: boolean; shiftKey?: boolean; ctrlKey?: boolean }): Promise<void>;
  select(start: number, end: number): Promise<void>;
  submit(): Promise<void>;
  driverState(): Promise<string>;
  measure(): Promise<{ x: number; y: number; width: number; height: number }>;
};

type Event<T> = { nativeEvent: T & NativeActionOwnership };

export function useNativeBar({
  ref,
  windowId,
  tabId,
  profileId,
  driverId,
  focusTag,
  go,
  switchTo = (target, url, disposition) => switchFromBar(target, url, tabId, disposition),
}: {
  ref: RefObject<NativeBarHandle | null>;
  windowId: string;
  tabId: string;
  profileId: string;
  driverId: string;
  focusTag: string;
  go(url: string, disposition?: Disposition): void;
  switchTo?(tabId: string, url: string, disposition: Disposition): void;
}) {
  usePublishSources(windowId, profileId);
  const claim = () => claimFocusTag(windowId, focusTag, () => findNodeHandle(ref.current as never));

  const driverState = useRef<Record<string, unknown>>({ items: [] });
  const refreshState = () => void ref.current?.driverState().then((s) => (driverState.current = JSON.parse(s) as Record<string, unknown>), () => {});
  useOmniboxDriver(driverId, {
    type: (text) => void ref.current?.type(text).then(refreshState),
    clear: () => void ref.current?.clear().then(refreshState),
    key: (key, mods) => void ref.current?.key(key, mods).then(refreshState),
    select: (start, end) => void ref.current?.select(start, end),
    submit: () => void ref.current?.submit(),
    applyMenu: (choice) => void ref.current?.applyMenu(choice).then(refreshState),
    measure: () => ref.current?.measure() ?? Promise.resolve({ x: 0, y: 0, width: 0, height: 0 }),
    state: () => driverState.current,
  });

  const openChip = async () => {
    const s = useBrowser.getState();
    const active = activeTabId(s, windowId);
    const others = viewTabIds(s, windowId)
      .map((id) => s.tabs[id]!)
      .filter((t) => t.id !== active && t.url)
      .slice(0, 12);
    const choice = await showMenu([
      ...others.map((t) => ({ id: `tab:${t.id}`, title: t.title || displayUrl(t.url) })),
      ...(others.length ? [{ separator: true as const }] : []),
      { id: "files", title: "Open File…", symbol: "doc" },
    ]);
    if (choice?.startsWith("tab:")) switchFromBar(choice.slice(4), "", tabId, "current");
    if (choice === "files") {
      const [file] = await pickFiles();
      if (file) go(file);
    }
  };

  const contextMenu = async (hasSelection: boolean, hasValue: boolean) => {
    const paste = await clipboardPasteAction();
    const choice = await showMenu([
      ...pasteMenuItem(paste),
      ...(paste ? [{ separator: true as const }] : []),
      { id: "cut", title: "Cut", enabled: hasSelection },
      { id: "copy", title: "Copy", enabled: hasSelection },
      { id: "paste", title: "Paste", enabled: !!paste },
      { separator: true },
      { id: "selectAll", title: "Select All", enabled: hasValue },
    ]);
    if (choice === "pasteAndGo" && paste) return go(pasteTarget(paste));
    if (choice === "cut" || choice === "copy" || choice === "paste" || choice === "selectAll") void ref.current?.applyMenu(choice as NewTabMenuChoice);
    else void ref.current?.focus();
  };

  const props = {
    driven: __DEV__ || perfProbeEnabled,
    offline: benchOffline,
    onDriverState: (e: Event<{ json: string }>) => (driverState.current = JSON.parse(e.nativeEvent.json) as Record<string, unknown>),
    onOpen: (e: Event<{ url: string; disposition: Disposition }>) => runOmniboxFallback("open", e.nativeEvent, () => go(e.nativeEvent.url, e.nativeEvent.disposition)),
    onSwitch: (e: Event<{ tabId: string; url: string; disposition: Disposition }>) => runOmniboxFallback("switch", e.nativeEvent, () => switchTo(e.nativeEvent.tabId, e.nativeEvent.url, e.nativeEvent.disposition)),
    onAction: (e: Event<{ id: string }>) => runOmniboxFallback("action", e.nativeEvent, () => runBarAction(e.nativeEvent.id, windowId)),
    onExtension: (e: Event<{ suggestion: unknown }>) => runOmniboxFallback("extension", e.nativeEvent, () => runBarExtension(e.nativeEvent.suggestion as Extract<Suggestion, { kind: "extension" }>, windowId)),
    onRemoveHistory: (e: Event<{ url: string }>) => runOmniboxFallback("removeHistory", e.nativeEvent, () => useBrowser.getState().removeHistory(profileId, [e.nativeEvent.url])),
    onOpenChip: (e: Event<Record<string, unknown>>) => runOmniboxFallback("openChip", e.nativeEvent, () => void openChip()),
    onDictate: (e: Event<Record<string, unknown>>) => runOmniboxFallback("dictate", e.nativeEvent, () => startDictation()),
    onContextMenu: (e: Event<{ hasSelection: boolean; hasValue: boolean }>) => runOmniboxFallback("contextMenu", e.nativeEvent, () => void contextMenu(e.nativeEvent.hasSelection, e.nativeEvent.hasValue)),
    onJourney: (e: Event<{ mark: string; tabId?: string; query?: string; generation?: string; at?: number }>) => {
      const mark = e.nativeEvent.mark;
      if (mark === "committed") journeyBarCommitted(tabId);
      else if (mark === "focused") {
        claim();
        journeyBarFocused(tabId);
      } else if (mark === "keystroke") journeyKeystroke(e.nativeEvent.tabId ?? tabId, e.nativeEvent.query, e.nativeEvent.generation);
      else if (mark === "suggestions") journeySuggestions(e.nativeEvent.tabId ?? tabId, e.nativeEvent.query, e.nativeEvent.generation, e.nativeEvent.at);
      else if (mark === "navigate") journeyNavigate(tabId);
      else if (mark === "queryInvalidated") journeyQueryInvalidated(e.nativeEvent.tabId ?? tabId, e.nativeEvent.generation);
    },
    onLatency: (e: Event<{ ms: number; query?: string; generation?: string }>) => sampleOmniboxLatency(e.nativeEvent.ms, e.nativeEvent.query, e.nativeEvent.generation),
  };
  return { props, claim };
}
