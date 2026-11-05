import { isPageCurrent, nativePageFacts, onTabSleepRunningChanged, pageReport, registerKeepAliveRuntime, type PageIdentity } from "@solara/store";
import { pageOf, patchPage, usePages } from "../components/layout/pageState";
import { revealToolbar, useToolbarAutoHide } from "../components/layout/toolbarAutoHide";
import { useMedia } from "../components/media/state";
import { useBrowser } from "../store/browser";
import { nativeTabSleepRunning } from "../store/nativeStore";
import { hasPage } from "../store/pageSession";
import { createKeepAliveFeed, keepAliveGone, observeKeepAlive } from "./keepAliveFeed";
import { applyHeldReports } from "./nativeEvents";

function clearTransientFacts(id: string) {
  patchPage(id, { mediaAccess: null, permission: null, crashed: null, unresponsive: false, fullscreen: false, newTabShown: null });
  revealToolbar(id);
  useMedia.setState((media) => {
    const keys = ["sessions", "dismissed", "pip", "pipOpen", "displayRequests", "tabShares"] as const;
    return Object.fromEntries(keys.map((key) => [key, Object.fromEntries(Object.entries(media[key]).filter(([tabId, value]) => tabId !== id && (key !== "tabShares" || (value as { capturedTabId?: string }).capturedTabId !== id)))]));
  });
}

let started = false;
let watching = false;
let nudge: (() => void) | null = null;
export function startNativeKeepAlive() {
  if (!watching) {
    watching = true;
    onTabSleepRunningChanged((running) => {
      if (running) startNativeKeepAlive();
      nudge?.();
    });
  }
  if (started || !nativeTabSleepRunning()) return;
  started = true;
  const sessions = new Map<string, string>();
  const identities = new Map<string, PageIdentity>();
  const read = (identity: PageIdentity) => {
    const s = useBrowser.getState();
    const tab = s.tabs[identity.tabId];
    if (!tab || !hasPage(tab) || s.live[tab.id]?.discarded || !isPageCurrent(identity)) return null;
    const native = nativePageFacts(tab.id);
    if (native?.generation !== identity.sessionGeneration || native.protectionKnown !== true) return null;
    const page = pageOf(tab.id);
    const media = useMedia.getState();
    const session = media.sessions[tab.id];
    return {
      route: JSON.stringify([tab.profileId, tab.windowId]),
      keep: {
        capturing: !!(page.mediaAccess || page.permission),
        newTabShown: !!page.newTabShown,
        pip: !!media.pipOpen[tab.id],
        displayRequest: !!media.displayRequests[tab.id],
        media: session?.playbackState === "playing" ? "playing" as const : session ? "present" as const : "none" as const,
      },
      reveal: {
        fullscreen: page.fullscreen,
        crashed: !!page.crashed,
        unresponsive: page.unresponsive,
        scrolledDown: !!useToolbarAutoHide.getState().scrolledDown[tab.id],
        sharing: !!media.tabShares[tab.id] || Object.values(media.tabShares).some((share) => share.capturedTabId === tab.id),
      },
    };
  };
  const feed = createKeepAliveFeed({ running: nativeTabSleepRunning, register: registerKeepAliveRuntime, read, send: pageReport, schedule: (run) => queueMicrotask(() => { applyHeldReports(); run(); }) });
  observeKeepAlive({
    created(identity, host) {
      const previous = identities.get(identity.tabId);
      if (previous && (previous.sessionGeneration !== identity.sessionGeneration || previous.registrationGeneration !== identity.registrationGeneration)) clearTransientFacts(identity.tabId);
      sessions.set(identity.tabId, identity.sessionGeneration);
      identities.set(identity.tabId, identity);
      feed.created(identity, host);
    },
    handled: feed.handled,
    failed: feed.failed,
    gone(identity) {
      feed.gone(identity);
    },
  });
  usePages.subscribe(feed.changed);
  useMedia.subscribe(feed.changed);
  useToolbarAutoHide.subscribe(feed.changed);
  useBrowser.subscribe((s, prev) => {
    for (const [id] of sessions) {
      const tab = s.tabs[id];
      if (tab && s.live[id]?.discarded && !prev.live[id]?.discarded) clearTransientFacts(id);
      if (!tab) {
        clearTransientFacts(id);
        const identity = identities.get(id);
        if (identity) keepAliveGone(identity);
        identities.delete(id);
        sessions.delete(id);
      }
    }
    feed.changed();
  });
  nudge = feed.changed;
  feed.changed();
}
