import { publishSettingsTopic } from "@solara/settings";
import { closeTab } from "../../lib/actions";
import { manualRefresh, openLiveItem } from "../../live/engine";
import { live, setExpandedStack, setLive, updateFolder, useLive } from "../../live/store";
import { useBrowser } from "../../store/browser";
import { viewTabIds } from "../../store/model";
import { openSettings } from "../settings/windows";
import { openLiveFolderMenu, openLiveItemMenu, openLiveStackMenu } from "./liveMenus";

let published = false;

export function publishNativeLive(): void {
  if (published) return;
  published = true;
  const publish = (showAll: Record<string, boolean>) => publishSettingsTopic("sidebar.liveShowAll", showAll);
  publish(useLive.getState().showAll);
  useLive.subscribe((s, prev) => {
    if (s.showAll !== prev.showAll) publish(s.showAll);
  });
}

export function runNativeLive(windowId: string, folderId: string, action: string, itemId: string | null, meta: boolean) {
  const s = live();
  const folder = s.folders[folderId];
  if (!folder) return;
  const item = itemId ? (s.items[folderId]?.find((i) => i.id === itemId) ?? null) : null;
  switch (action) {
    case "toggle":
      return updateFolder(folderId, { collapsed: !folder.collapsed });
    case "refresh":
      return void manualRefresh(folderId);
    case "settings":
      return void openSettings("liveFolders");
    case "folderMenu":
      return void openLiveFolderMenu(windowId, folderId);
    case "open":
      return item ? openLiveItem(windowId, folderId, item, { background: meta }) : undefined;
    case "itemMenu":
      return item ? void openLiveItemMenu(windowId, folderId, item, itemId ? liveTab(windowId, folder.profileId, folderId, itemId) : null) : undefined;
    case "close":
      return itemId ? void closeTab(itemId) : undefined;
    case "stack":
      return itemId ? setExpandedStack(itemId, s.expandedStacks[itemId] === false) : undefined;
    case "stackMenu":
      return itemId ? void openLiveStackMenu(folderId, itemId) : undefined;
    case "more":
      return itemId ? setLive((l) => ({ showAll: { ...l.showAll, [`${folderId}:${itemId}`]: true } })) : undefined;
    case "openCompleted": {
      const done = s.completed[folderId]?.find((c) => c.item.id === itemId);
      return done ? openLiveItem(windowId, folderId, done.item) : undefined;
    }
  }
}

function liveTab(windowId: string, profileId: string, folderId: string, itemId: string): string | null {
  const b = useBrowser.getState();
  return viewTabIds(b, windowId, profileId).find((id) => b.tabs[id]?.liveItem?.itemId === itemId && b.tabs[id]?.liveItem?.folderId === folderId) ?? null;
}
