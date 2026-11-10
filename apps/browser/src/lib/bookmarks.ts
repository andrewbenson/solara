import { refreshBookmarkProjection } from "../store/bookmarkProjection";
import { onBookmarkProjectionChanged, onBookmarkWriterState, reloadBookmarkProjection } from "@solara/settings";
import { useBrowser } from "../store/browser";

export async function migrateBookmarksFile(_options: { keepMs?: number } = {}): Promise<"kept"> {
  return "kept";
}

export function startBookmarks() {
  let stopped = false;
  const refresh = () => !stopped && refreshBookmarkProjection(useBrowser);
  const projection = onBookmarkProjectionChanged(refresh);
  const authority = onBookmarkWriterState(refresh);
  refresh();
  void reloadBookmarkProjection().then(refresh).catch((error: unknown) => console.warn("[bookmarks] native reload unavailable", error));
  return () => { stopped = true; projection.remove(); authority?.remove(); };
}

export async function reloadBookmarks() {
  await reloadBookmarkProjection();
  refreshBookmarkProjection(useBrowser);
}
