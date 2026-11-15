import { onHostedEvent, publishSettingsTopic, SolaraHostedView, windowNativeLayoutGeneration } from "@solara/settings";
import { useEffect, useLayoutEffect, useMemo, useRef } from "react";
import { StyleSheet } from "react-native";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { holderOf } from "../../store/pinShare";
import { notePainted, startPinHandoff, useFrozenPages } from "./pinHandoff";
import { NativeLayoutFeed, nativePaneWindows, useNativeLayoutFeed, type NativePanePresentation } from "./nativeLayoutFeed";

let receipts = 0;
let frozenWindows: ReturnType<typeof nativePaneWindows<object>> = {};
const frozenFeed = new NativeLayoutFeed<NativePanePresentation<object>>((entries) => {
  const windows = nativePaneWindows(entries, frozenWindows);
  frozenWindows = Object.fromEntries(Object.entries(windows).filter(([id, entry]) => windowNativeLayoutGeneration(id) === entry.generation));
  publishSettingsTopic("split.frozen", { v: 1, windows: frozenWindows });
});

type Presentation = {
  token: number;
  windowId: string;
  tabId: string | undefined;
  frozen: boolean;
  copyId: string;
  uri: string | null;
  pass: { copyId: string; uri: string } | undefined;
};

export function FrozenPage({ windowId, tabId, top = 0, headless = false }: { windowId: string; tabId: string | undefined; top?: number; headless?: boolean }) {
  const theme = useTheme();
  useEffect(startPinHandoff, []);
  const frozen = useBrowser((s) => !!tabId && !!s.tabs[tabId]?.pageIn);
  const bridge = useFrozenPages((f) => f.bridges[windowId]);
  const bridgeHere = useBrowser((state) => !headless || !bridge || holderOf(state, bridge.copyId)?.id === tabId);
  const pass = bridgeHere ? bridge : undefined;
  const copyId = frozen ? tabId : pass?.copyId;
  const uri = useFrozenPages((f) => (copyId ? f.frames[copyId] : undefined)) ?? pass?.uri ?? null;
  const current = useRef<Presentation | null>(null);
  if ((!frozen && !pass) || !copyId) current.current = null;
  else if (!current.current || current.current.copyId !== copyId || current.current.uri !== uri || current.current.pass !== pass || current.current.tabId !== tabId || current.current.frozen !== frozen || current.current.windowId !== windowId) {
    current.current = { token: ++receipts, windowId, tabId, frozen, copyId, uri, pass };
  }
  useLayoutEffect(() => {
    const off = onHostedEvent("frozenPage", windowId, (name, payload) => {
      const shown = current.current;
      if (!shown || shown.windowId !== windowId || payload.token !== shown.token || payload.copyId !== shown.copyId) return;
      const now = useFrozenPages.getState();
      const bridge = now.bridges[windowId];
      if ((!headless || shown.pass) && bridge !== shown.pass) return;
      if ((now.frames[shown.copyId] ?? shown.pass?.uri ?? null) !== shown.uri) return;
      const tab = shown.tabId ? useBrowser.getState().tabs[shown.tabId] : undefined;
      if (shown.frozen && (!tab?.pageIn || tab.windowId !== windowId)) return;
      if (name === "painted" && shown.uri && (!headless || shown.pass)) notePainted(windowId);
      if (name === "press" && shown.frozen && shown.tabId) useBrowser.getState().activate(shown.tabId);
    });
    return () => {
      if (current.current?.windowId === windowId) current.current = null;
      off();
    };
  }, [windowId]);
  const shown = current.current;
  const state = shown ? JSON.stringify({ token: shown.token, tabId, copyId: shown.copyId, uri, dark: !!theme.dark }) : null;
  if (headless) return <FrozenPageFeed windowId={windowId} tabId={tabId ?? ""} state={state} />;
  if (!state) return null;
  return <SolaraHostedView kind="frozenPage" windowId={windowId} state={state} style={[StyleSheet.absoluteFill, { top }]} />;
}

function FrozenPageFeed({ windowId, tabId, state }: { windowId: string; tabId: string; state: string | null }) {
  const value = useMemo(() => ({ windowId, tabId, presentation: state ? JSON.parse(state) as object : null }), [windowId, tabId, state]);
  useNativeLayoutFeed(frozenFeed, windowId, value, JSON.stringify([windowId, tabId]));
  return null;
}
