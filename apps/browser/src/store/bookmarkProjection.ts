import { bookmarkProjection, bookmarkWriterState, type BookmarkProjection } from "@solara/settings";
import type { BrowserState } from "./browser";
import type { Bookmarks } from "./types";

type Replica = { getState(): BrowserState; setState(partial: Partial<BrowserState>): void };
const authorized = new WeakSet<object>();
const frozenBookmarks = new WeakSet<Bookmarks>();
const projected = new WeakMap<Replica, BookmarkProjection>();

export const nativeBookmarksSelected = () => true;

function freezeReplica(bookmarks: Bookmarks, ready: Record<string, true>) {
  if (!frozenBookmarks.has(bookmarks)) {
    for (const node of Object.values(bookmarks.nodes)) {
      if (node.kind === "folder") Object.freeze(node.children);
      Object.freeze(node);
    }
    for (const roots of Object.values(bookmarks.roots)) Object.freeze(roots);
    Object.freeze(bookmarks.nodes);
    Object.freeze(bookmarks.roots);
    Object.freeze(bookmarks);
    frozenBookmarks.add(bookmarks);
  }
  Object.freeze(ready);
}

export function protectBookmarkReplica(state: BrowserState) {
  if (nativeBookmarksSelected()) freezeReplica(state.bookmarks, state.bookmarksReady);
}

export function guardBookmarkWrite(partial: Partial<BrowserState>, previous: BrowserState, replace?: boolean) {
  if (authorized.delete(partial)) return;
  if (!nativeBookmarksSelected()) return;
  if (("bookmarks" in partial && partial.bookmarks !== previous.bookmarks) || ("bookmarksReady" in partial && partial.bookmarksReady !== previous.bookmarksReady) || (replace && (!("bookmarks" in partial) || !("bookmarksReady" in partial)))) {
    throw new Error("bookmarks are owned by the native coordinator; JS writes are refused");
  }
}

function install(store: Replica, partial: Partial<BrowserState>) {
  authorized.add(partial);
  try { store.setState(partial); } finally { authorized.delete(partial); }
}

export function refreshBookmarkProjection(store: Replica): boolean {
  const state = bookmarkWriterState();
  if (state.state === "legacy") return false;
  protectBookmarkReplica(store.getState());
  let next: BookmarkProjection;
  try { next = bookmarkProjection(); } catch {
    if (Object.keys(store.getState().bookmarksReady).length) install(store, { bookmarksReady: Object.freeze({}) });
    return false;
  }
  const last = projected.get(store);
  if (last && BigInt(next.owner) < BigInt(last.owner)) return false;
  if (last?.owner === next.owner) {
    if (BigInt(next.generation) < BigInt(last.generation)) return false;
    if (next.generation === last.generation) {
      for (const [engine, view] of Object.entries(next.views)) {
        const before = last.views[engine];
        if (before && BigInt(view.revision) < BigInt(before.revision)) return false;
      }
    }
  }
  const bookmarks: Bookmarks = { nodes: {}, roots: {} };
  const ready: Record<string, true> = {};
  for (const [profile, binding] of Object.entries(next.profiles)) {
    const view = next.views[binding.engine];
    if (!view?.hasView) continue;
    const roots = view.document.roots[profile];
    if (!roots || view.document.nodes[roots.bar]?.kind !== "folder" || view.document.nodes[roots.other]?.kind !== "folder") continue;
    bookmarks.roots[profile] = roots;
    Object.assign(bookmarks.nodes, view.document.nodes);
    if (state.state === "owned" && view.readyForSync) ready[profile] = true;
  }
  freezeReplica(bookmarks, ready);
  const current = store.getState();
  projected.set(store, next);
  const sameBookmarks = JSON.stringify(current.bookmarks) === JSON.stringify(bookmarks);
  const sameReady = JSON.stringify(current.bookmarksReady) === JSON.stringify(ready);
  if (sameBookmarks && sameReady) return false;
  install(store, { bookmarks: sameBookmarks ? current.bookmarks : bookmarks, bookmarksReady: sameReady ? current.bookmarksReady : ready });
  return true;
}
