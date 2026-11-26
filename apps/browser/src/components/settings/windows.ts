import { openWindow } from "@solara/shell";
import { navigateNativeSettings, setNativePreferredImportSource } from "@solara/settings";

export const SETTINGS_WINDOW_ID = "settings";
export const IMPORT_WINDOW_ID = "import";

export const isUtilityWindowId = (id: string | null | undefined) =>
  id === SETTINGS_WINDOW_ID || id === IMPORT_WINDOW_ID;

export type SettingsPane =
  | "general"
  | "profiles"
  | "sync"
  | "tabs"
  | "appearance"
  | "privacy"
  | "passwords"
  | "autofill"
  | "extensions"
  | "search"
  | "engines"
  | "shortcuts"
  | "liveFolders"
  | "calendar"
  | "advanced";

export function openSettings(pane?: SettingsPane, profileId?: string | null, detail?: string | null) {
  if (pane) void navigateNativeSettings(pane, profileId ?? null, detail ?? null);
  void openWindow(SETTINGS_WINDOW_ID, { kind: "settings", title: "Settings" });
}

export function openImport(browserId?: string) {
  setNativePreferredImportSource(browserId ?? null);
  void openWindow(IMPORT_WINDOW_ID, { kind: "import", title: "Import from Another Browser" });
}
