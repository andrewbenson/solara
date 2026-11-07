import { useBrowser } from "../../store/browser";
import type { Settings } from "../../store/settings";

export const BOOKMARKS_BAR_HEIGHT = 30;

export function bookmarksBarShown(mode: BookmarksBarMode, tab: { url: string } | undefined): boolean {
  if (!tab || mode === "never") return false;
  return mode === "always" || !tab.url;
}

export type BookmarksBarMode = Settings["bookmarksBar"];

export function useBookmarksBarMode(windowId: string): BookmarksBarMode {
  return useBrowser((s) => (s.windows[windowId]?.incognito ? "never" : s.settings.bookmarksBar));
}
