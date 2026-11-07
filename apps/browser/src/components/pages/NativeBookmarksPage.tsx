import { NativePage, type NativePageEvent } from "@solara/settings";
import { useEffect, useMemo, useRef, useState } from "react";
import { StyleSheet } from "react-native";
import { addFolderToSidebar, makesGroup, restorableArcHolder, restoreArcFolders } from "../../lib/bookmarkGroups";
import { bookmarkWriter, reportBookmarkFailure, submitBookmarks, type BookmarkMutation } from "../../lib/bookmarkWriter";
import { useTheme } from "../../lib/theme";
import type { RemovedBookmarks } from "../../store/bookmarks";
import { useBrowser } from "../../store/browser";
import { engineProfile } from "../../store/model";
import type { BookmarkNode } from "../../store/types";
import { openFolder, openUrl } from "../bookmarks/actions";
import { editBookmark } from "../bookmarks/edit";
import { openImport } from "../settings/windows";
import { pageThemeState } from "./nativePageTheme";

type OpenMode = Parameters<typeof openUrl>[2];
type Bookmarks = ReturnType<typeof useBrowser.getState>["bookmarks"];

function profileNodes(b: Bookmarks, roots: { bar: string; other: string } | undefined) {
  const folders: string[] = [];
  const bookmarkIcons: Record<string, string> = {};
  const walk = (id: string, depth: number) => {
    const node: BookmarkNode | undefined = b.nodes[id];
    if (!node || depth > 64) return;
    if (node.kind === "folder") {
      folders.push(node.id);
      node.children.forEach((c) => walk(c, depth + 1));
    } else if (node.favicon) bookmarkIcons[node.id] = node.favicon;
  };
  if (roots) {
    walk(roots.bar, 0);
    walk(roots.other, 0);
  }
  return { folders, bookmarkIcons };
}

export function NativeBookmarksPage({ tabId, profileId }: { tabId: string; profileId: string }) {
  const theme = useTheme();
  const windowId = useBrowser((s) => s.tabs[tabId]?.windowId ?? "");
  const bookmarks = useBrowser((s) => s.bookmarks);
  const roots = bookmarks.roots[profileId];
  const [undo, setUndo] = useState<{ removed: RemovedBookmarks; count: number } | null>(null);
  const restoring = useRef<{ removed: RemovedBookmarks; count: number } | null>(null);
  useEffect(() => {
    if (!undo) return;
    const timer = setTimeout(() => setUndo((current) => (current && restoring.current === current ? current : null)), 8000);
    return () => clearTimeout(timer);
  }, [undo]);

  const actionFlags = useMemo(() => {
    const { folders, bookmarkIcons } = profileNodes(bookmarks, roots);
    const s = { bookmarks };
    const groupable = folders.filter((id) => makesGroup(s, id));
    const arcRestorable = folders.filter((id) => restorableArcHolder(useBrowser.getState(), id));
    return { groupable, arcRestorable, bookmarkIcons };
  }, [bookmarks, roots]);
  const state = JSON.stringify({ ...pageThemeState(theme), profileId, engineProfile: engineProfile(profileId), undoCount: undo?.count ?? null, ...actionFlags });

  const onEvent = async (e: NativePageEvent) => {
    const id = String(e.id ?? "");
    if (e.kind === "open") openUrl(String(e.url), windowId, e.mode as OpenMode);
    else if (e.kind === "openAll") void openFolder(id, windowId, e.newWindow ? "window" : "tabs");
    else if (e.kind === "edit") editBookmark(id, windowId, { profileId });
    else if (e.kind === "addGroup") addFolderToSidebar(id, windowId);
    else if (e.kind === "restoreArc") restoreArcFolders(id, windowId);
    else if (e.kind === "delete") {
      const removed = await bookmarkWriter.removeBookmarks(profileId, e.ids as string[]);
      setUndo({ removed, count: removed.places.length });
    } else if (e.kind === "undo") {
      if (!undo || restoring.current) return;
      restoring.current = undo;
      try {
        await bookmarkWriter.restoreBookmarks(profileId, undo.removed);
        setUndo((current) => (current === undo ? null : current));
      } catch (error) {
        setUndo((current) => (current === undo || !current ? { ...undo } : current));
        throw error;
      } finally {
        restoring.current = null;
      }
    } else if (e.kind === "move") {
      await submitBookmarks(profileId, bookmarksPageMoves(e));
    } else if (e.kind === "addBookmark") editBookmark(null, windowId, { profileId, parentId: (e.parentId as string | null) ?? undefined });
    else if (e.kind === "addFolder") editBookmark(null, windowId, { profileId, parentId: (e.parentId as string | null) ?? undefined, folder: true });
    else if (e.kind === "import") openImport();
  };
  return <NativePage kind="bookmarks" state={state} style={StyleSheet.absoluteFill} onPageEvent={(e) => void onEvent(e.nativeEvent).catch(reportBookmarkFailure)} />;
}

export function bookmarksPageMoves(e: NativePageEvent): BookmarkMutation[] {
  const moving = e.ids as string[];
  if (typeof e.into === "string") return moving.map((m) => ({ method: "moveBookmark", args: [m, e.into] }));
  const listed = e.listed as string[];
  let index = e.index as number;
  for (const m of moving) {
    const from = listed.indexOf(m);
    if (from >= 0 && from < (e.index as number)) index--;
  }
  return moving.map((m, i) => ({ method: "moveBookmark", args: [m, String(e.parentId), index + i] }));
}
