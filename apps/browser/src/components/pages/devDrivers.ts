import { openImport, openSettings } from "../settings/windows";
import { useMeetingAlert } from "../../live/alerts";
import { useCalendar } from "../../live/calendar";
import { measureRow, setSidebarUi } from "../sidebar/state";
import { useFolderPanel } from "../sidebar/tileFolderUi";
import { nativeWrite } from "../../store/nativeStore";
import { encodeCommand } from "@solara/store";
import { openInternalPage } from "./urls";

const makeTileFolder = (ids: string[]) => (nativeWrite(encodeCommand("newTileFolder", [ids]))?.result as string | undefined) ?? null;

export const pagesDrivers = {
  openInternalPage,
  openSettings,
  openImport,
  meetingAlert: useMeetingAlert,
  calendar: useCalendar,
  setSidebarUi,
  tileFolders: { make: makeTileFolder, panel: useFolderPanel, measure: measureRow },
};
