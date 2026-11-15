import { observeWindowLayoutAnchors, windowLayoutAnchorsAvailable, windowNativeLayout, type WindowLayoutAnchors } from "@solara/settings";
import { useEffect, useState } from "react";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { applyNativeWindowAnchors, dropNativeWindowAnchors, nativeWindowAnchorFeed } from "./windowLayout";

let anchorReaderSequence = 0;

addNativeSettingsHandlers({
  "window.layoutAnchors": (windowId: string, batch: WindowLayoutAnchors) => {
    const accepted = nativeWindowAnchorFeed.event(windowId, batch);
    if (accepted) applyNativeWindowAnchors(accepted);
  },
});

export function useNativeWindowAnchors(windowId: string): boolean {
  const [native] = useState(() => windowNativeLayout(windowId) && windowLayoutAnchorsAvailable(windowId));
  useEffect(() => {
    if (!native) return;
    const owner = {};
    const reader = `${windowId}:${++anchorReaderSequence}`;
    let disposed = false;
    nativeWindowAnchorFeed.begin(windowId, owner);
    void observeWindowLayoutAnchors(windowId, true, reader).then((observation) => {
      if (!observation) return;
      if (disposed) return void observeWindowLayoutAnchors(windowId, false, reader, observation.windowGeneration);
      const accepted = nativeWindowAnchorFeed.initial(windowId, owner, observation);
      if (accepted) applyNativeWindowAnchors(accepted);
    });
    return () => {
      disposed = true;
      const generation = nativeWindowAnchorFeed.end(windowId, owner);
      if (generation === undefined) return;
      dropNativeWindowAnchors(windowId);
      if (generation !== null) void observeWindowLayoutAnchors(windowId, false, reader, generation);
    };
  }, [native, windowId]);
  return native;
}
