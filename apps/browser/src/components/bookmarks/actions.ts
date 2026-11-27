import { nativeWorkspaceCommand } from "@solara/settings";

type OpenMode = "current" | "background" | "foreground" | "window" | "incognito" | "split";

export function openModeFor(e: { metaKey?: boolean; shiftKey?: boolean; altKey?: boolean; middle?: boolean }): OpenMode {
  if (e.metaKey || e.middle) return e.shiftKey ? "foreground" : "background";
  if (e.altKey) return "split";
  if (e.shiftKey) return "window";
  return "current";
}

export function openUrl(url: string, windowId: string | null | undefined, mode: OpenMode) {
  nativeWorkspaceCommand("openBookmarkItems", JSON.stringify({ url, mode }), windowId ?? null);
}

export function openBookmark(id: string, windowId: string | null | undefined, mode: OpenMode) {
  nativeWorkspaceCommand("openBookmarkItems", JSON.stringify({ id, mode }), windowId ?? null);
}

export function openFolder(id: string, windowId: string | null | undefined, mode: "tabs" | "window" | "incognito" = "tabs") {
  nativeWorkspaceCommand("openBookmarkItems", JSON.stringify({ id, mode, folder: true }), windowId ?? null);
}

export function restoreArcFolders(id: string, windowId: string | null): void {
  nativeWorkspaceCommand("restoreArcFolders", id, windowId);
}

export function bookmarkTab(windowId: string, tabId: string) {
  return nativeWorkspaceCommand("bookmarkTab", tabId, windowId);
}
