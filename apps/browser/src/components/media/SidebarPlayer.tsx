import { switchToTab } from "../../lib/actions";
import { addMediaActions, runPlayerAction } from "./nativeMedia";

addMediaActions({ sidebarPlayer: (_windowId, tabId, extra) => runPlayerAction(tabId, extra, () => switchToTab(tabId)) });
