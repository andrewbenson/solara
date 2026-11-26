import { focusWindow } from "@solara/shell";
import type { SettingsHandler } from "@solara/settings";
import { deleteLiveFolder } from "../../../live/engine";
import { connectGoogleDrive } from "../../../live/googleAuth";
import { useBrowser } from "../../../store/browser";

function browserWindow(): string | null {
  const s = useBrowser.getState();
  return s.ui.focusOrder.find((id) => s.windows[id] && !s.windows[id]!.incognito) ?? s.windowOrder.find((id) => !s.windows[id]!.incognito) ?? null;
}

export const liveHandlers: Record<string, SettingsHandler> = {
  "liveFolders.deleteFolder": (id: string) => deleteLiveFolder(id),
  "liveFolders.connectGoogleDrive": async (clientId: string, clientSecret: string) => {
    const windowId = browserWindow();
    if (!windowId) throw new Error("Open a browser window first");
    void focusWindow(windowId);
    await connectGoogleDrive(windowId, clientId, clientSecret);
  },
};
