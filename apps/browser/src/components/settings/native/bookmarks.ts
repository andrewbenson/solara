import { confirm } from "@solara/shell";
import { type SettingsHandler } from "@solara/settings";
import { allArcHolders, restoreArcFoldersSettled } from "../../../lib/bookmarkGroups";
import { nativeSafeMode } from "../../../store/nativeStore";
import { useBrowser } from "../../../store/browser";

const restorations = new Set<Promise<unknown>>();
let drains = 0;

export const bookmarkRestorationHandlers: Record<string, SettingsHandler> = {
  "bookmarks.drainRestoration": async () => {
    drains++;
    try { await Promise.allSettled([...restorations]); return true; }
    finally { drains--; }
  },
  "bookmarks.arcHolders": () => allArcHolders(useBrowser.getState()).length,
  "bookmarks.restoreArcFolders": async () => {
    if (drains > 0) return allArcHolders(useBrowser.getState()).length;
    if (nativeSafeMode()) {
      void confirm({ title: "Safe Mode", message: "Imported tabs, spaces, pinned tabs and new profiles cannot be saved in safe mode. Open Solara normally to import them.", confirmTitle: "OK" });
      return allArcHolders(useBrowser.getState()).length;
    }
    const pending = Promise.all(allArcHolders(useBrowser.getState()).map((id) => restoreArcFoldersSettled(id, null)));
    restorations.add(pending);
    try { await pending; } finally { restorations.delete(pending); }
    return allArcHolders(useBrowser.getState()).length;
  },
};
