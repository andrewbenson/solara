import { cleanUrl } from "@solara/core";
import { makesGroup, restorableArcHolder } from "../../lib/bookmarkGroups";
import type { Theme } from "../../lib/theme";
import { folderLinks } from "../../store/bookmarks";
import type { Settings } from "../../store/settings";
import type { BookmarkNode, Bookmarks } from "../../store/types";

type BarTheme = Pick<Theme, "toolbarHover" | "toolbarPressed" | "textTab" | "textTertiary" | "icon" | "divider" | "accent" | "dark">;

export type BookmarksBarItem = {
  id: string;
  kind: "url" | "folder";
  title: string;
  url?: string;
  cleanUrl?: string;
  favicon?: string | null;
  children?: BookmarksBarItem[];
  folderLinks?: number;
  makesGroup?: boolean;
  restorableArcHolder?: boolean;
};

export function bookmarksBarSnapshot(bookmarks: Bookmarks, profileId: string, hideBookmarksBarImport: boolean, theme: BarTheme, sidebarEdge: number | null = null, bookmarksBar: Settings["bookmarksBar"] = "always") {
  const roots = bookmarks.roots[profileId];
  const bar = roots ? bookmarks.nodes[roots.bar] : undefined;
  const other = roots ? bookmarks.nodes[roots.other] : undefined;
  const state = { bookmarks };
  const build = (node: BookmarkNode, depth: number): BookmarksBarItem => node.kind === "url"
    ? { id: node.id, kind: node.kind, title: node.title, url: node.url, cleanUrl: cleanUrl(node.url), favicon: node.favicon }
    : {
      id: node.id,
      kind: node.kind,
      title: node.title,
      children: depth < 8 ? children(node.children, depth + 1) : [],
      folderLinks: folderLinks(bookmarks, node.id).length,
      makesGroup: makesGroup(state, node.id),
      restorableArcHolder: restorableArcHolder(state, node.id),
    };
  const children = (ids: string[], depth: number): BookmarksBarItem[] => ids.flatMap((id) => {
    const node = bookmarks.nodes[id];
    return node ? [build(node, depth)] : [];
  });
  return {
    profileId,
    barId: roots?.bar ?? null,
    bookmarksBar,
    items: bar?.kind === "folder" ? children(bar.children, -1) : [],
    otherId: roots?.other ?? null,
    otherFolder: other?.kind === "folder" ? build(other, -1) : null,
    hasOther: other?.kind === "folder" && other.children.length > 0,
    hideBookmarksBarImport,
    sidebarEdge,
    theme: {
      toolbarHover: theme.toolbarHover,
      toolbarPressed: theme.toolbarPressed,
      textTab: theme.textTab,
      textTertiary: theme.textTertiary,
      icon: theme.icon,
      divider: theme.divider,
      accent: theme.accent,
    },
    dark: theme.dark,
  };
}
