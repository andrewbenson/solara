import { bookmarkProjection, bookmarkWriterState, type BookmarkProjection } from "@solara/settings";
import type { BrowserState } from "./browser";
import type { Bookmarks } from "./types";

type Replica = { setState(partial: Partial<BrowserState>): void };
const authorized = new WeakSet<object>();
const frozenBookmarks = new WeakSet<Bookmarks>();
const projected = new WeakMap<Replica, BookmarkProjection>();
const projectedPhase = new WeakMap<Replica, string>();

function sameProjection(a: BookmarkProjection, b: BookmarkProjection): boolean {
  if (a.owner !== b.owner || a.generation !== b.generation) return false;
  const profiles = Object.keys(a.profiles);
  const engines = Object.keys(a.views);
  return profiles.length === Object.keys(b.profiles).length && engines.length === Object.keys(b.views).length
    && profiles.every((id) => a.profiles[id]!.engine === b.profiles[id]?.engine && a.profiles[id]!.generation === b.profiles[id]?.generation)
    && engines.every((engine) => {
      const before = a.views[engine]!, next = b.views[engine];
      return !!next && before.revision === next.revision && before.hasView === next.hasView && before.readyForSync === next.readyForSync;
    });
}

function olderProjection(next: BookmarkProjection, last: BookmarkProjection): boolean {
  if (next.owner !== last.owner) return BigInt(next.owner) < BigInt(last.owner);
  if (next.generation !== last.generation) return BigInt(next.generation) < BigInt(last.generation);
  return Object.entries(next.views).some(([engine, view]) => {
    const before = last.views[engine];
    return !!before && BigInt(view.revision) < BigInt(before.revision);
  });
}

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

function catalogFromProjection(next: BookmarkProjection, phase: string) {
  const bookmarks: Bookmarks = { nodes: {}, roots: {} };
  const bookmarksReady: Record<string, true> = {};
  for (const [profile, binding] of Object.entries(next.profiles)) {
    const view = next.views[binding.engine];
    if (!view?.hasView) continue;
    const roots = view.document.roots[profile];
    if (!roots || view.document.nodes[roots.bar]?.kind !== "folder" || view.document.nodes[roots.other]?.kind !== "folder") continue;
    bookmarks.roots[profile] = roots;
    Object.assign(bookmarks.nodes, view.document.nodes);
    if (phase === "owned" && view.readyForSync) bookmarksReady[profile] = true;
  }
  freezeReplica(bookmarks, bookmarksReady);
  return { bookmarks, bookmarksReady };
}

const emptyCatalog = catalogFromProjection({ owner: "0", generation: "0", profiles: {}, views: {} }, "legacy");
let catalog: { projection: BookmarkProjection; phase: string; value: typeof emptyCatalog } | undefined;

export function bookmarkCatalog() {
  const phase = bookmarkWriterState().state;
  try {
    const projection = bookmarkProjection();
    if (catalog && olderProjection(projection, catalog.projection)) return catalog.value;
    if (catalog?.phase === phase && sameProjection(catalog.projection, projection)) return catalog.value;
    const value = catalogFromProjection(projection, phase);
    catalog = { projection, phase, value };
    return value;
  } catch {
    catalog = undefined;
    return emptyCatalog;
  }
}

function install(store: Replica, partial: Partial<BrowserState>) {
  authorized.add(partial);
  try { store.setState(partial); } finally { authorized.delete(partial); }
}

export function applyBookmarkProjectionForTests(store: Replica, current: BrowserState): boolean {
  const state = bookmarkWriterState();
  if (state.state === "legacy") return false;
  protectBookmarkReplica(current);
  let next: BookmarkProjection;
  try { next = bookmarkProjection(); } catch {
    projectedPhase.delete(store);
    if (Object.keys(current.bookmarksReady).length) install(store, { bookmarksReady: Object.freeze({}) });
    return false;
  }
  const last = projected.get(store);
  if (last && olderProjection(next, last)) return false;
  if (last && projectedPhase.get(store) === state.state && sameProjection(last, next)) return false;
  const { bookmarks, bookmarksReady: ready } = catalogFromProjection(next, state.state);
  projected.set(store, next);
  projectedPhase.set(store, state.state);
  const sameBookmarks = Object.keys(current.bookmarks.nodes).length === Object.keys(bookmarks.nodes).length
    && Object.entries(bookmarks.nodes).every(([id, node]) => current.bookmarks.nodes[id] === node)
    && Object.keys(current.bookmarks.roots).length === Object.keys(bookmarks.roots).length
    && Object.entries(bookmarks.roots).every(([profile, roots]) => current.bookmarks.roots[profile]?.bar === roots.bar && current.bookmarks.roots[profile]?.other === roots.other);
  const sameReady = Object.keys(current.bookmarksReady).length === Object.keys(ready).length && Object.keys(ready).every((profile) => current.bookmarksReady[profile] === true);
  if (sameBookmarks && sameReady) return false;
  install(store, { bookmarks: sameBookmarks ? current.bookmarks : bookmarks, bookmarksReady: sameReady ? current.bookmarksReady : ready });
  return true;
}
