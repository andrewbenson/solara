import type { BrowserCommand } from "@solara/shell";
import { tidyPins } from "./tidyPinsUi";

export function runSidebarCommand(command: BrowserCommand, _arg: string | null, windowId: string): boolean {
  if (command !== "tidyPins") return false;
  tidyPins(windowId);
  return true;
}
