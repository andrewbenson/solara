import type { BookmarkDraft } from "../store/bookmarks";
import { useBrowser, type BrowserState } from "../store/browser";
import { bookmarkDraft, hasLinks, MAX_DRAFT_LINKS, withDraftGroups, type DraftGroups, type GroupDraft } from "../store/draftGroups";
import { bookmarkProfileId, plural } from "../store/model";
import { mainWindowFor } from "../store/small";
import { encodeCommand } from "@solara/store";
import { nativeOwnsWorkspace, nativeWrite } from "../store/nativeStore";
import { groupLabel } from "../store/organize";
import type { TabGroup } from "../store/types";
import { reportBookmarkFailure, submitBookmarks, type BookmarkMutation } from "./bookmarkWriter";

export const ARC_HOLDER = " (Arc)";

function sidebarWindow(s: BrowserState, profileId: string, near?: string | null): string | undefined {
  const w = near ? s.windows[near] : undefined;
  if (w && !w.incognito && w.kind !== "small") return w.id;
  return mainWindowFor(s, profileId);
}

export function addGroupsFromDrafts(profileId: string, drafts: GroupDraft[], near?: string | null): DraftGroups {
  const s = useBrowser.getState();
  const windowId = sidebarWindow(s, profileId, near) ?? s.createWindow({ profileId });
  let result: DraftGroups;
  if (nativeOwnsWorkspace()) result = draftGroupsFromNative(nativeWrite(encodeCommand("openDraftGroups", [windowId, profileId, drafts]))?.result);
  else {
    const [next, made] = withDraftGroups(useBrowser.getState(), windowId, profileId, drafts);
    result = made;
    if (result.made.length) useBrowser.setState(next);
  }
  if (result.skipped) (require("../components/layout/splitActions") as typeof import("../components/layout/splitActions")).showToast(windowId, `${plural(result.skipped, "link")} left out`, `A folder brings up to ${MAX_DRAFT_LINKS.toLocaleString("en-US")} links.`);
  return result;
}

function draftGroupsFromNative(value: unknown): DraftGroups {
  const reply = (value ?? {}) as { made?: string[]; carried?: string[]; skipped?: number };
  return { made: reply.made ?? [], carried: new Set(reply.carried ?? []), skipped: reply.skipped ?? 0 };
}

export function profileOfWindow(windowId: string | null | undefined): string {
  const s = useBrowser.getState();
  return bookmarkProfileId(s, windowId ? s.windows[windowId] : undefined);
}

export function makesGroup(s: Pick<BrowserState, "bookmarks">, folderId: string): boolean {
  const draft = bookmarkDraft(s.bookmarks, folderId);
  return !!draft && hasLinks(draft);
}

export function addFolderToSidebar(folderId: string, windowId: string | null): string[] {
  const s = useBrowser.getState();
  const draft = bookmarkDraft(s.bookmarks, folderId);
  return draft ? addGroupsFromDrafts(profileOfWindow(windowId), [draft], windowId).made : [];
}

function holderProfile(s: Pick<BrowserState, "bookmarks">, folderId: string, prefer?: string): string | undefined {
  const node = s.bookmarks.nodes[folderId];
  if (node?.kind !== "folder" || !node.title.endsWith(ARC_HOLDER) || !node.parentId) return undefined;
  const owners = Object.keys(s.bookmarks.roots).filter((p) => s.bookmarks.roots[p]!.bar === node.parentId);
  return prefer && owners.includes(prefer) ? prefer : owners[0];
}

export function restorableArcHolder(s: Pick<BrowserState, "bookmarks">, folderId: string): boolean {
  const node = s.bookmarks.nodes[folderId];
  return !!holderProfile(s, folderId) && node?.kind === "folder" && node.children.some((id) => makesGroup(s, id));
}

export const allArcHolders = (s: Pick<BrowserState, "bookmarks">) => [...new Set(Object.keys(s.bookmarks.roots).flatMap((p) => arcHolders(s, p)))];

export function arcHolders(s: Pick<BrowserState, "bookmarks">, profileId: string): string[] {
  const bar = s.bookmarks.roots[profileId]?.bar;
  const root = bar ? s.bookmarks.nodes[bar] : undefined;
  return root?.kind === "folder" ? root.children.filter((id) => restorableArcHolder(s, id)) : [];
}

function carriedOver(b: BrowserState["bookmarks"], id: string, carried: Set<string>): { whole: boolean; ids: string[] } {
  const node = b.nodes[id];
  if (!node) return { whole: false, ids: [] };
  if (node.kind === "url") return carried.has(id) ? { whole: true, ids: [id] } : { whole: false, ids: [] };
  const parts = node.children.map((c) => carriedOver(b, c, carried));
  return node.children.length && parts.every((p) => p.whole) ? { whole: true, ids: [id] } : { whole: false, ids: parts.flatMap((p) => p.ids) };
}

const restoringArc = new Map<string, Promise<void>>();
const unremovedArc = new Map<string, Map<string, string>>();

export function restoreArcFolders(holderId: string, windowId: string | null): string[] {
  return startArcRestore(holderId, windowId).made;
}

