import { type SettingsHandler } from "@solara/settings";
import { adoptProfileThemeForImport } from "../../../sync/engine";
import { useBrowser } from "../../../store/browser";

export const replicaHandlers: Record<string, SettingsHandler> = {
  "import.adoptProfileTheme": (profileId: string) => adoptProfileThemeForImport(profileId),
  "replica.adoptHistory": (profileId: string, rows: { url: string; title: string; visits: number; lastVisit: number }[]) => {
    const before = useBrowser.getState().history[profileId]?.length ?? 0;
    useBrowser.getState().adoptImportedHistory(profileId, Array.isArray(rows) ? rows : []);
    return (useBrowser.getState().history[profileId]?.length ?? 0) - before;
  },
};
