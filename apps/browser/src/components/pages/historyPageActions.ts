import { finishNativeHistoryAction, nativeHistoryActionCurrent, onNativeHistoryAction, type NativeHistoryAction } from "@solara/settings";
import { confirm } from "@solara/shell";
import { useBrowser } from "../../store/browser";
import { clearDataFor, type ClearRange } from "./ClearDataDialog";

export function startHistoryPageActions() {
  onNativeHistoryAction((event) => {
    void handle(event).catch((error) => console.warn("[history] page action failed", error));
  });
}

async function handle(event: NativeHistoryAction) {
  const { token, profileId, windowId } = event;
  if (!await nativeHistoryActionCurrent(token)) return;
  switch (event.kind) {
    case "remove":
      useBrowser.getState().removeHistory(profileId, event.urls);
      return;
    case "deleteSelected": {
      const { confirmed } = await confirm({
        title: "Remove selected items?",
        message: "Are you sure you want to delete these pages from your history?",
        confirmTitle: "Remove",
        destructive: true,
        windowId,
      });
      if (!confirmed || !await nativeHistoryActionCurrent(token)) return;
      useBrowser.getState().removeHistory(profileId, event.urls);
      await finishNativeHistoryAction(token, "selection");
      return;
    }
    case "clearData":
      try {
        await clearDataFor(profileId, event.range as ClearRange, event.history, event.siteData);
        await finishNativeHistoryAction(token, "clear");
      } catch (error) {
        await finishNativeHistoryAction(token, "clearFailed");
        throw error;
      }
  }
}
