import { refreshBookmarkProjection } from "../store/bookmarkProjection";
import { bookmarkWriterErrorCode, bookmarkWriterBinding, bookmarkWriterState, newBookmarkRequestID, submitBookmarkCommands, whileBookmarkEngineHolds } from "@solara/settings";
import type { BookmarkDraft, RemovedBookmarks } from "../store/bookmarks";
import { showToast } from "../components/layout/toasts";
import { useBrowser } from "../store/browser";

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

export class BookmarkConditionFailed extends Error {}

export const isBookmarkConditionFailure = (error: unknown) => bookmarkWriterErrorCode(error) === "conditionFailed" || /bookmark replacement refused: conditionFailed\("/.test(error instanceof Error ? error.message : String(error));

export function projectNativeBookmarks(_engine: string, _revision: string, _documentJSON: string): boolean {
  return refreshBookmarkProjection(useBrowser);
}

export async function submitBookmarks(profileId: string, mutations: BookmarkMutation[], requestId = newBookmarkRequestID("bookmarks")): Promise<unknown[]> {
  const ownership = bookmarkWriterState();
  if (ownership.state !== "owned") throw new Error("Bookmark editing is paused while native ownership is unavailable");
  const first = bookmarkWriterBinding(profileId);
  let receipt: Awaited<ReturnType<typeof submitBookmarkCommands>>;
  try {
    receipt = await whileBookmarkEngineHolds(profileId, { engine: first.engine, generation: first.generation }, (binding) => submitBookmarkCommands(profileId, mutations, binding, requestId));
  } catch (error) {
    if (bookmarkWriterErrorCode(error) === "expired") {
      refreshBookmarkProjection(useBrowser);
      throw error;
    }
    if (!isBookmarkConditionFailure(error)) throw error;
    refreshBookmarkProjection(useBrowser);
    throw new BookmarkConditionFailed(error instanceof Error ? error.message : String(error));
  }
  refreshBookmarkProjection(useBrowser);
  return receipt.results;
}

const trimmed = (args: unknown[]) => {
  const out = [...args];
  while (out.length && out.at(-1) === undefined) out.pop();
  return out;
};

export const reportBookmarkFailure = (error: unknown, { toast = true }: { toast?: boolean } = {}) => {
  if (bookmarkWriterErrorCode(error) === "expired") return;
  const message = error instanceof Error ? error.message : String(error);
  const uncertain = bookmarkWriterErrorCode(error) === "savedUnconfirmed" || /savedUnconfirmed|may have been saved/.test(message);
  console.warn(uncertain ? "[bookmarks] the edit may have been saved; changes are paused" : "[bookmarks] the edit was not saved", error);
  if (!toast) return;
  try {
    const windowId = useBrowser.getState().ui.focusedWindowId;
    if (windowId) showToast(windowId, uncertain ? "Bookmark save unconfirmed" : "Bookmark not saved", uncertain ? "This change may have been saved. Bookmark edits and sync are paused until Solara restarts." : "Solara couldn't save that bookmark change. Try it again.");
  } catch {}
};

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
