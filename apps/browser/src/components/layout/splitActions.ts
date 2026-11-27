import { nativeOpenLinkInSplit, nativeOpenSplitPane } from "@solara/settings";
import type { OpenPaneOptions } from "../../store/splits";

export { hideKeyedToast, hideToast, showNotice, showToast, useToasts, type Notice, type ToastOptions } from "./toasts";
export { nativeOpenLinkInSplit as openLinkInSplit };

export function openSplitPane(windowId: string, options: OpenPaneOptions = {}): string | null {
  return nativeOpenSplitPane(windowId, options);
}
