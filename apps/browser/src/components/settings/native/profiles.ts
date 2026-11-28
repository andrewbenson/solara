import { clearBrowsingData, type BrowsingDataType } from "@solara/solaracore";
import { publishSettingsTopic, type SettingsHandler } from "@solara/settings";
import { useBrowser, type BrowserState } from "../../../store/browser";
import { refuseSafeHistoryDeletion } from "../../../store/safeLibraryEdits";
import { adoptProfileTheme } from "../../../sync/engine";

export const profilesHandlers: Record<string, SettingsHandler> = {
  "profiles.clearHistory": (profileId: string, since: number | null) => useBrowser.getState().clearHistory(profileId, since ?? undefined),
  "profiles.clearBrowsingData": (profile: string, kinds: BrowsingDataType[], since: number | null) => {
    if (kinds.includes("history") && refuseSafeHistoryDeletion(profile, undefined, since ?? undefined)) throw new Error("History deletion is unavailable until the legacy file has migrated in a normal launch.");
    return clearBrowsingData(profile, kinds, since ?? undefined);
  },
  "profiles.adoptTheme": (id: string) => adoptProfileTheme(id),
};

function statsTopic(s: BrowserState) {
  return Object.fromEntries(s.profileOrder.map((id) => [id, { historyPages: (s.history[id] ?? []).length }]));
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
    if (s.history !== prev.history || s.profileOrder !== prev.profileOrder) publishStats(s);
  });
}
