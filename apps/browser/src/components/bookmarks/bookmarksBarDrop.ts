import type { BookmarkMutation } from "../../lib/bookmarkWriter";
import type { BrowserState } from "../../store/browser";

export function bookmarksBarDropMutations(state: Pick<BrowserState, "bookmarks">, profileId: string, payload: Record<string, unknown>): BookmarkMutation[] {
  const edits: BookmarkMutation[] = [];
  const roots = state.bookmarks.roots[profileId];
  if (!roots || typeof payload.parentId !== "string" || !Array.isArray(payload.items)) return edits;
  const parentId = payload.parentId;
  const parent = state.bookmarks.nodes[parentId];
  const bar = state.bookmarks.nodes[roots.bar];
  if (parent?.kind !== "folder" || (parentId !== roots.bar && parentId !== roots.other && !(bar?.kind === "folder" && bar.children.includes(parentId)))) return edits;
  if (payload.index !== null && (typeof payload.index !== "number" || !Number.isSafeInteger(payload.index) || payload.index < 0 || payload.index > parent.children.length)) return edits;
  let index = payload.index === null ? undefined : payload.index;
  for (const item of payload.items) {
    if (!item || typeof item !== "object" || typeof item.url !== "string") continue;
    const url = item.url.trim();
    if (!/^https?:\/\//i.test(url)) continue;
    try {
      const parsed = new URL(url);
      if ((parsed.protocol !== "http:" && parsed.protocol !== "https:") || !parsed.hostname) continue;
    } catch {
      continue;
    }
    const title = typeof item.title === "string" ? item.title.trim() || url : url;
    edits.push({ method: "addBookmark", args: [{ profileId, parentId, index, url, title }] });
    if (index !== undefined) index++;
  }
  return edits;
}
