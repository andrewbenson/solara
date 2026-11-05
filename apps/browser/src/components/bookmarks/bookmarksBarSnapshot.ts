import type { Theme } from "../../lib/theme";
import type { Bookmarks } from "../../store/types";

type BarTheme = Pick<Theme, "toolbarHover" | "toolbarPressed" | "textTab" | "textTertiary" | "icon" | "divider" | "dark">;

export type BookmarksBarItem = {
  id: string;
  kind: "url" | "folder";
  title: string;
  url?: string;
  favicon?: string | null;
};

export function bookmarksBarSnapshot(bookmarks: Bookmarks, profileId: string, hideBookmarksBarImport: boolean, theme: BarTheme) {
  const roots = bookmarks.roots[profileId];
  const bar = roots ? bookmarks.nodes[roots.bar] : undefined;
  const other = roots ? bookmarks.nodes[roots.other] : undefined;
  const items: BookmarksBarItem[] = [];
  if (bar?.kind === "folder") {
    for (const id of bar.children) {
      const node = bookmarks.nodes[id];
      if (!node) continue;
      items.push(node.kind === "url"
        ? { id: node.id, kind: node.kind, title: node.title, url: node.url, favicon: node.favicon }
        : { id: node.id, kind: node.kind, title: node.title });
    }
  }
  return {
    profileId,
    items,
    otherId: roots?.other ?? null,
    hasOther: other?.kind === "folder" && other.children.length > 0,
    hideBookmarksBarImport,
    theme: {
      toolbarHover: theme.toolbarHover,
      toolbarPressed: theme.toolbarPressed,
      textTab: theme.textTab,
      textTertiary: theme.textTertiary,
      icon: theme.icon,
      divider: theme.divider,
    },
    dark: theme.dark,
  };
}
