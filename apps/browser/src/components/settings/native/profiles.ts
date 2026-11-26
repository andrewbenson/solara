import { clearBrowsingData, listExtensions, type BrowsingDataType } from "@solara/solaracore";
import { publishSettingsTopic, type SettingsHandler } from "@solara/settings";
import { pruneProfileFavicons } from "../../../lib/favicons";
import { useBrowser, type BrowserState } from "../../../store/browser";
import { refuseSafeHistoryDeletion } from "../../../store/safeLibraryEdits";
import { adoptProfileTheme } from "../../../sync/engine";

export const profilesHandlers: Record<string, SettingsHandler> = {
  "profiles.delete": (id: string) => useBrowser.getState().deleteProfile(id),
  "profiles.clearHistory": (profileId: string, since: number | null) => useBrowser.getState().clearHistory(profileId, since ?? undefined),
  "profiles.pruneFavicons": (profileId: string) => pruneProfileFavicons(profileId),
  "profiles.clearBrowsingData": (profile: string, kinds: BrowsingDataType[], since: number | null) => {
    if (kinds.includes("history") && refuseSafeHistoryDeletion(profile, undefined, since ?? undefined)) throw new Error("History deletion is unavailable until the legacy file has migrated in a normal launch.");
    return clearBrowsingData(profile, kinds, since ?? undefined);
  },
  "profiles.extensionsKeptOnDelete": () =>
    listExtensions("").then(
      (list) => list.filter((e) => e.mayModify).map((e) => e.name),
      () => null,
    ),
  "profiles.adoptTheme": (id: string) => adoptProfileTheme(id),
};

const bookmarkCounts = new WeakMap<BrowserState["bookmarks"], Map<string, number>>();

function bookmarkCount(s: BrowserState, profileId: string): number {
  let byRoot = bookmarkCounts.get(s.bookmarks);
  if (!byRoot) bookmarkCounts.set(s.bookmarks, (byRoot = new Map()));
  const roots = s.bookmarks.roots[profileId];
  if (!roots) return 0;
  const key = `${roots.bar}:${roots.other}`;
  const known = byRoot.get(key);
  if (known !== undefined) return known;
  let count = 0;
  const walk = (id: string) => {
    const n = s.bookmarks.nodes[id];
    if (n?.kind === "url") count++;
    if (n?.kind === "folder") n.children.forEach(walk);
  };
  [roots.bar, roots.other].forEach(walk);
  byRoot.set(key, count);
  return count;
}

function statsTopic(s: BrowserState) {
  return Object.fromEntries(s.profileOrder.map((id) => [id, { historyPages: (s.history[id] ?? []).length, bookmarks: bookmarkCount(s, id) }]));
}

export function publishProfiles(): void {
  let lastStats = "";
  const publishStats = (s: BrowserState) => {
    const stats = statsTopic(s);
    const json = JSON.stringify(stats);
    if (json === lastStats) return;
    lastStats = json;
    publishSettingsTopic("profiles.stats", stats);
  };
  const initial = useBrowser.getState();
  publishSettingsTopic("profiles.appDark", initial.ui.appDark);
  publishStats(initial);
  useBrowser.subscribe((s, prev) => {
    if (s.ui.appDark !== prev.ui.appDark) publishSettingsTopic("profiles.appDark", s.ui.appDark);
    if (s.history !== prev.history || s.bookmarks !== prev.bookmarks || s.profileOrder !== prev.profileOrder) publishStats(s);
  });
}
