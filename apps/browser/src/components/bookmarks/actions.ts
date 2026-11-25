import { nativeWorkspaceCommand } from "@solara/settings";
import { create } from "zustand";
import { bookmarkWriter, reportBookmarkFailure } from "../../lib/bookmarkWriter";
import { useBrowser } from "../../store/browser";
import { bookmarkProfileId, resolveWindowId, viewTabIds } from "../../store/model";

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

export type BookmarkDialogState =
  | { kind: "page"; windowId: string; bookmarkId: string }
  | { kind: "allTabs"; windowId: string; profileId: string; tabs: { url: string; title: string }[] };

export const useBookmarkDialog = create<{ open: BookmarkDialogState | null; set(open: BookmarkDialogState | null): void }>((set) => ({
  open: null,
  set: (open) => set({ open }),
}));

export async function bookmarkTab(windowId: string, tabId: string) {
  const s = useBrowser.getState();
  const id = windowId;
  const tab = s.tabs[tabId];
  if (!s.windows[id] || !tab?.url) return;
  const profileId = bookmarkProfileId(s, s.windows[id]);
  const roots = s.bookmarks.roots[profileId];
  const existing = Object.values(s.bookmarks.nodes).find(
    (n) => n.kind === "url" && n.url === tab.url && roots && isUnder(n.id, [roots.bar, roots.other]),
  );
  let bookmarkId = existing?.id;
  try {
    bookmarkId ??= await bookmarkWriter.addBookmark({ profileId, url: tab.url, title: tab.customTitle || tab.title || tab.url, favicon: tab.favicon });
  } catch (error) {
    return reportBookmarkFailure(error);
  }
  useBookmarkDialog.getState().set({ kind: "page", windowId: id, bookmarkId });
}

export function bookmarkAllTabs(windowId: string | null | undefined) {
  const s = useBrowser.getState();
  const id = resolveWindowId(s, windowId);
  if (!id) return;
  const tabs = viewTabIds(s, id)
    .map((t) => s.tabs[t]!)
    .filter((t) => /^(https?|file):/.test(t.url))
    .map((t) => ({ url: t.url, title: t.customTitle || t.title || t.url }));
  if (!tabs.length) return;
  useBookmarkDialog.getState().set({ kind: "allTabs", windowId: id, profileId: bookmarkProfileId(s, s.windows[id]), tabs });
}

function isUnder(id: string, roots: string[]): boolean {
  const { nodes } = useBrowser.getState().bookmarks;
  let node = nodes[id];
  for (let i = 0; node && i < 64; i++) {
    if (roots.includes(node.id)) return true;
    node = node.parentId ? nodes[node.parentId] : undefined;
  }
  return false;
}
