import { onLiveAuthRequest, resolveLiveAuth } from "@solara/settings";
import { liveCommand } from "./command";
import { useBrowser } from "../store/browser";

let started = false;
const watching = new Map<string, () => void>();

export function startGoogleAuth() {
  if (started) return;
  started = true;
  onLiveAuthRequest((request) => {
    if ("cancelled" in request) {
      watching.get(request.requestId)?.();
      return;
    }
    const { requestId, url, redirectPrefix } = request;
    const s = useBrowser.getState();
    const windowId = s.ui.focusOrder.find((id) => s.windows[id] && !s.windows[id]!.incognito) ?? s.windowOrder.find((id) => !s.windows[id]!.incognito);
    if (!windowId) {
      void resolveLiveAuth(requestId, null, "Open a browser window first");
      return;
    }
    const tabId = s.newTab(windowId, { url });
    const unsubscribe = useBrowser.subscribe((state, prev) => {
      if (state.tabs === prev.tabs) return;
      const tab = state.tabs[tabId];
      if (!tab) {
        stop();
        void resolveLiveAuth(requestId, null, "Sign-in was cancelled");
        return;
      }
      if (!tab.url.startsWith(redirectPrefix)) return;
      stop();
      useBrowser.getState().closeTab(tabId);
      void resolveLiveAuth(requestId, tab.url, null);
    });
    const stop = () => {
      unsubscribe();
      watching.delete(requestId);
    };
    watching.set(requestId, () => {
      stop();
      if (useBrowser.getState().tabs[tabId]) useBrowser.getState().closeTab(tabId);
    });
  });
}

export const connectGoogleDrive = async (_windowId: string, clientId: string, clientSecret: string): Promise<void> => {
  await liveCommand("connectGoogleDrive", { clientId, clientSecret });
};
