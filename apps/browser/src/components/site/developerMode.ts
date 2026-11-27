import { developerModeOf, isDeveloperMode, NO_DEVELOPER_MODE, withDeveloperMode, developerHostOf, type DeveloperModeState, type DeveloperReload } from "../../lib/developerMode";
import { resolveInput } from "@solara/core";
import { create } from "zustand";
import { useBrowser } from "../../store/browser";
import { useTabLive } from "../../store/hooks";
import { searchUrlPrefix } from "../../store/settings";
import { incognitoOriginal, isIncognitoProfile } from "../../store/model";
import type { Settings } from "../../store/settings";

const ownerOf = (profileId: string) => (isIncognitoProfile(profileId) ? incognitoOriginal(profileId) : profileId);

const sanitized = new WeakMap<object, DeveloperModeState>();

export function developerModeFor(settings: Pick<Settings, "developerMode">, profileId: string): DeveloperModeState {
  const raw: unknown = settings.developerMode?.[ownerOf(profileId)];
  if (!raw || typeof raw !== "object") return NO_DEVELOPER_MODE;
  let state = sanitized.get(raw);
  if (!state) sanitized.set(raw, (state = developerModeOf(raw)));
  return state;
}

const tabOf = (tabId: string | undefined) => (tabId ? useBrowser.getState().tabs[tabId] : undefined);

export function tabInDeveloperMode(tabId: string | undefined): boolean {
  const tab = tabOf(tabId);
  return !!tab && isDeveloperMode(tab.url, developerModeFor(useBrowser.getState().settings, tab.profileId));
}

export function canToggleDeveloperModeFor(tabId: string | undefined): boolean {
  const tab = tabOf(tabId);
  return !!tab && !isIncognitoProfile(tab.profileId) && !!developerHostOf(tab.url);
}

function updateProfile(profileId: string, change: (state: DeveloperModeState) => DeveloperModeState) {
  const s = useBrowser.getState();
  const all = s.settings.developerMode ?? {};
  s.updateSettings({ developerMode: { ...all, [profileId]: change(developerModeFor(s.settings, profileId)) } });
}

export function setDeveloperModeFor(tabId: string, on: boolean) {
  const tab = tabOf(tabId);
  if (!tab || !canToggleDeveloperModeFor(tabId)) return;
  updateProfile(tab.profileId, (state) => withDeveloperMode(state, tab.url, on));
}

export function toggleDeveloperModeFor(tabId: string | undefined) {
  if (tabId) setDeveloperModeFor(tabId, !tabInDeveloperMode(tabId));
}

export function developerReloadFor(tabId: string): DeveloperReload {
  const tab = tabOf(tabId);
  return tab ? developerModeFor(useBrowser.getState().settings, tab.profileId).reload : "reload";
}

export function setDeveloperReload(tabId: string, reload: DeveloperReload) {
  const tab = tabOf(tabId);
  if (!tab || isIncognitoProfile(tab.profileId) || developerReloadFor(tabId) === reload) return;
  updateProfile(tab.profileId, (state) => ({ ...state, reload }));
}

export function useTabDeveloperMode(tabId: string | undefined): boolean {
  return useBrowser((s) => {
    const tab = tabId ? s.tabs[tabId] : undefined;
    return !!tab && isDeveloperMode(tab.url, developerModeFor(s.settings, tab.profileId));
  });
}

export const useUrlEdit = create<{ tabId: string | null; request: number }>(() => ({ tabId: null, request: 0 }));

export function startUrlEdit(tabId: string) {
  useUrlEdit.setState((s) => ({ tabId, request: Math.max(0, s.request) + 1 }));
}

export function endUrlEdit(tabId: string) {
  if (useUrlEdit.getState().tabId === tabId) useUrlEdit.setState({ tabId: null });
}

export function submitUrlEdit(tabId: string, text: string) {
  endUrlEdit(tabId);
  const s = useBrowser.getState();
  const url = resolveInput(text, searchUrlPrefix(s.settings));
  if (url && s.tabs[tabId]) s.navigate(tabId, url);
}

export function useToolbarSiteColor(tabId: string | undefined): string | null {
  const extend = useBrowser((s) => s.settings.extendWebsiteColor);
  const hasUrl = useBrowser((s) => !!(tabId && s.tabs[tabId]?.url));
  const themeColor = useTabLive(tabId, (l) => l.themeColor);
  const developer = useTabDeveloperMode(tabId);
  return extend && hasUrl && !developer ? (themeColor ?? null) : null;
}
