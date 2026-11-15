import { menuShown, watchMenus } from "@solara/shell";
import { useBrowser } from "../../store/browser";
import { activeTabId } from "../../store/model";
import { pointerOnCard, watchPointerOnCard } from "../sidebar/hover";
import { sidebarUi, useSidebarUi } from "../sidebar/state";
import { usePages } from "./pageState";
import { addressBarInSidebar } from "./windowLayout";

export function peekHeld(windowId: string, nativeLayout = false): boolean {
  if (!nativeLayout && menuShown()) return true;
  const ui = sidebarUi();
  if (ui.renaming?.windowId === windowId || ui.iconPicker?.windowId === windowId) return true;
  if (ui.hover?.windowId === windowId && pointerOnCard()) return true;
  const s = useBrowser.getState();
  if (!nativeLayout && s.windowUi[windowId]?.downloadsOpen) return true;
  const tabId = addressBarInSidebar(s, windowId) ? activeTabId(s, windowId) : undefined;
  return !!tabId && !!usePages.getState().popover[tabId];
}

export function watchPeekHolds(changed: () => void): () => void {
  const stops = [watchMenus(changed), watchPointerOnCard(changed), useSidebarUi.subscribe(changed), useBrowser.subscribe(changed), usePages.subscribe(changed)];
  return () => stops.forEach((stop) => stop());
}

export function followPeekHold(windowId: string, floating: boolean, set: (held: boolean) => void, nativeLayout = false): () => void {
  set(floating && peekHeld(windowId, nativeLayout));
  return floating ? watchPeekHolds(() => set(peekHeld(windowId, nativeLayout))) : () => {};
}
