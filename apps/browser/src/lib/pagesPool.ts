import { tabPoolAvailable, windowPagesPoolActive, windowPaneRootsActive, windowShellActive } from "@solara/settings";

export const pagesPooledIn = (windowId: string) =>
  windowShellActive(windowId) && windowPaneRootsActive(windowId) && windowPagesPoolActive() && tabPoolAvailable();

export const panePromptsNativeIn = (windowId: string) => pagesPooledIn(windowId);
