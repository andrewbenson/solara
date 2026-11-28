import { windowPeekAction } from "@solara/settings";
import { useBrowser } from "../../store/browser";

const motions = new Map<string, { tabId: string; close(): void; expand(done: () => void): void }>();
const peekIn = (windowId: string) => useBrowser.getState().peeks[windowId];

export function registerPeekMotion(windowId: string, tabId: string, close: () => void, expand: (done: () => void) => void) {
  const motion = { tabId, close, expand };
  motions.set(windowId, motion);
  return () => {
    if (motions.get(windowId) === motion) motions.delete(windowId);
  };
}

export function dismissPeek(windowId: string) {
  const peek = peekIn(windowId);
  if (!peek) return;
  const motion = motions.get(windowId);
  if (motion?.tabId !== peek.tabId) return void windowPeekAction(windowId, peek.tabId, "dismiss");
  void windowPeekAction(windowId, peek.tabId, "beginClose").then((accepted) => {
    if (!accepted) return;
    if (motions.get(windowId) === motion) motion.close();
    else finishPeek(windowId, peek.tabId);
  });
}

export function finishPeek(windowId: string, tabId: string) {
  void windowPeekAction(windowId, tabId, "closed");
}

export function openPeekAsTab(windowId: string) {
  const peek = peekIn(windowId);
  if (!peek) return;
  const motion = motions.get(windowId);
  if (motion?.tabId !== peek.tabId) return void windowPeekAction(windowId, peek.tabId, "expand");
  motion.expand(() => void windowPeekAction(windowId, peek.tabId, "promote"));
}

export function openPeekInSplit(windowId: string) {
  const peek = peekIn(windowId);
  if (peek) void windowPeekAction(windowId, peek.tabId, "split");
}

export function runPeekCommand(command: string, windowId: string) {
  const s = useBrowser.getState();
  const peek = s.peeks[windowId];
  if (!peek || s.windowUi[windowId]?.panel.open) return;
  if (command === "openFile") return openPeekAsTab(windowId);
  if (command !== "closeTab") return;
  if (s.find[peek.tabId]?.open) void windowPeekAction(windowId, peek.tabId, "closeFind");
  else dismissPeek(windowId);
}
