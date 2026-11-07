import { cleanUrl } from "@solara/core";
import { copyText, prompt } from "@solara/shell";
import { addFolderToSidebar, restoreArcFolders } from "../../lib/bookmarkGroups";
import { folderChildren } from "../../store/bookmarks";
import { useBrowser } from "../../store/browser";
import type { BookmarkNode } from "../../store/types";
import { openInternalPage } from "../pages/urls";
import { openFolder, openUrl } from "./actions";
import { editBookmark } from "./edit";

export async function handleBookmarksBarMenuChoice(windowId: string, profileId: string, action: string, id?: string) {
  const s = useBrowser.getState();
  const node = id ? s.bookmarks.nodes[id] : undefined;
  const bar = s.bookmarks.roots[profileId]?.bar;
  if (node?.kind === "url") {
    if (action === "open") openUrl(node.url, windowId, "current");
    if (action === "tab") openUrl(node.url, windowId, "foreground");
    if (action === "window") openUrl(node.url, windowId, "window");
    if (action === "incognito") openUrl(node.url, windowId, "incognito");
    if (action === "split") openUrl(node.url, windowId, "split");
    if (action === "edit") void editBookmark(node.id, windowId);
    if (action === "copy") copyText(cleanUrl(node.url));
  }
  if (node?.kind === "folder") {
    if (action === "openAll") void openFolder(node.id, windowId, "tabs");
    if (action === "openAllWindow") void openFolder(node.id, windowId, "window");
    if (action === "openAllIncognito") void openFolder(node.id, windowId, "incognito");
    if (action === "rename") void editBookmark(node.id, windowId);
    if (action === "addGroup") addFolderToSidebar(node.id, windowId);
    if (action === "restoreArc") restoreArcFolders(node.id, windowId);
  }
  if (action === "delete" && node) useBrowser.getState().removeBookmark(node.id);
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
  if (title) useBrowser.getState().addBookmarkFolder({ profileId, title, ...position });
}
