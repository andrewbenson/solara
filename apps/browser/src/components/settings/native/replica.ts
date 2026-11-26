import { type SettingsHandler } from "@solara/settings";
import { adoptFaviconCache } from "../../../lib/favicons";
import { adoptProfileThemeForImport } from "../../../sync/engine";
import { useBrowser } from "../../../store/browser";

export const replicaHandlers: Record<string, SettingsHandler> = {
  "import.adoptProfileTheme": (profileId: string) => adoptProfileThemeForImport(profileId),
  "replica.adoptHistory": (profileId: string, rows: { url: string; title: string; visits: number; lastVisit: number }[]) => {
    const before = useBrowser.getState().history[profileId]?.length ?? 0;
    useBrowser.getState().adoptImportedHistory(profileId, Array.isArray(rows) ? rows : []);
    return (useBrowser.getState().history[profileId]?.length ?? 0) - before;
  },
  "replica.adoptFavicons": (profileId: string, favicons: { page: string; icon: string; png: string }[]) => {
    adoptFaviconCache(profileId, Array.isArray(favicons) ? favicons : []);
    return true;
  },
};
