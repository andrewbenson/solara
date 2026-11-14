import { publishSettingsTopic, type NativeDownloadsEvent } from "@solara/settings";
import { useEffect, useRef } from "react";
import { addNativeSettingsHandlers } from "./settings/nativeSettings";

export type DownloadsPanelEvent = (NativeDownloadsEvent | { kind: "dismiss" } | { kind: "closed" }) & { token?: number };

const windows: Record<string, string> = {};
const handlers = new Map<string, { current: (event: DownloadsPanelEvent) => void }>();
const owners = new Map<string, object>();
let queued = false;

function publish() {
  if (queued) return;
  queued = true;
  queueMicrotask(() => {
    queued = false;
    publishSettingsTopic("downloads.panel", { windows });
  });
}

addNativeSettingsHandlers({
  "downloads.panel": (windowId: string, event: DownloadsPanelEvent) => handlers.get(windowId)?.current(event),
});

export function useNativeDownloadsPanel(windowId: string, state: string | null, onEvent: (event: DownloadsPanelEvent) => void) {
  const ref = useRef(onEvent);
  ref.current = onEvent;
  useEffect(() => {
    handlers.set(windowId, ref);
    return () => void (handlers.get(windowId) === ref && handlers.delete(windowId));
  }, [windowId]);
  useEffect(() => {
    if (state === null) {
      if (owners.get(windowId) !== ref) return;
      owners.delete(windowId);
      delete windows[windowId];
      publish();
      return;
    }
    owners.set(windowId, ref);
    if (windows[windowId] === state) return;
    windows[windowId] = state;
    publish();
  }, [windowId, state]);
  useEffect(
    () => () => {
      if (owners.get(windowId) !== ref) return;
      owners.delete(windowId);
      delete windows[windowId];
      publish();
    },
    [windowId],
  );
}
