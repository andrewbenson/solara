import { installPendingUpdate, onPendingUpdate, pendingUpdate, type PendingUpdate } from "@solara/shell";
import { useEffect } from "react";
import { create } from "zustand";
import { PRODUCT } from "./productName";

export const UPDATE_PILL_TEXT = `New ${PRODUCT} Version Available`;
export const UPDATE_PILL_SHORT_TEXT = "Update";
export const UPDATE_PILL_HEIGHT = 30;
export const UPDATE_PILL_BAND = UPDATE_PILL_HEIGHT + 8;

const usePendingUpdateStore = create<{ update: PendingUpdate | null }>(() => ({ update: null }));

let watching = false;

export function watchPendingUpdate() {
  if (watching) return;
  watching = true;
  let heard = false;
  onPendingUpdate((update) => {
    heard = true;
    usePendingUpdateStore.setState({ update });
  });
  void pendingUpdate()
    .then((update) => heard || usePendingUpdateStore.setState({ update: update ?? null }))
    .catch(() => undefined);
}

export function usePendingUpdate(): PendingUpdate | null {
  useEffect(watchPendingUpdate, []);
  return usePendingUpdateStore((s) => s.update);
}

export const pendingUpdateNow = () => usePendingUpdateStore.getState().update;

export const installUpdateNow = () => void installPendingUpdate().catch(() => undefined);

export function updatePillTooltip(update: PendingUpdate): string {
  return `Restart to update ${PRODUCT} to ${update.version}. Your windows and tabs reopen as they are.`;
}
