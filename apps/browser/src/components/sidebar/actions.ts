import { cleanUrl, markdownLink } from "@solara/core";
import { copyText, prompt } from "@solara/shell";
import { bookmarkWriter, reportBookmarkFailure, submitBookmarks } from "../../lib/bookmarkWriter";
import { updateFolder } from "../../live/store";
import { useBrowser } from "../../store/browser";
import { ancestorIds } from "../../store/groups";
import { activeTabId, bookmarkProfileId, inPinnedContainer, pinSection, tabLayoutOf, viewTabIds } from "../../store/model";
import type { ClickMods } from "../../store/drops";
import { groupLabel, groupOf, selectedTabIds } from "../../store/organize";
import type { Tab } from "../../store/types";
import { measureRow, setSidebarUi, sidebarUi, type Target } from "./state";

const store = () => useBrowser.getState();

export function clickTab(windowId: string, tabId: string, mods: ClickMods = {}) {
  store().clickTab(windowId, tabId, mods);
}

export async function startRename(windowId: string, target: Target) {
  const s = store();
  if (target.kind === "tab") {
    const tab = s.tabs[target.id];
    if (!tab) return;
    if (tab.pinned && !tab.pinnedAsRow) {
      const name = await prompt({
        title: "Rename Tab",
        value: tab.customTitle ?? tab.title,
        placeholder: tab.title || "Tab name",
        confirmTitle: "Update",
        windowId,
      });
      if (name !== null) store().updateTab(tab.id, { customTitle: name });
      return;
    }
    const group = groupOf(s, tab.id);
    if (group && activeTabId(s, windowId) !== tab.id) {
      for (const id of [group.id, ...ancestorIds(s.groups, group.id)]) if (s.groups[id]!.collapsed) s.updateGroup(id, { collapsed: false });
    }
  }
  if (target.kind === "group" && !sidebarShows(windowId)) return renameGroupInSheet(windowId, target.id);
  setSidebarUi({ renaming: { windowId, ...target } });
}

const sidebarShows = (windowId: string) => tabLayoutOf(store(), windowId) === "sidebar" && !!store().windows[windowId]?.sidebarOpen;

async function renameGroupInSheet(windowId: string, groupId: string) {
  const g = store().groups[groupId];
  if (!g) return;
  const name = await prompt({
    title: "Rename Group",
    value: g.name,
    placeholder: groupLabel(store(), g),
    confirmTitle: "Update",
    windowId,
  });
  if (name !== null && store().groups[groupId]) store().updateGroup(groupId, { name: name.trim() });
}

export function commitRename(target: Target, text: string) {
  const name = text.trim();
  if (target.kind === "tab") {
    const tab = store().tabs[target.id];
    if (tab) store().updateTab(tab.id, { customTitle: name && name !== tab.title ? name : null });
  } else store().updateGroup(target.id, { name });
  endRename(target);
}

export function endRename(target: Target) {
  const r = sidebarUi().renaming;
  if (r && r.id === target.id) setSidebarUi({ renaming: null });
}

export async function openIconPicker(windowId: string, target: Target) {
  const anchor = await measureRow(windowId, target.id);
  setSidebarUi({ iconPicker: { windowId, ...target, anchor }, hover: null });
}

export function setIcon(target: Target, icon: string | null) {
  if (target.kind === "tab") store().updateTab(target.id, { customIcon: icon });
  else if (target.kind === "live") updateFolder(target.id.split("|")[1] ?? "", { icon });
  else store().updateGroup(target.id, { icon });
}

export function newGroupWithSelection(windowId: string, ids = selectedTabIds(store(), windowId)) {
  const groupId = store().groupTabs(ids.filter((id) => pinSection(store().tabs[id]) !== "tile"));
  if (groupId && sidebarShows(windowId)) void startRename(windowId, { kind: "group", id: groupId });
  return groupId;
}

const urlLabel = (url: string) => url.replace(/^[a-z][\w+.-]*:\/\//i, "").replace(/^www\./, "").replace(/\/$/, "");
export const tabTitle = (t: Pick<Tab, "customTitle" | "title" | "url">) => t.customTitle || t.title || (t.url && urlLabel(t.url)) || "New Tab";

export function copyUrls(ids: string[], markdown: boolean) {
  const tabs = ids.map((id) => store().tabs[id]).filter((t): t is Tab => !!t?.url);
  if (!tabs.length) return;
  const lines = tabs.map((t) => (markdown ? markdownLink(tabTitle(t), t.url) : cleanUrl(t.url)));
  copyText(markdown && lines.length > 1 ? lines.map((l) => `- ${l}`).join("\n") : lines.join("\n"));
}

export async function bookmarkTabs(windowId: string, ids: string[], folder: string | "bar" | "new") {
  const s = store();
  const profileId = bookmarkProfileId(s, s.windows[windowId]);
  let parentId: string | undefined = folder === "bar" ? undefined : folder;
  if (folder === "new") {
    const title = await prompt({ title: "New Folder", placeholder: "Folder name", confirmTitle: "Create", windowId });
    if (!title) return;
    try {
      parentId = await bookmarkWriter.addBookmarkFolder({ profileId, title });
    } catch (error) {
      return reportBookmarkFailure(error);
    }
  }
  const pages = ids.map((id) => store().tabs[id]).filter((t): t is Tab => !!t?.url);
  if (pages.length) await submitBookmarks(profileId, pages.map((t) => ({ method: "addBookmark", args: [{ profileId, url: t.url, title: tabTitle(t), favicon: t.favicon, parentId }] }))).catch(reportBookmarkFailure);
}

export async function editPinnedPage(windowId: string, tabId: string) {
  const tab = store().tabs[tabId];
  if (!tab || !inPinnedContainer(store(), tabId)) return;
  const url = await prompt({
    title: "Edit Pinned Page",
    value: tab.pinnedUrl ?? tab.url,
    placeholder: "Enter Pinned URL",
    confirmTitle: "Save",
    windowId,
  });
  if (url) store().setPinnedUrl(tabId, url.includes("://") ? url : `https://${url}`);
}

export function muteAll(windowId: string, muted: boolean) {
  store().setMuted(viewTabIds(store(), windowId), muted);
}

export const allMuted = (windowId: string) => {
  const s = store();
  const view = viewTabIds(s, windowId).filter((id) => s.tabs[id]!.url);
  return view.length > 0 && view.every((id) => s.tabs[id]!.muted);
};
