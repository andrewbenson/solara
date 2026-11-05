import { focusPageIfUnclaimed, hostedKinds, onHostedEvent, SolaraHostedView } from "@solara/settings";
import { memo, useEffect } from "react";
import { View } from "react-native";
import { addFolderToSidebar } from "../../lib/bookmarkGroups";
import { useTheme } from "../../lib/theme";
import { folderChildren } from "../../store/bookmarks";
import { useBrowser } from "../../store/browser";
import { useWindowId } from "../../store/hooks";
import { bookmarkProfileId } from "../../store/model";
import { shownPageId } from "../../store/peek";
import { openImport } from "../settings/windows";
import { useSidebarWidth } from "../sidebar/tokens";
import { openModeFor, openUrl } from "./actions";
import { BOOKMARKS_BAR_HEIGHT, BookmarksBar, handleBookmarksBarMenuChoice } from "./BookmarksBar";
import { bookmarksBarSnapshot } from "./bookmarksBarSnapshot";
import { dropBookmarksBarLinks } from "./bookmarksBarDrop";

export const NativeBookmarksBar = memo(function NativeBookmarksBar({ placeholder }: { placeholder?: boolean }) {
  const windowId = useWindowId();
  if (!hostedKinds().includes("bookmarksBar")) return <BookmarksBar placeholder={placeholder} />;
  return placeholder ? <View style={{ height: BOOKMARKS_BAR_HEIGHT }} /> : <Bar windowId={windowId} />;
});

function Bar({ windowId }: { windowId: string }) {
  const theme = useTheme();
  const profileId = useBrowser((s) => bookmarkProfileId(s, s.windows[windowId]));
  const bookmarks = useBrowser((s) => s.bookmarks);
  const hideImport = useBrowser((s) => s.settings.hideBookmarksBarImport);
  const barMode = useBrowser((s) => s.settings.bookmarksBar);
  const width = useSidebarWidth(windowId);
  const sidebarEdge = useBrowser((s) => {
    const w = s.windows[windowId];
    return w?.sidebarOpen && (w.tabLayout ?? s.settings.tabLayout) !== "top" ? width : null;
  });
  const state = JSON.stringify(bookmarksBarSnapshot(bookmarks, profileId, hideImport, theme, sidebarEdge, barMode));
  useEffect(() => onHostedEvent("bookmarksBar", windowId, (name, payload) => {
    const s = useBrowser.getState();
    const window = s.windows[windowId];
    if (!window) return;
    const currentProfileId = bookmarkProfileId(s, window);
    if (payload.profileId !== undefined && payload.profileId !== currentProfileId) return;
    const roots = s.bookmarks.roots[currentProfileId];
    const children = roots ? folderChildren(s.bookmarks, roots.bar) : [];
    const node = typeof payload.id === "string" ? children.find((n) => n.id === payload.id) : undefined;
    if (name === "press" && node?.kind === "url") {
      openUrl(node.url, windowId, openModeFor({
        metaKey: payload.metaKey === true,
        shiftKey: payload.shiftKey === true,
        altKey: payload.altKey === true,
        middle: payload.middle === true,
      }));
    } else if (name === "move" && node && roots) {
      if (typeof payload.into === "string") {
        const target = children.find((n) => n.id === payload.into);
        if (target?.kind === "folder" && target.id !== node.id) s.moveBookmark(node.id, target.id);
      } else if (payload.into === undefined && typeof payload.index === "number" && Number.isInteger(payload.index) && payload.index >= 0 && payload.index < children.length) {
        s.moveBookmark(node.id, roots.bar, payload.index);
      }
    } else if (name === "dropLinks") {
      dropBookmarksBarLinks(s, currentProfileId, payload);
    } else if (name === "folderToSidebar" && node?.kind === "folder") {
      addFolderToSidebar(node.id, windowId);
    } else if (name === "menuChoice" && typeof payload.action === "string") {
      const id = typeof payload.id === "string" ? payload.id : undefined;
      if (id !== undefined && payload.action !== "bar") {
        const contains = (ids: string[], depth = 0): boolean => depth < 64 && ids.some((candidate) => {
          if (candidate === id) return true;
          const node = s.bookmarks.nodes[candidate];
          return node?.kind === "folder" && contains(node.children, depth + 1);
        });
        if (!roots || !s.bookmarks.nodes[id] || !contains([roots.bar, roots.other])) return;
      }
      void handleBookmarksBarMenuChoice(windowId, currentProfileId, payload.action, id);
    } else if (name === "focusPage") {
      const tabId = shownPageId(s, windowId);
      if (tabId) void focusPageIfUnclaimed(windowId, tabId);
    } else if (name === "importPress") openImport();
  }), [windowId]);
  return <SolaraHostedView kind="bookmarksBar" windowId={windowId} state={state} style={{ height: BOOKMARKS_BAR_HEIGHT }} />;
}
