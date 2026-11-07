import { NativePage, type NativePageEvent } from "@solara/settings";
import { useEffect, useMemo, useRef, useState } from "react";
import { StyleSheet } from "react-native";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import type { BookmarkNode } from "../../store/types";
import { useAddressBarInSidebar } from "../layout/windowLayout";
import { useBookmarkDialog, type BookmarkDialogState } from "./actions";
import { bookmarkDialogPlacement, finishBookmarkDialog, newDialogFolder, profileOfNode, removeDialogBookmark } from "./BookmarkDialog";
import { useBookmarkEditor, type EditorState } from "./edit";
import { formGate } from "./formGate";
import { saveBookmarkEditor } from "./EditBookmarkDialog";

function useFolders(profileId: string | null) {
  const bookmarks = useBrowser((s) => s.bookmarks);
  return useMemo(() => {
    const roots = profileId ? bookmarks.roots[profileId] : undefined;
    const folders: Record<string, unknown>[] = [];
    const walk = (id: string, depth: number) => {
      const node: BookmarkNode | undefined = bookmarks.nodes[id];
      if (node?.kind !== "folder" || depth > 64) return;
      folders.push({ id: node.id, kind: "folder", parentId: node.parentId ?? null, title: node.title, children: node.children.filter((c) => bookmarks.nodes[c]?.kind === "folder") });
      node.children.forEach((c) => walk(c, depth + 1));
    };
    if (roots) {
      walk(roots.bar, 0);
      walk(roots.other, 0);
    }
    return { folders, roots: roots ?? null };
  }, [bookmarks, profileId]);
}

export function NativeBookmarkDialog({ state }: { state: BookmarkDialogState }) {
  const theme = useTheme();
  const addressBar = useAddressBarInSidebar();
  const bookmark = useBrowser((s) => (state.kind === "page" ? s.bookmarks.nodes[state.bookmarkId] : undefined));
  const profileId = state.kind === "page" ? profileOfNode(state.bookmarkId) : state.profileId;
  const { folders, roots } = useFolders(profileId);
  const [initial] = useState(() => ({
    name: state.kind === "page" ? (bookmark?.title ?? "") : "",
    folderId: state.kind === "page" ? (bookmark?.parentId ?? null) : (useBrowser.getState().bookmarks.roots[state.profileId]?.bar ?? null),
  }));
  const [select, setSelect] = useState<{ id: string; rev: number } | null>(null);
  useEffect(() => {
    if (state.kind === "page" && !bookmark) useBookmarkDialog.getState().set(null);
  }, [bookmark]);
  const json = JSON.stringify({
    kind: state.kind,
    key: state.kind === "page" ? state.bookmarkId : "all",
    name: initial.name,
    folderId: initial.folderId,
    tabCount: state.kind === "allTabs" ? state.tabs.length : null,
    folders,
    roots,
    placement: bookmarkDialogPlacement(addressBar),
    select: select?.id ?? null,
    selectRev: select?.rev ?? null,
    dark: !!theme.dark,
  });
  const gate = useRef(formGate()).current;
  const onEvent = (e: NativePageEvent) => gate(e.kind === "done" || e.kind === "remove" || e.kind === "newFolder", async () => {
    if (e.kind === "done") await finishBookmarkDialog(state, String(e.name ?? ""), (e.folderId as string | null) ?? null);
    else if (e.kind === "remove") await removeDialogBookmark(state);
    else if (e.kind === "cancel") useBookmarkDialog.getState().set(null);
    else if (e.kind === "newFolder") {
      const id = await newDialogFolder(state, profileId, (e.parentId as string | null) ?? null);
      if (id) setSelect((prev) => ({ id, rev: (prev?.rev ?? 0) + 1 }));
    }
  });
  return <NativePage kind="bookmarkForm" state={json} style={StyleSheet.absoluteFill} onPageEvent={(e) => void onEvent(e.nativeEvent).catch(keepFormOpen)} />;
}

const keepFormOpen = (error: unknown) => console.warn("[bookmarks] the edit was not saved; the form stays open", error);

export function NativeBookmarkEditor({ state }: { state: EditorState }) {
  const theme = useTheme();
  const { folders, roots } = useFolders(state.profileId);
  const [initial] = useState(() => {
    const s = useBrowser.getState();
    const node = s.bookmarks.nodes[state.bookmarkId ?? ""];
    return {
      node: !!node,
      name: node?.title ?? "",
      url: node?.kind === "url" ? node.url : "",
      folderId: node?.parentId ?? state.parentId ?? s.bookmarks.roots[state.profileId]?.bar ?? null,
    };
  });
  const kind = state.folder ? (initial.node ? "renameFolder" : "newFolder") : initial.node ? "editBookmark" : "addBookmark";
  const json = JSON.stringify({
    kind,
    key: `${state.bookmarkId}:${state.folder}`,
    name: initial.name,
    url: initial.url,
    folderId: initial.folderId,
    folders,
    roots,
    dark: !!theme.dark,
  });
  const gate = useRef(formGate()).current;
  const onEvent = (e: NativePageEvent) => gate(e.kind === "save", async () => {
    if (e.kind === "save") await saveBookmarkEditor(state, String(e.name ?? ""), String(e.url ?? ""), (e.parentId as string | null) ?? null);
    else if (e.kind === "cancel") useBookmarkEditor.getState().set(null);
  });
  return <NativePage kind="bookmarkForm" state={json} style={StyleSheet.absoluteFill} onPageEvent={(e) => void onEvent(e.nativeEvent).catch(keepFormOpen)} />;
}
