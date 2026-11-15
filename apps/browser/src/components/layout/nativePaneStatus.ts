import { windowNativeLayoutGeneration } from "@solara/settings";
import { useBrowser } from "../../store/browser";
import { publishPaneStatusStyle } from "./paneFeed";

export function publishNativePaneStatus(windowId: string, generation: number, tabId: string, owner: object, style: Parameters<typeof publishPaneStatusStyle>[2]) {
  if (generation <= 0 || windowNativeLayoutGeneration(windowId) !== generation || useBrowser.getState().tabs[tabId]?.windowId !== windowId) return;
  publishPaneStatusStyle(tabId, owner, style);
}
