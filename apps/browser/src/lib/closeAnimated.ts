import { animateWindowClose, focusWindow } from "@solara/shell";
import { useBrowser } from "../store/browser";
import { isWindowClosing, startClosingWindow, stopClosingWindow } from "../store/closingWindows";

export { isWindowClosing };

const pending = new Map<string, () => void>();

export function closeWindowAnimated(windowId: string, replacedBy: string | null = null, then?: () => void) {
  const w = useBrowser.getState().windows[windowId];
  if (isWindowClosing(windowId) || !w) return;
  const leaving = new Set(w.tabIds);
  const close = () => {
    if (!pending.delete(windowId)) return;
    stopClosingWindow(windowId);
    const now = useBrowser.getState().windows[windowId];
    if (!now) return;
    if (now.tabIds.some((id) => !leaving.has(id))) return void focusWindow(windowId, true);
    useBrowser.getState().closeWindow(windowId);
    then?.();
  };
  startClosingWindow(windowId);
  pending.set(windowId, close);
  void animateWindowClose(windowId, replacedBy).then(close, close);
}

export function finishAnimatedCloses() {
  for (const close of [...pending.values()]) close();
}
