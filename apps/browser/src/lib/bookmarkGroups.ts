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

export function restorableArcHolder(s: Pick<BrowserState, "bookmarks">, folderId: string): boolean {
  const node = s.bookmarks.nodes[folderId];
  return node?.kind === "folder" && node.title.endsWith(" (Arc)") && !!node.parentId
    && Object.values(s.bookmarks.roots).some((roots) => roots.bar === node.parentId)
    && node.children.some((id) => makesGroup(s, id));
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
