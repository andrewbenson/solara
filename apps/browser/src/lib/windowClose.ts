import { confirm, onWindowEvent, retainLastWindow } from "@solara/shell";
import { useBrowser } from "../store/browser";
import { nativeOwnsWorkspace } from "../store/nativeStore";
import { tabsClosingWithWindow } from "../store/model";
import { closeWindowDialog } from "./closeWindowDialog";
import { closeWindowAnimated } from "./closeAnimated";

const MIN_TABS = 2;

export function startWindowCloseGuard() {
  const pending = new Set<string>();
  onWindowEvent((e) => {
    if (e.type !== "closeRequest" || nativeOwnsWorkspace() || pending.has(e.id)) return;
    pending.add(e.id);
    void requestClose(e.id).finally(() => pending.delete(e.id));
  });
}

export async function requestClose(windowId: string) {
  const s = useBrowser.getState();
  const w = s.windows[windowId];
  if (!w) return;
  if (await retainLastWindow(windowId)) return;
  if (!useBrowser.getState().windows[windowId]) return;
  const count = closingTabs(windowId).length;
  if (s.settings.warnBeforeClosingWindow && count >= MIN_TABS) {
    const { confirmed, suppressed } = await confirm({ ...closeWindowDialog(windowId), suppression: "Don’t ask me again", windowId });
    if (suppressed) useBrowser.getState().updateSettings({ warnBeforeClosingWindow: false });
    if (!confirmed) return;
  }
  if (await retainLastWindow(windowId, true)) return;
  closeWindowAnimated(windowId);
}

const closingTabs = (windowId: string) => tabsClosingWithWindow(useBrowser.getState(), windowId);
