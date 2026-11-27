import { requireOptionalNativeModule } from "expo-modules-core";
import type { SplitSide } from "../../store/splits";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { beginTabDrag, cancelTabDrag, captureDragPage, endNativeTabDrag, updateNativeTabDrag, useTabDrag } from "./tabDrag";

const native = requireOptionalNativeModule<{ tabDrag(onPage: boolean): Promise<void> }>("SolaraSidebarDrag");

let stopWatching: (() => void) | null = null;

function watchTabDrag() {
  stopWatching?.();
  let sent = "";
  stopWatching = useTabDrag.subscribe((d) => {
    const key = String(d.onPage);
    if (key === sent) return;
    sent = key;
    void native?.tabDrag(d.onPage);
  });
  void native?.tabDrag(false);
}

function stopTabDrag() {
  stopWatching?.();
  stopWatching = null;
  void native?.tabDrag(false);
}

addNativeSettingsHandlers({
  "tabDrag.begin": (windowId: string, tabId: string | null, tabIds: string[], owned = false) => {
    beginTabDrag(windowId, tabId, tabIds, owned);
    if (!owned) watchTabDrag();
  },
  "tabDrag.move": (
    _windowId: string,
    x: number,
    y: number,
    outside: boolean,
    overWindow: string | null,
    ox: number,
    oy: number,
    lifted: boolean | null,
    zoneBefore: string | null | false,
    onPage: boolean | null = null,
    target: [string, SplitSide] | null = null,
  ) => updateNativeTabDrag(x, y, outside, overWindow, overWindow ? [ox, oy] : null, lifted, zoneBefore, onPage === null ? null : { onPage, target: target && { tabId: target[0], side: target[1] } }),
  "tabDrag.capture": (windowId: string) => captureDragPage(windowId),
  "tabDrag.end": (_windowId: string, commit: boolean, deadline?: number) => {
    const end = () => {
      const late = !!deadline && Date.now() > deadline;
      const reply = commit && !late ? endNativeTabDrag() : (cancelTabDrag(), { split: false, onPage: false });
      stopTabDrag();
      return reply;
    };
    const delay = __DEV__ ? ((globalThis as { acTabDragEndDelay?: number }).acTabDragEndDelay ?? 0) : 0;
    return delay > 0 ? new Promise<ReturnType<typeof end>>((resolve) => setTimeout(() => resolve(end()), delay)) : end();
  },
});
