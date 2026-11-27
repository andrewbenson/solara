import { topStripPeek } from "@solara/settings";
import { useEffect, useRef } from "react";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { useTabDrag } from "./tabDrag";
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

const nativeFeed = nativeLayoutFeed<{ dropOver: boolean }>("topStrip.nativeFeed");

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
  useTopStripPeekProbe(windowId);
  return null;
}
