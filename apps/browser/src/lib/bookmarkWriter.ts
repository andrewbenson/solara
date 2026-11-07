import { bookmarkWriterSnapshot, bookmarkWriterState, submitBookmarkMutations } from "@solara/settings";
import type { BookmarkDraft, RemovedBookmarks } from "../store/bookmarks";
import { useBrowser } from "../store/browser";
import type { BookmarkNode, Bookmarks } from "../store/types";

export type BookmarkMethod =
  | "addBookmark"
  | "addBookmarkFolder"
  | "updateBookmark"
  | "moveBookmark"
  | "removeBookmark"
  | "toggleBookmark"
  | "addBookmarkTree"
  | "removeBookmarks"
  | "restoreBookmarks"
  | "expectChildren";

export type BookmarkMutation = { method: BookmarkMethod; args: unknown[] };

const projected = new Map<string, bigint>();
let requests = 0;

export class BookmarkConditionFailed extends Error {}

export const isBookmarkConditionFailure = (error: unknown) => /bookmark replacement refused: conditionFailed\("/.test(error instanceof Error ? error.message : String(error));

function legacy(mutation: BookmarkMutation): unknown {
  if (mutation.method === "expectChildren") {
    const [, folderId, children] = mutation.args as [string, string, string[]];
    const node = useBrowser.getState().bookmarks.nodes[folderId];
    if (node?.kind !== "folder" || JSON.stringify(node.children) !== JSON.stringify(children)) throw new BookmarkConditionFailed(`conditionFailed("${folderId}")`);
    return true;
  }
  const store = useBrowser.getState() as unknown as Record<BookmarkMethod, (...args: unknown[]) => unknown>;
  return store[mutation.method](...mutation.args);
}

function engineNodes(b: Bookmarks, roots: { bar: string; other: string }[]): Set<string> {
  const out = new Set<string>();
  const walk = (id: string) => {
    if (out.has(id)) return;
    out.add(id);
    const node = b.nodes[id];
    if (node?.kind === "folder") node.children.forEach(walk);
  };
  for (const root of roots) {
    walk(root.bar);
    walk(root.other);
  }
  return out;
}

export function projectNativeBookmarks(engine: string, revision: string, documentJSON: string): boolean {
  const next = BigInt(revision);
  const last = projected.get(engine);
  if (last !== undefined && last >= next) return false;
  projected.set(engine, next);
  const document = JSON.parse(documentJSON) as Bookmarks;
  const current = useBrowser.getState().bookmarks;
  const engineRoots = [...new Map(Object.values(document.roots).map((roots) => [roots.bar, roots])).values()];
  const stale = engineNodes(current, engineRoots);
  const nodes: Record<string, BookmarkNode> = {};
  for (const [id, node] of Object.entries(current.nodes)) if (!stale.has(id)) nodes[id] = node;
  Object.assign(nodes, document.nodes);
  const roots = { ...current.roots };
  for (const [profile, own] of Object.entries(document.roots)) {
    const mapped = current.roots[profile];
    if (!mapped || (mapped.bar === own.bar && mapped.other === own.other)) roots[profile] = own;
  }
  useBrowser.setState({ bookmarks: { nodes, roots } });
  return true;
}

export async function submitBookmarks(profileId: string, mutations: BookmarkMutation[], requestId = `bookmarks-${Date.now()}-${++requests}`): Promise<unknown[]> {
  if (bookmarkWriterState().state !== "owned") {
    for (const mutation of mutations) if (mutation.method === "expectChildren") legacy(mutation);
    return mutations.map(legacy);
  }
  const snapshot = bookmarkWriterSnapshot(profileId);
  let receipt: Awaited<ReturnType<typeof submitBookmarkMutations>>;
  try {
    receipt = await submitBookmarkMutations(profileId, mutations, { engine: snapshot.engine, generation: snapshot.generation }, requestId);
  } catch (error) {
    if (!isBookmarkConditionFailure(error)) throw error;
    const fresh = bookmarkWriterSnapshot(profileId);
    projectNativeBookmarks(fresh.engine, fresh.revision, fresh.document);
    throw new BookmarkConditionFailed(error instanceof Error ? error.message : String(error));
  }
  projectNativeBookmarks(receipt.engine, receipt.revision, receipt.document);
  return receipt.results;
}

const trimmed = (args: unknown[]) => {
  const out = [...args];
  while (out.length && out.at(-1) === undefined) out.pop();
  return out;
};

export const reportBookmarkFailure = (error: unknown) => console.warn("[bookmarks] the edit was not saved", error);

const toggling = new Map<string, Promise<boolean | undefined>>();

export function toggleBookmarkFromUI(profileId: string, page: { url: string; title: string; favicon: string | null }): Promise<boolean | undefined> {
  const key = `${profileId}\n${page.url}`;
  const pending = toggling.get(key);
  if (pending) return pending;
  const run = bookmarkWriter
    .toggleBookmark(profileId, page)
    .catch((error: unknown) => {
      reportBookmarkFailure(error);
      return undefined;
    })
    .finally(() => toggling.delete(key));
  toggling.set(key, run);
  return run;
}

const one = async <T>(profileId: string, mutation: BookmarkMutation): Promise<T> => (await submitBookmarks(profileId, [mutation]))[0] as T;

type AddBookmark = { profileId: string; url: string; title: string; favicon?: string | null; parentId?: string; index?: number };
type AddFolder = { profileId: string; title: string; parentId?: string; index?: number };

export const bookmarkWriter = {
  addBookmark: (options: AddBookmark) => one<string>(options.profileId, { method: "addBookmark", args: [options] }),
  addBookmarkFolder: (options: AddFolder) => one<string>(options.profileId, { method: "addBookmarkFolder", args: [options] }),
  updateBookmark: (profileId: string, id: string, patch: { title?: string; url?: string; favicon?: string | null }) =>
    one<void>(profileId, { method: "updateBookmark", args: [id, patch] }),
  moveBookmark: (profileId: string, id: string, parentId: string, index?: number) =>
    one<void>(profileId, { method: "moveBookmark", args: trimmed([id, parentId, index]) }),
  removeBookmark: (profileId: string, id: string) => one<void>(profileId, { method: "removeBookmark", args: [id] }),
  toggleBookmark: (profileId: string, page: { url: string; title: string; favicon: string | null }) =>
    one<boolean>(profileId, { method: "toggleBookmark", args: [profileId, page] }),
  addBookmarkTree: (profileId: string, drafts: BookmarkDraft[], parentId?: string, index?: number) =>
    one<string[]>(profileId, { method: "addBookmarkTree", args: trimmed([profileId, drafts, parentId, index]) }),
  removeBookmarks: (profileId: string, ids: string[]) => one<RemovedBookmarks>(profileId, { method: "removeBookmarks", args: [ids] }),
  restoreBookmarks: (profileId: string, removed: RemovedBookmarks) => one<void>(profileId, { method: "restoreBookmarks", args: [removed] }),
};
