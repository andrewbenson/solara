import { changeCaptureSource, stopCapture } from "@solara/solaracore";
import { publishSettingsTopic } from "@solara/settings";
import { useEffect, useRef, useState } from "react";
import { Animated, Easing } from "react-native";
import { pagesPooledIn } from "../../lib/pagesPool";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { engineProfile } from "../../store/model";
import { browserIdOf } from "../extensions/state";
import { pageOf, usePages } from "../layout/pageState";
import { addMediaActions, mediaTheme, NativeMediaView } from "./nativeMedia";
import { useMedia, type TabShare } from "./state";
import { useWindowId } from "../../store/hooks";
import { nativeSplitPanes } from "../layout/nativeSplitChrome";

const SHARE_BAR_HEIGHT = 38;

const hostOf = (origin: string) => {
  try {
    return new URL(origin).hostname.replace(/^www\./, "") || origin;
  } catch {
    return origin;
  }
};

function useShareFor(tabId: string): [string, TabShare] | null {
  const shares = useMedia((m) => m.tabShares);
  const profile = useBrowser((s) => {
    const tab = s.tabs[tabId];
    return tab && /^https?:|^file:/.test(tab.url) ? engineProfile(tab.profileId) : null;
  });
  const capturing = usePages((p) => Object.keys(shares).filter((id) => p.pages[id]?.mediaAccess?.screen).join(","));
  if (profile === null) return null;
  for (const capturer of capturing ? capturing.split(",") : []) {
    const share = shares[capturer];
    if (!share || share.dismissed[tabId]) continue;
    const owner = useBrowser.getState().tabs[capturer];
    if (owner && engineProfile(owner.profileId) === profile) return [capturer, share];
  }
  return null;
}

export function noteTabShare(capturerTabId: string, capturedTabId: string, origin: string) {
  useMedia.setState((m) => ({ tabShares: { ...m.tabShares, [capturerTabId]: { capturedTabId, origin, dismissed: {} } } }));
}

const SHARE_END_MS = 1500;

export function startTabShareCleanup() {
  return usePages.subscribe((p, prev) => {
    if (p.pages === prev.pages) return;
    const shares = useMedia.getState().tabShares;
    const ended = Object.keys(shares).filter((id) => prev.pages[id]?.mediaAccess?.screen && !p.pages[id]?.mediaAccess?.screen);
    if (!ended.length) return;
    setTimeout(() => {
      const gone = ended.filter((id) => !usePages.getState().pages[id]?.mediaAccess?.screen);
      if (!gone.length) return;
      useMedia.setState((m) => {
        const next = { ...m.tabShares };
        for (const id of gone) delete next[id];
        return { tabShares: next };
      });
    }, SHARE_END_MS);
  });
}

async function shareInstead(capturer: string, tabId: string): Promise<boolean> {
  const ok = await changeCaptureSource(browserIdOf(capturer), browserIdOf(tabId));
  if (!ok) return false;
  useMedia.setState((m) => {
    const share = m.tabShares[capturer];
    return share ? { tabShares: { ...m.tabShares, [capturer]: { ...share, capturedTabId: tabId, dismissed: {} } } } : m;
  });
  return true;
}

if (__DEV__) (globalThis as { acShareBar?: unknown }).acShareBar = { shareInstead, tabShares: () => useMedia.getState().tabShares };

function dismiss(capturer: string, tabId: string) {
  useMedia.setState((m) => {
    const share = m.tabShares[capturer];
    return share ? { tabShares: { ...m.tabShares, [capturer]: { ...share, dismissed: { ...share.dismissed, [tabId]: true } } } } : m;
  });
}

addMediaActions({
  shareBar: (_windowId, tabId, extra) => {
    const capturer = typeof extra.capturer === "string" ? extra.capturer : "";
    if (!capturer) return;
    if (extra.action === "stop") return void stopCapture(browserIdOf(capturer));
    if (extra.action === "shareInstead") return void shareInstead(capturer, tabId);
    if (extra.action === "dismiss") return dismiss(capturer, tabId);
  },
});

const bands: Record<string, Record<string, object>> = {};
let bandsQueued = false;

function setBand(windowId: string, tabId: string, state: object | null) {
  const windowBands = (bands[windowId] ??= {});
  if (state) windowBands[tabId] = state;
  else delete windowBands[tabId];
  if (!Object.keys(windowBands).length) delete bands[windowId];
  if (bandsQueued) return;
  bandsQueued = true;
  queueMicrotask(() => {
    bandsQueued = false;
    publishSettingsTopic("media.shareBand", { v: 1, windows: bands });
  });
}

function shareBarState(tabId: string, capturer: string, share: TabShare, theme: ReturnType<typeof useTheme>) {
  const host = hostOf(share.origin || pageOf(capturer).security?.origin || useBrowser.getState().tabs[capturer]?.url || "");
  return { capturer, tabId, shared: share.capturedTabId === tabId, host, theme: mediaTheme(theme) };
}

export function ShareBar({ tabId }: { tabId: string }) {
  const windowId = useWindowId();
  const [native] = useState(() => nativeSplitPanes && pagesPooledIn(windowId));
  const theme = useTheme();
  const found = useShareFor(tabId);
  const band = native && found ? shareBarState(tabId, found[0], found[1], theme) : null;
  const bandKey = band && JSON.stringify(band);
  useEffect(() => {
    if (native) setBand(windowId, tabId, band);
  }, [native, windowId, tabId, bandKey]);
  useEffect(() => () => {
    if (native) setBand(windowId, tabId, null);
  }, [native, windowId, tabId]);
  const heightRef = useRef<Animated.Value | null>(null);
  const height = native ? null : (heightRef.current ??= new Animated.Value(0));
  const visible = !!found;
  useEffect(() => {
    if (height) Animated.timing(height, { toValue: visible ? SHARE_BAR_HEIGHT : 0, duration: 180, easing: Easing.out(Easing.cubic), useNativeDriver: false }).start();
  }, [visible]);
  const last = useRef(found);
  if (found) last.current = found;
  const shown = found ?? last.current;
  if (!height || !shown) return null;
  const [capturer, share] = shown;
  return (
    <Animated.View style={{ height, overflow: "hidden" }}>
      <NativeMediaView kind="media.shareBar" windowId={windowId} state={shareBarState(tabId, capturer, share, theme)} style={{ height: SHARE_BAR_HEIGHT }} />
    </Animated.View>
  );
}
