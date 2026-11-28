import { listExtensions } from "@solara/solaracore";
import { confirm, focusWindow } from "@solara/shell";
import { closeNativeWorkspaceTab, stepProfilePager, switchProfilePager } from "@solara/settings";
import "../components/layout/profilePager";
import { profileNames, requestCreateProfile, type CreateProfilePreset } from "../components/profiles/CreateProfile";
import { useBrowser, type CreateWindowOptions } from "../store/browser";
import { nativeOwnsWorkspace } from "../store/nativeStore";
import { closesWindow, engineProfile, isIncognitoProfile, resolveWindowId } from "../store/model";
import { leavesEmptyWindow, windowClosingWithTab } from "../store/newTabBar";
import { engineIdOf, sharingProfiles } from "../store/profiles";
import { closeWindowAnimated } from "./closeAnimated";
import { applyHeldReports } from "./nativeEvents";
import { webviews } from "./webviews";
import { closeWindowDialog } from "./closeWindowDialog";

const store = () => useBrowser.getState();

export function focus(windowId: string) {
  store().setFocusedWindow(windowId);
  void focusWindow(windowId);
}

export function openWindow(options?: CreateWindowOptions): string {
  return store().createWindow(options);
}

export function switchToTab(tabId: string) {
  const tab = store().tabs[tabId];
  if (!tab) return;
  store().activate(tabId);
  if (tab.windowId !== store().ui.focusedWindowId) focus(tab.windowId);
}

export async function closeTab(tabId: string, successor?: string) {
  if (nativeOwnsWorkspace() && await closeNativeWorkspaceTab(tabId, successor)) return;
  const s = store();
  const tab = s.tabs[tabId];
  const w = tab && s.windows[tab.windowId];
  if (!tab || !w) return;
  const last = closesWindow(s, tabId) && !leavesEmptyWindow(s, tabId);
  const windowId = windowClosingWithTab(s, tabId);
  if (windowId && s.settings.warnBeforeClosingWindow) {
    const { confirmed, suppressed } = await confirm({ ...closeWindowDialog(windowId), suppression: "Don’t ask me again", windowId });
    if (suppressed) store().updateSettings({ warnBeforeClosingWindow: false });
    if (!confirmed) return;
    applyHeldReports();
  } else if (last && s.settings.warnBeforeClosingLastTab && !w.incognito) {
    const { confirmed, suppressed } = await confirm({ ...closeWindowDialog(w.id), suppression: "Don’t ask me again", windowId: w.id });
    if (suppressed) store().updateSettings({ warnBeforeClosingLastTab: false });
    if (!confirmed) return;
    applyHeldReports();
  }
  const now = store();
  const closesItsWindow = now.tabs[tabId]?.windowId === w.id && now.peeks[w.id]?.tabId !== tabId && closesWindow(now, tabId) && !leavesEmptyWindow(now, tabId);
  if (last && closesItsWindow) return closeWindowAnimated(w.id);
  store().closeTab(tabId, successor);
}

export function toggleMute(tabId: string) {
  const tab = store().tabs[tabId];
  if (!tab) return;
  store().setSiteMuted(tabId, !tab.muted);
  void webviews.get(tabId)?.setMuted(!tab.muted);
}

export function createProfile(windowId?: string, preset?: CreateProfilePreset): Promise<string | null> {
  return requestCreateProfile(windowId, preset);
}

export async function deleteProfile(profileId: string, windowId?: string) {
  const s = store();
  const profile = s.profiles[profileId];
  if (!profile || s.profileOrder.length <= 1) return;
  const sharing = sharingProfiles(s, profileId).map((id) => s.profiles[id]!.name);
  const { confirmed } = await confirm({
    title: `Delete “${profile.name}”?`,
    message: sharing.length
      ? `Its tabs will be closed. Its cookies, passwords, extensions, bookmarks and history stay with ${profileNames(sharing)}, which share them.`
      : `All data associated with this Profile will be removed. This action cannot be undone.${engineIdOf(profile) === "" ? await keptExtensionsNote() : ""}`,
    confirmTitle: "Delete Profile",
    destructive: true,
    windowId,
  });
  if (!confirmed) return;
  store().deleteProfile(profileId);
}

async function keptExtensionsNote(): Promise<string> {
  const names = await listExtensions("").then(
    (list) => list.filter((e) => e.mayModify).map((e) => e.name),
    () => null,
  );
  if (names && !names.length) return "";
  return names ? ` Its extensions (${profileNames(names)}) stay installed on this Mac, turned off.` : " Its extensions stay installed on this Mac, turned off.";
}

export async function moveTabToProfile(tabId: string, target: string) {
  const tab = store().tabs[tabId];
  if (!tab || isIncognitoProfile(tab.profileId)) return;
  const profileId = target === "new" ? await createProfile(tab.windowId) : target;
  if (!profileId || profileId === tab.profileId) return;
  const shared = engineProfile(profileId) === engineProfile(tab.profileId);
  if (store().settings.warnBeforeMovingTabsToProfile && !shared) {
    const { confirmed, suppressed } = await confirm({
      title: "Move Tab to Profile?",
      message: "Moving tabs between profiles could result in some data being lost.",
      confirmTitle: "Move Tab",
      suppression: "Don't warn me again",
      windowId: tab.windowId,
    });
    if (suppressed) store().updateSettings({ warnBeforeMovingTabsToProfile: false });
    if (!confirmed) return;
  }
  store().moveTabToProfile(tabId, profileId);
}

export function switchProfile(windowId: string, profileId: string, animated = false) {
  if (animated) void switchProfilePager(windowId, profileId);
  else store().switchProfile(windowId, profileId);
}

export function cycleProfile(windowId: string, delta: 1 | -1) {
  void stepProfilePager(windowId, delta);
}

export function openUrls(urls: string[], windowId?: string | null) {
  let target = resolveWindowId(store(), windowId);
  for (const url of urls) {
    if (!target || store().windows[target]?.incognito) target = openWindow({ url });
    else store().newTab(target, { url });
  }
}
