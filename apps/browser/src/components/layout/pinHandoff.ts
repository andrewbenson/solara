import { nativeWorkspaceCommand } from "@solara/settings";
import { setPinHandoff } from "../../store/tabs";

export const requestPinHandOff = (tabId: string) => nativeWorkspaceCommand("handOffPin", JSON.stringify({ tabId }), null);
export function startPinHandoff() {
  setPinHandoff((tabId) => { requestPinHandOff(tabId); });
}
