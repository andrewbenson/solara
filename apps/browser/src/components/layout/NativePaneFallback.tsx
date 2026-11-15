import { windowNativeLayoutGeneration } from "@solara/settings";
import { requireOptionalNativeModule } from "expo-modules-core";
import { useEffect, useMemo, useRef, useSyncExternalStore, type ReactNode, type ReactPortal } from "react";
import { StyleSheet, View } from "react-native";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { usePaneRootDrawn } from "./paneFeed";
import { NativePaneFallbackFeed, type NativePaneFallbackSnapshot, type NativePaneFallbackTarget, type NativePaneFallbackOffer } from "./nativePaneFallbackFeed";

type NativePaneFallbackModule = {
  paneFallbacks(windowId: string): string;
  admitPaneFallback(windowId: string, windowGeneration: number, revision: number): string;
  releasePaneFallback(windowId: string, tabId: string, generation: number, lease: number): Promise<void>;
};

const native = requireOptionalNativeModule<NativePaneFallbackModule>("SolaraWindowShell");
const feed = new NativePaneFallbackFeed(windowNativeLayoutGeneration, (windowId, tabId, generation, lease) => {
  void native?.releasePaneFallback(windowId, tabId, generation, lease);
});
const offerOf = (json: string | undefined) => {
  const snapshot = json ? JSON.parse(json) as Partial<NativePaneFallbackSnapshot> : null;
  return snapshot && typeof snapshot.windowGeneration === "number" && typeof snapshot.revision === "number" && snapshot.targets
    ? snapshot as NativePaneFallbackOffer : null;
};

const acquiredOf = (json: string | undefined): NativePaneFallbackSnapshot | null => {
  const snapshot = offerOf(json) as NativePaneFallbackSnapshot | null;
  return snapshot && Object.values(snapshot.targets).every((target) => Number.isSafeInteger(target.lease) && target.lease > 0) ? snapshot : null;
};

addNativeSettingsHandlers({
  "pane.fallbackTargets": (windowId: string, snapshot: NativePaneFallbackOffer) => feed.admit(windowId, snapshot, () =>
    acquiredOf(native?.admitPaneFallback(windowId, snapshot.windowGeneration, snapshot.revision))),
});

export function useNativePaneFallbacks(windowId: string) {
  const owner = useRef({}).current;
  useEffect(() => {
    feed.begin(windowId, owner);
    const snapshot = offerOf(native?.paneFallbacks(windowId));
    if (snapshot) feed.admit(windowId, snapshot, () =>
      acquiredOf(native?.admitPaneFallback(windowId, snapshot.windowGeneration, snapshot.revision)));
    return () => feed.end(windowId, owner);
  }, [windowId, owner]);
  const version = useSyncExternalStore(feed.subscribe, () => feed.version(windowId));
  useEffect(() => feed.flush(windowId, owner, version), [windowId, owner, version]);
  return feed.read(windowId);
}

export function NativePaneFallback({ windowId, tabId, target, children }: { windowId: string; tabId: string; target: NativePaneFallbackTarget | undefined; children: ReactNode }) {
  const drawn = usePaneRootDrawn(tabId);
  const active = !!target?.shown && !drawn;
  const tag = target?.rootTag;
  const generation = target?.targetGeneration;
  const container = useMemo(() => tag === undefined ? null : { containerTag: tag }, [tag]);
  if (!active || !container) return null;
  const renderer = require("react-native/Libraries/Renderer/shims/ReactNative").default as { createPortal(children: ReactNode, container: { containerTag: number }, key: string): ReactPortal };
  return renderer.createPortal(<View pointerEvents="box-none" style={StyleSheet.absoluteFill}>{children}</View>, container, JSON.stringify([windowId, windowNativeLayoutGeneration(windowId), generation, tag]));
}
