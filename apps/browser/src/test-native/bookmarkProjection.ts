import { refreshBookmarkProjection } from "../store/bookmarkProjection";
import type { Bookmarks } from "../store/types";
import type { BrowserState } from "../store/browser";

let sequence = 0;
export const nextBookmarkProjectionOwner = () => String(++sequence);

export function seedBookmarkProjection(store: { getState(): BrowserState; setState(partial: Partial<BrowserState>): void }, document: Bookmarks = { nodes: {}, roots: {} }, ready = false) {
  const owner = nextBookmarkProjectionOwner();
  const profiles: Record<string, { engine: string; generation: string }> = {};
  const views: Record<string, unknown> = {};
  for (const [profile, roots] of Object.entries(document.roots)) {
    const name = roots.bar.slice(4);
    const engine = name === "default" ? "" : name;
    profiles[profile] = { engine, generation: "1" };
    views[engine] = { revision: "1", hasView: true, readyForSync: ready, document };
  }
  const globals = globalThis as typeof globalThis & { acTestBookmarkWriter?: unknown };
  const previous = globals.acTestBookmarkWriter;
  globals.acTestBookmarkWriter = {
    state: () => ({ state: "owned", generation: "1" }),
    projection: () => ({ owner, generation: "1", profiles, views }),
  };
  try { refreshBookmarkProjection(store); } finally { globals.acTestBookmarkWriter = previous; }
}
