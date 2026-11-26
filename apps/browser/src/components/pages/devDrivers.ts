import { openImport, openSettings } from "../settings/windows";
import { useBookmarkDialog } from "../bookmarks/actions";
import { useBookmarkEditor } from "../bookmarks/edit";
import { useMeetingAlert } from "../../live/alerts";
import { useCalendar } from "../../live/calendar";
import { useEngineOffers } from "../../lib/engines";
import { measureRow, setSidebarUi } from "../sidebar/state";
import { useFolderPanel } from "../sidebar/tileFolderUi";
import { newTileFolder } from "../../store/tileFolders";
import { nativeOwnsWorkspace, nativeWrite } from "../../store/nativeStore";
import { useBrowser } from "../../store/browser";
import { encodeCommand } from "@solara/store";
import { useClearDataRequest } from "./ClearDataDialog";
import { openInternalPage } from "./urls";

const makeTileFolder = (ids: string[]) => {
  if (nativeOwnsWorkspace()) return (nativeWrite(encodeCommand("newTileFolder", [ids]))?.result as string | undefined) ?? null;
  const made = newTileFolder(useBrowser.getState(), ids);
  if (made.folderId) useBrowser.setState(made.state);
  return made.folderId;
};

export const pagesDrivers = {
  openInternalPage,
  openSettings,
  openImport,
  bookmarkDialog: useBookmarkDialog,
  bookmarkEditor: useBookmarkEditor,
  clearDataRequest: useClearDataRequest,
  meetingAlert: useMeetingAlert,
  calendar: useCalendar,
  engineOffers: useEngineOffers,
  setSidebarUi,
  tileFolders: { make: makeTileFolder, panel: useFolderPanel, measure: measureRow },
};
