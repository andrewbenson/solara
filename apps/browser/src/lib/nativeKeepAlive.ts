import { isPageCurrent, nativePageFacts, onTabSleepRunningChanged, pageReport, registerKeepAliveRuntime, type PageIdentity } from "@solara/store";
import { pageOf, patchPage, usePages } from "../components/layout/pageState";
import { revealToolbar, useToolbarAutoHide } from "../components/layout/toolbarAutoHide";
import { useMedia } from "../components/media/state";
import { useBrowser, type BrowserState } from "../store/browser";
import { changedIds } from "../store/changes";
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

const PENDING_RETRY_MS = 1000;
const PENDING_RETRY_MAX_MS = 30_000;

let started = false;
let watching = false;
let nudge: (() => void) | null = null;
type PagesState = ReturnType<typeof usePages.getState>;
let followPages: ((s: PagesState, prev: PagesState) => void) | null = null;
export const keepAlivePagesChanged = (s: PagesState, prev: PagesState) => followPages?.(s, prev);
let followBrowser: ((s: BrowserState, prev: BrowserState) => void) | null = null;
export const keepAliveBrowserChanged = (s: BrowserState, prev: BrowserState) => followBrowser?.(s, prev);
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
    if (!tab || !hasPage(tab) || s.live[tab.id]?.discarded) return null;
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
  const ready = (identity: PageIdentity) => {
    if (!isPageCurrent(identity)) return false;
    const native = nativePageFacts(identity.tabId);
    return native?.generation === identity.sessionGeneration && native.protectionKnown === true;
  };
  let retry: ReturnType<typeof setTimeout> | null = null;
  let retryMs = PENDING_RETRY_MS;
  const resetRetry = () => {
    if (retry) clearTimeout(retry);
    retry = null;
    retryMs = PENDING_RETRY_MS;
  };
  const waiting = (pending: boolean) => {
    if (!pending) return resetRetry();
    if (retry) return;
    const delay = retryMs;
    retryMs = Math.min(PENDING_RETRY_MAX_MS, retryMs * 2);
    retry = setTimeout(() => {
      retry = null;
      feed.changed();
    }, delay);
  };
  const feed = createKeepAliveFeed({ running: nativeTabSleepRunning, register: registerKeepAliveRuntime, read, ready, send: pageReport, schedule: (run) => queueMicrotask(() => { applyHeldReports(); run(); }), waiting });
  const tracked = (ids: Iterable<string>) => { for (const id of ids) if (identities.has(id)) return true; return false; };
  followPages = (s, prev) => {
    if (s.pages === prev.pages) return;
    for (const id of identities.keys()) {
      const now = s.pages[id];
      const before = prev.pages[id];
      if (now === before) continue;
      if (!now || !before || now.mediaAccess !== before.mediaAccess || now.permission !== before.permission || now.newTabShown !== before.newTabShown || now.fullscreen !== before.fullscreen || now.crashed !== before.crashed || now.unresponsive !== before.unresponsive) return feed.changed();
    }
  };
  const mediaChanged = (s: ReturnType<typeof useMedia.getState>, prev: ReturnType<typeof useMedia.getState>) => {
    for (const id of identities.keys()) {
      if (s.sessions[id] !== prev.sessions[id] || s.pipOpen[id] !== prev.pipOpen[id] || s.displayRequests[id] !== prev.displayRequests[id]) return feed.changed();
    }
    if (s.tabShares === prev.tabShares) return;
    const shares = (all: typeof s.tabShares) => Object.entries(all).flatMap(([id, share]) => [id, (share as { capturedTabId?: string }).capturedTabId ?? ""]);
    if (tracked(shares(s.tabShares)) || tracked(shares(prev.tabShares))) feed.changed();
  };
  const toolbarChanged = (s: ReturnType<typeof useToolbarAutoHide.getState>, prev: ReturnType<typeof useToolbarAutoHide.getState>) => {
    if (s.scrolledDown === prev.scrolledDown) return;
    for (const id of identities.keys()) if (s.scrolledDown[id] !== prev.scrolledDown[id]) return feed.changed();
  };
  let listening: (() => void)[] = [];
  const listen = () => {
    if (listening.length || !identities.size) return;
    listening = [useMedia.subscribe(mediaChanged), useToolbarAutoHide.subscribe(toolbarChanged)];
  };
  const unlisten = () => {
    if (identities.size) return;
    for (const stop of listening) stop();
    listening = [];
  };
  observeKeepAlive({
    created(identity, host) {
      const previous = identities.get(identity.tabId);
      if (previous && (previous.sessionGeneration !== identity.sessionGeneration || previous.registrationGeneration !== identity.registrationGeneration)) clearTransientFacts(identity.tabId);
      sessions.set(identity.tabId, identity.sessionGeneration);
      identities.set(identity.tabId, identity);
      listen();
      resetRetry();
      feed.created(identity, host);
    },
    handled: feed.handled,
    failed: feed.failed,
    gone(identity) {
      feed.gone(identity);
    },
  });
  followBrowser = (s, prev) => {
    if (s.tabs === prev.tabs && s.live === prev.live) return;
    let changed = false;
    for (const id of new Set([...changedIds(s.tabs, prev.tabs), ...changedIds(s.live, prev.live)])) {
      if (!sessions.has(id)) continue;
      const tab = s.tabs[id];
      const before = prev.tabs[id];
      if (!tab || !before || tab.profileId !== before.profileId || tab.windowId !== before.windowId || tab.adoptId !== before.adoptId
        || tab.navigation?.url !== before.navigation?.url || tab.navigation?.seq !== before.navigation?.seq
        || tab.navigation?.userInitiated !== before.navigation?.userInitiated || !!s.live[id]?.discarded !== !!prev.live[id]?.discarded) changed = true;
      if (tab && s.live[id]?.discarded && !prev.live[id]?.discarded) clearTransientFacts(id);
      if (!tab) {
        clearTransientFacts(id);
        const identity = identities.get(id);
        if (identity) keepAliveGone(identity);
        identities.delete(id);
        sessions.delete(id);
      }
    }
    if (changed) feed.changed();
    unlisten();
  };
  nudge = feed.changed;
  listen();
  feed.changed();
}