export async function restoreArcFoldersSettled(holderId: string, windowId: string | null): Promise<string[]> {
  const { made, settled } = startArcRestore(holderId, windowId);
  await settled;
  return made;
}

function startArcRestore(holderId: string, windowId: string | null): { made: string[]; settled: Promise<void> } {
  const pending = restoringArc.get(holderId);
  if (pending) return { made: [], settled: pending };
  const s = useBrowser.getState();
  const owner = holderProfile(s, holderId, windowId ? profileOfWindow(windowId) : undefined);
  if (!owner) return { made: [], settled: Promise.resolve() };
  const profileId = s.profiles[owner] ? owner : profileOfWindow(windowId);
  const holder = s.bookmarks.nodes[holderId];
  const folders = holder?.kind === "folder" ? holder.children.filter((id) => makesGroup(s, id)) : [];
  const near = windowId && s.windows[windowId]?.profileId === profileId ? windowId : null;
  const { made, carried } = addGroupsFromDrafts(profileId, folders.map((id) => bookmarkDraft(s.bookmarks, id)!), near);
  const b = useBrowser.getState().bookmarks;
  const urlOf = (id: string) => {
    const node = b.nodes[id];
    return node?.kind === "url" ? node.url : undefined;
  };
  const filed = new Map<string, string>([...(unremovedArc.get(holderId) ?? [])].filter(([id, url]) => urlOf(id) === url));
  for (const id of carried) if (urlOf(id) !== undefined) filed.set(id, urlOf(id)!);
  const ids = folders.flatMap((id) => carriedOver(b, id, new Set(filed.keys())).ids);
  const removing = new Set(ids);
  const left = b.nodes[holderId];
  const emptied = left?.kind === "folder" && left.children.every((id) => removing.has(id));
  const edits: BookmarkMutation[] = [...(ids.length ? [{ method: "removeBookmarks" as const, args: [ids] }] : []), ...(emptied ? [{ method: "removeBookmark" as const, args: [holderId] }] : [])];
  if (!edits.length) return { made, settled: Promise.resolve() };
  const settled = submitBookmarks(owner, edits)
    .then(
      () => void unremovedArc.delete(holderId),
      (error: unknown) => {
        unremovedArc.set(holderId, filed);
        reportBookmarkFailure(error);
      },
    )
    .finally(() => restoringArc.delete(holderId));
  restoringArc.set(holderId, settled);
  return { made, settled };
}

const filingGroups = new Set<string>();

export async function moveGroupToBookmarksBar(groupId: string): Promise<void> {
  const s = useBrowser.getState();
  const g = s.groups[groupId];
  if (!g || filingGroups.has(groupId)) return;
  const profileId = bookmarkProfileId(s, s.windows[g.windowId]);
  const favicons: (string | null)[] = [];
  const draft = (group: TabGroup): BookmarkDraft => {
    const nested = Object.values(s.groups).filter((c) => c.parentId === group.id);
    const filed = new Set<string>();
    const children: BookmarkDraft[] = [];
    for (const id of group.tabIds) {
      const child = nested.find((c) => c.tabIds.includes(id));
      if (child) {
        if (!filed.has(child.id)) {
          filed.add(child.id);
          children.push(draft(child));
        }
        continue;
      }
      const t = s.tabs[id];
      if (!t?.url) continue;
      children.push({ title: t.customTitle || t.title || t.url, url: t.url });
      favicons.push(t.favicon ?? null);
    }
    return { title: groupLabel(s, group), children };
  };
  const tree = draft(g);
  const members = groupMembers(s, groupId);
  filingGroups.add(groupId);
  try {
    const [made] = (await submitBookmarks(profileId, [{ method: "addBookmarkTree", args: [profileId, [tree]] }])) as [string[] | undefined];
    const now = useBrowser.getState();
    if (now.groups[groupId] && groupMembers(now, groupId) === members) now.closeGroup(groupId);
    const links = linksIn(useBrowser.getState().bookmarks, made?.[0]);
    const icons: BookmarkMutation[] = links.flatMap((id, i) => (favicons[i] ? [{ method: "updateBookmark" as const, args: [id, { favicon: favicons[i] }] }] : []));
    if (icons.length) void submitBookmarks(profileId, icons).catch(reportBookmarkFailure);
  } finally {
    filingGroups.delete(groupId);
  }
}

function groupMembers(s: BrowserState, groupId: string): string {
  const walk = (id: string): unknown[] => {
    const group = s.groups[id];
    if (!group) return [];
    const nested = Object.values(s.groups).filter((c) => c.parentId === id).map((c) => [c.id, walk(c.id)]);
    return [group.tabIds.map((t) => [t, s.tabs[t]?.url ?? null]), nested];
  };
  return JSON.stringify(walk(groupId));
}

function linksIn(b: BrowserState["bookmarks"], id: string | undefined): string[] {
  const node = id ? b.nodes[id] : undefined;
  if (!node) return [];
  return node.kind === "url" ? [node.id] : node.children.flatMap((c) => linksIn(b, c));
}
