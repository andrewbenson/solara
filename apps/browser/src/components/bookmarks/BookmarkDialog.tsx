import { prompt } from "@solara/shell";
import { bookmarkWriter, submitBookmarks, type BookmarkMutation } from "../../lib/bookmarkWriter";
import { layout } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { useWindowId } from "../../store/hooks";
import { useBookmarkDialog, type BookmarkDialogState } from "./actions";
import { NativeBookmarkDialog } from "./NativeBookmarkForms";
import { SIDEBAR_HEADER_WITH_FIELD } from "../layout/windowLayout";

export function BookmarkDialog() {
  const windowId = useWindowId();
  const open = useBookmarkDialog((d) => (d.open?.windowId === windowId ? d.open : null));
  if (!open) return null;
  const key = open.kind === "page" ? open.bookmarkId : "all";
  return <NativeBookmarkDialog key={key} state={open} />;
}

export async function finishBookmarkDialog(state: BookmarkDialogState, name: string, folderId: string | null) {
  const s = useBrowser.getState();
  const close = () => useBookmarkDialog.getState().set(null);
  if (state.kind === "page") {
    const bookmark = s.bookmarks.nodes[state.bookmarkId];
    const profileId = profileOfNode(state.bookmarkId);
    if (!bookmark || !profileId) return close();
    const edits: BookmarkMutation[] = [];
    if (name.trim() && name !== bookmark.title) edits.push({ method: "updateBookmark", args: [state.bookmarkId, { title: name.trim() }] });
    if (folderId && folderId !== bookmark.parentId) edits.push({ method: "moveBookmark", args: [state.bookmarkId, folderId] });
    if (edits.length) await submitBookmarks(profileId, edits);
  } else {
    const title = name.trim() || "Tabs";
    await bookmarkWriter.addBookmarkTree(state.profileId, [{ title, children: state.tabs.map((t) => ({ title: t.title, url: t.url })) }], folderId ?? undefined);
  }
  close();
}

export async function removeDialogBookmark(state: BookmarkDialogState) {
  const profileId = state.kind === "page" ? profileOfNode(state.bookmarkId) : null;
  if (state.kind === "page" && profileId) await bookmarkWriter.removeBookmark(profileId, state.bookmarkId);
  useBookmarkDialog.getState().set(null);
}

export async function newDialogFolder(state: BookmarkDialogState, profileId: string | null, folderId: string | null) {
  const title = await prompt({ title: "New Folder", placeholder: "Folder name", confirmTitle: "Create", windowId: state.windowId });
  if (!title || !profileId) return null;
  return bookmarkWriter.addBookmarkFolder({ profileId, title, parentId: folderId ?? undefined });
}

export function bookmarkDialogPlacement(addressBar: boolean) {
  return addressBar ? { top: SIDEBAR_HEADER_WITH_FIELD + 4, left: layout.sidebarInset } : { top: layout.cardTop + layout.toolbarHeight - 2, right: layout.cardInset + 10 };
}

export function profileOfNode(id: string): string | null {
  const b = useBrowser.getState().bookmarks;
  let node = b.nodes[id];
  for (let i = 0; node?.parentId && i < 64; i++) node = b.nodes[node.parentId];
  if (!node) return null;
  return Object.entries(b.roots).find(([, r]) => r.bar === node!.id || r.other === node!.id)?.[0] ?? null;
}
