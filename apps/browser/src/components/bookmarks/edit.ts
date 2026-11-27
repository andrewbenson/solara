import { nativeWorkspaceCommand } from "@solara/settings";

export function editBookmark(id: string | null, windowId: string, options?: { profileId: string; parentId?: string; index?: number; folder?: boolean }) {
  return nativeWorkspaceCommand("editBookmark", JSON.stringify({ id, ...options }), windowId);
}
