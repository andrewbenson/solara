import { nativeSafeMode } from "../store/nativeStore";
import { persistenceRefused } from "../lib/persistLatch";
import { onAppEvent, onWindowEvent } from "@solara/shell";
import { liveStart } from "@solara/settings";
import { liveCommand } from "./command";
import { useBrowser } from "../store/browser";
import { activeTabId, viewTabIds } from "../store/model";
import { SOURCES } from "./sources";
import { live, markRead, removeFolder, useLive } from "./store";
import type { LiveErrorKind, LiveFolderKind, LiveItem, LiveSourceId } from "./types";

export const COMPLETION_MS = 2600;
export const refreshFolder = (folderId: string): Promise<void> => liveCommand("refreshFolder", { folderId }).then(() => undefined);
export const manualRefresh = (folderId: string): Promise<void> => liveCommand("manualRefresh", { folderId }).then(() => undefined);

export function statusText(folderId: string, now = Date.now()): string {
  const hidden = live().hidden[folderId]?.length ?? 0;
  return hidden ? `${fetchText(folderId, now)} · ${hidden} hidden until you refresh` : fetchText(folderId, now);
}

function fetchText(folderId: string, now: number): string {
  const st = live().status[folderId];
  if (!st || st.state === "initializing") return "Loading…";
  if (st.state === "updating") return "Updating…";
  if (st.error) return errorText(st.error.kind, st.error.source);
  if (!st.lastFetch) return "Not updated yet";
  const min = Math.floor((now - st.lastFetch) / 60_000);
  return min < 1 ? "Updated just now" : min < 60 ? `Updated ${min} min ago` : `Updated ${Math.floor(min / 60)} hr ago`;
}

export function errorText(kind: LiveErrorKind, source: LiveSourceId): string {
  const name = SOURCES[source].name;
  switch (kind) {
    case "notConfigured": return `Connect ${name} in Settings`;
    case "signedOut": return `Sign back in to ${name}`;
    case "sso": return `${name} needs Single Sign-On for this organization`;
    case "rateLimited": return `${name} rate limit exceeded. Try again in a few minutes.`;
    case "network": return `Couldn't connect to ${name}`;
    default: return `We're having trouble connecting to ${name}`;
  }
}

export function newLiveFolder(windowId: string, kind: LiveFolderKind): Promise<string | null> {
  const w = useBrowser.getState().windows[windowId];
  return w && !w.incognito ? newProfileLiveFolder(w.profileId, kind) : Promise.resolve(null);
}

export async function newProfileLiveFolder(profileId: string, kind: LiveFolderKind, sources?: LiveSourceId[]): Promise<string> {
  const s = live();
  const connected: LiveSourceId[] = kind === "pullRequests"
    ? (["github"] as const).filter((id) => s.accounts[id])
    : (["notion", "gdrive"] as const).filter((id) => s.accounts[id]);
  const chosen = sources ?? (connected.length ? connected : undefined);
  const result = await liveCommand("newProfileLiveFolder", { profileId, kind, ...(chosen ? { sources: chosen } : {}) });
  if (!result.folderId) throw new Error("Live folder creation returned no ID");
  return result.folderId;
}

export function openLiveItem(windowId: string, folderId: string, item: LiveItem, options: { background?: boolean } = {}) {
  const s = useBrowser.getState();
  void markRead(folderId, [item.id]);
  const existing = viewTabIds(s, windowId).find((id) => s.tabs[id]?.liveItem?.itemId === item.id && s.tabs[id]?.liveItem?.folderId === folderId);
  if (existing) {
    if (!options.background) s.activate(existing);
    return existing;
  }
  const id = s.newTab(windowId, { url: item.url, background: options.background });
  useBrowser.getState().updateTab(id, { liveItem: { folderId, itemId: item.id } });
  return id;
}

export function deleteLiveFolder(folderId: string) {
  const s = useBrowser.getState();
  const tabs = Object.values(s.tabs).filter((t) => t.liveItem?.folderId === folderId).map((t) => t.id);
  if (tabs.length) s.closeTabs(tabs);
  return removeFolder(folderId);
}

let started = false;

export function startLiveEngine() {
  if (started || nativeSafeMode() || persistenceRefused()) return;
  started = true;
  const orphans = () => {
    const s = useBrowser.getState();
    const folders = live().folders;
    for (const t of Object.values(s.tabs)) if (t.liveItem && !folders[t.liveItem.folderId]) s.updateTab(t.id, { liveItem: undefined });
  };
  orphans();
  useLive.subscribe((s, prev) => { if (s.folders !== prev.folders) orphans(); });
  useBrowser.subscribe((s, prev) => {
    if (s.profiles === prev.profiles) return;
    for (const profileId of new Set(Object.values(live().folders).map((f) => f.profileId))) if (!s.profiles[profileId]) void liveCommand("removeProfile", { profileId });
  });
  useBrowser.subscribe((s, prev) => {
    if (s.tabs === prev.tabs) return;
    for (const id in s.tabs) {
      const t = s.tabs[id]!;
      if (t.pinned && t.liveItem && !prev.tabs[id]?.pinned) useBrowser.getState().updateTab(id, { liveItem: undefined });
    }
  });
  useBrowser.subscribe((s, prev) => {
    if (s.windows === prev.windows) return;
    for (const windowId of s.windowOrder) {
      const before = activeTabId(prev, windowId);
      if (!before || before === activeTabId(s, windowId)) continue;
      const folderId = s.tabs[before]?.liveItem?.folderId;
      if (folderId) void liveCommand("liveTabDeactivated", { folderId });
    }
  });
  onWindowEvent((e) => { if (e.type === "focus") void liveCommand("windowFocused", {}); });
  onAppEvent((e) => { if (e.type === "resignActive") void liveCommand("appResignedActive", {}); });
  void liveStart();
}
