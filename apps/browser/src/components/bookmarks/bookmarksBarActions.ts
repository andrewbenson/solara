import { cleanUrl } from "@solara/core";
import { copyText, prompt } from "@solara/shell";
import { addFolderToSidebar } from "../../lib/bookmarkGroups";
import { bookmarkWriter, reportBookmarkFailure } from "../../lib/bookmarkWriter";
import { folderChildren } from "../../store/bookmarks";
import { useBrowser } from "../../store/browser";
import type { BookmarkNode } from "../../store/types";
import { openInternalPage } from "../pages/urls";
import { openBookmark, openFolder, restoreArcFolders } from "./actions";
import { editBookmark } from "./edit";

export async function handleBookmarksBarMenuChoice(windowId: string, profileId: string, action: string, id?: string) {
  const modes = { open: "current", tab: "foreground", window: "window", incognito: "incognito", split: "split" } as const;
  if (id && Object.prototype.hasOwnProperty.call(modes, action)) return openBookmark(id, windowId, modes[action as keyof typeof modes]);
  if (id && action === "openAll") return openFolder(id, windowId, "tabs");
  if (id && action === "openAllWindow") return openFolder(id, windowId, "window");
  if (id && action === "openAllIncognito") return openFolder(id, windowId, "incognito");
  if (id && action === "restoreArc") return restoreArcFolders(id, windowId);
  const s = useBrowser.getState();
  const node = id ? s.bookmarks.nodes[id] : undefined;
  if (node?.kind === "url") {
    if (action === "edit") void editBookmark(node.id, windowId);
    if (action === "copy") copyText(cleanUrl(node.url));
  }
  if (node?.kind === "folder") {
    if (action === "rename") void editBookmark(node.id, windowId);
    if (action === "addGroup") addFolderToSidebar(node.id, windowId);
  }
  if (action === "delete" && node) await bookmarkWriter.removeBookmark(profileId, node.id).catch(reportBookmarkFailure);
  if (action === "addPage") addPageFromBookmarksBar(windowId, profileId, node ?? null);
  if (action === "addFolder") await addFolderFromBookmarksBar(windowId, profileId, node ?? null);
  if (action === "manage") openInternalPage("bookmarks", windowId);
  if (action === "bar" && (id === "always" || id === "newTab" || id === "never")) useBrowser.getState().updateSettings({ bookmarksBar: id });
  if (action === "hide") useBrowser.getState().updateSettings({ hideBookmarksBarImport: true });
}

function bookmarksBarInsertion(profileId: string, node: BookmarkNode | null) {
  const s = useBrowser.getState();
  const parentId = node?.parentId ?? s.bookmarks.roots[profileId]?.bar;
  const index = node && parentId ? folderChildren(s.bookmarks, parentId).findIndex((n) => n.id === node.id) + 1 : undefined;
  return { parentId: parentId ?? undefined, index };
}

function addPageFromBookmarksBar(windowId: string, profileId: string, node: BookmarkNode | null) {
  void editBookmark(null, windowId, { profileId, ...bookmarksBarInsertion(profileId, node) });
}

async function addFolderFromBookmarksBar(windowId: string, profileId: string, node: BookmarkNode | null) {
  const position = bookmarksBarInsertion(profileId, node);
  const title = await prompt({ title: "New Folder", placeholder: "Folder name", confirmTitle: "Create", windowId });
  if (title) await bookmarkWriter.addBookmarkFolder({ profileId, title, ...position }).catch(reportBookmarkFailure);
}
