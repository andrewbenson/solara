import { showMenu } from "@solara/shell";
import { openManageExtensions, openPinDialog, openWebStore } from "../extensions/state";

export async function addExtensionMenu(windowId: string, onClose: () => void) {
  const choice = await showMenu([
    { id: "add", title: "Add Extension…", symbol: "plus" },
    { id: "pin", title: "Pin Extensions…", symbol: "pin" },
    { id: "manage", title: "Manage Extensions…", symbol: "puzzlepiece.extension" },
  ]);
  if (!choice) return;
  onClose();
  if (choice === "add") openWebStore(windowId);
  if (choice === "pin") openPinDialog(windowId);
  if (choice === "manage") openManageExtensions(windowId);
}
