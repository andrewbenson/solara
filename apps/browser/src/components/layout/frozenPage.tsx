import { onHostedEvent, SolaraHostedView } from "@solara/settings";
import { useEffect, useLayoutEffect, useRef } from "react";
import { StyleSheet } from "react-native";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { notePainted, startPinHandoff, useFrozenPages } from "./pinHandoff";

let receipts = 0;

type Presentation = {
  token: number;
  windowId: string;
  tabId: string | undefined;
  frozen: boolean;
  copyId: string;
  uri: string | null;
  pass: { copyId: string; uri: string } | undefined;
};

export function FrozenPage({ windowId, tabId, top }: { windowId: string; tabId: string | undefined; top: number }) {
  const theme = useTheme();
  useEffect(startPinHandoff, []);
  const frozen = useBrowser((s) => !!tabId && !!s.tabs[tabId]?.pageIn);
  const pass = useFrozenPages((f) => f.bridges[windowId]);
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
      if (bridge !== shown.pass || (now.frames[shown.copyId] ?? bridge?.uri ?? null) !== shown.uri) return;
      const tab = shown.tabId ? useBrowser.getState().tabs[shown.tabId] : undefined;
      if (shown.frozen && (!tab?.pageIn || tab.windowId !== windowId)) return;
      if (name === "painted" && shown.uri) notePainted(windowId);
      if (name === "press" && shown.frozen && shown.tabId) useBrowser.getState().activate(shown.tabId);
    });
    return () => {
      if (current.current?.windowId === windowId) current.current = null;
      off();
    };
  }, [windowId]);
  const shown = current.current;
  if (!shown) return null;
  const state = JSON.stringify({ token: shown.token, tabId, copyId: shown.copyId, uri, dark: !!theme.dark });
  return <SolaraHostedView kind="frozenPage" windowId={windowId} state={state} style={[StyleSheet.absoluteFill, { top }]} />;
}
