import { endTopStripIncoming, topStripIncoming, topStripPeek, topStripDownloadsAnchor } from "@solara/settings";
import { useEffect, useRef } from "react";
import { registerDownloadsAnchor } from "../Downloads";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { openNewTabInSplit } from "./splitActions";
import { EXTERNAL_DRAG, setInsert, setInsertResolver, useTabDrag } from "./tabDrag";
import "./nativeTabDrag";
import { nativeLayoutFeed, useNativeLayoutFeed } from "./nativeLayoutFeed";
import { devPeeks } from "./dockMotion";

const peekLive = new Map<string, (live: boolean) => void>();

addNativeSettingsHandlers({
  "topStrip.peek.action": (windowId: string, name: string, extra?: { live?: boolean }) => {
    switch (name) {
      case "live":
        peekLive.get(windowId)?.(!!extra?.live);
    }
  },
});

addNativeSettingsHandlers({
  "topStrip.action": (windowId: string, name: string, _id: string, extra: { split?: boolean }) => {
    switch (name) {
      case "newTab":
        if (extra.split) return openNewTabInSplit(windowId);
        return;
    }
  },
});

export function useIncomingFile(windowId: string) {
  const point = useTabDrag((d) => (d.windowId === EXTERNAL_DRAG ? (d.overWindow === windowId && d.overPoint ? d.overPoint.join() : "") : null));
  const resolved = useRef<string | null | undefined>(undefined);
  const asked = useRef(0);
  const dragging = point !== null;
  useEffect(() => {
    if (!dragging) return;
    setInsertResolver(windowId, () => resolved.current);
    return () => {
      setInsertResolver(windowId, null);
      resolved.current = undefined;
      void endTopStripIncoming(windowId);
    };
  }, [dragging, windowId]);
  useEffect(() => {
    const ask = ++asked.current;
    if (point === null) return;
    const at = point ? (point.split(",").map(Number) as [number, number]) : null;
    void topStripIncoming(windowId, at).then((beforeId) => {
      if (ask !== asked.current) return;
      resolved.current = beforeId;
      setInsert(windowId, beforeId);
    });
  }, [point, windowId]);
}

const nativeFeed = nativeLayoutFeed<{ dropOver: boolean }>("topStrip.nativeFeed");

export function useTopStripDownloadsAnchor(windowId: string) {
  useEffect(
    () => registerDownloadsAnchor(windowId, async () => {
      const rect = await topStripDownloadsAnchor(windowId);
      return rect ? { x: rect[0], y: rect[1], width: rect[2], height: rect[3] } : null;
    }),
    [windowId],
  );
}

export function useTopStripPeekProbe(windowId: string, onLive?: (live: boolean) => void) {
  const latest = useRef(onLive);
  latest.current = onLive;
  useEffect(() => {
    const key = `strip:${windowId}`;
    const peek = topStripPeek(windowId);
    const handle = { live: false, show: () => void peek.show(), hide: () => void peek.hide(), trace: () => void peek.trace(), samples: () => peek.samples(), pin: (value: number) => void peek.pin(value) };
    const report = (live: boolean) => {
      handle.live = live;
      latest.current?.(live);
    };
    if (__DEV__) devPeeks[key] = handle;
    peekLive.set(windowId, report);
    void peek.state().then(state => { if (peekLive.get(windowId) === report) report(state?.live ?? false); });
    return () => {
      if (__DEV__ && devPeeks[key] === handle) delete devPeeks[key];
      if (peekLive.get(windowId) === report) peekLive.delete(windowId);
    };
  }, [windowId]);
}

export function NativeTopStripFeed({ windowId }: { windowId: string }) {
  const dropOver = useTabDrag((d) => d.overWindow === windowId);
  useNativeLayoutFeed(nativeFeed, windowId, { dropOver });
  useTopStripDownloadsAnchor(windowId);
  useTopStripPeekProbe(windowId);
  return null;
}
