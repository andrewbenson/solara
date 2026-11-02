import { addToDock, currentAppIcon, isInDock, playIntroMusic, setIntroMusicMuted, stopIntroMusic, type IntroMusicCues } from "@solara/shell";
import { hostedKinds, publishSettingsTopic, type SettingsHandler } from "@solara/settings";
import { useBrowser } from "../../../store/browser";
import { tabLayoutOf } from "../../../store/model";
import type { ProfileColor } from "../../../store/types";
import { importModule } from "../../import/module";
import { PINNABLE_SITES, pinnedHosts, pinSites } from "../../onboarding/sites";
import { setWindowLayout, useOnboarding } from "../../onboarding/state";
import { endToolTour, startToolTour } from "../../onboarding/tour/state";
import { openImport } from "../windows";

const hostOf = (url: string) => {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return "";
  }
};

function pinnableVisits(profileId: string) {
  const wanted = new Map(PINNABLE_SITES.map((site) => [hostOf(site.url), 0]));
  for (const entry of useBrowser.getState().history[profileId] ?? []) {
    const host = hostOf(entry.url);
    const visits = wanted.get(host);
    if (visits !== undefined) wanted.set(host, visits + entry.visits);
  }
  return PINNABLE_SITES.map((site) => ({ url: site.url, visits: wanted.get(hostOf(site.url)) ?? 0 }));
}

function windowTopic() {
  const windowId = useOnboarding.getState().windowId;
  const s = useBrowser.getState();
  const w = windowId ? s.windows[windowId] : undefined;
  if (!windowId || !w) return null;
  return {
    windowId,
    profileId: w.profileId,
    tabLayout: tabLayoutOf(s, windowId),
    color: s.profiles[w.profileId]?.color ?? null,
    incognito: w.incognito,
    pinnedHosts: [...pinnedHosts(windowId)],
    history: pinnableVisits(w.profileId),
    importAvailable: !!importModule(),
  };
}

let lastTopic: string | null = null;

function publishWindow() {
  const topic = windowTopic();
  if (!topic) return;
  const json = JSON.stringify(topic);
  if (json === lastTopic) return;
  lastTopic = json;
  publishSettingsTopic("onboarding.window", topic);
}

export function publishOnboarding(): void {
  if (!hostedKinds().includes("onboarding")) return;
  publishWindow();
  useOnboarding.subscribe((s, prev) => {
    if (s.windowId !== prev.windowId) publishWindow();
  });
  useBrowser.subscribe((s, prev) => {
    if (!useOnboarding.getState().windowId) return;
    if (s.windows !== prev.windows || s.profiles !== prev.profiles || s.tabs !== prev.tabs || s.groups !== prev.groups || s.parkedPins !== prev.parkedPins || s.history !== prev.history || s.settings.tabLayout !== prev.settings.tabLayout) {
      publishWindow();
    }
  });
}

export const onboardingHandlers: Record<string, SettingsHandler> = {
  "onboarding.setWindowLayout": (windowId: string, layout: "sidebar" | "top") => setWindowLayout(windowId, layout),
  "onboarding.setProfileColor": (windowId: string, color: ProfileColor) => {
    const s = useBrowser.getState();
    const profileId = s.windows[windowId]?.profileId;
    if (profileId) s.updateProfile(profileId, { color });
  },
  "onboarding.startToolTour": (windowId: string) => startToolTour(windowId),
  "onboarding.endToolTour": () => endToolTour(),
  "onboarding.playIntroMusic": (cues: IntroMusicCues, muted: boolean) => playIntroMusic(cues, muted),
  "onboarding.setIntroMusicMuted": (muted: boolean) => setIntroMusicMuted(muted),
  "onboarding.stopIntroMusic": (fade: number) => stopIntroMusic(fade),
  "onboarding.openImport": (browserId: string) => openImport(browserId),
  "onboarding.isInDock": () => isInDock().catch(() => false),
  "onboarding.addToDock": () => addToDock().catch(() => false),
  "onboarding.currentAppIcon": () => currentAppIcon().catch(() => null),
  "onboarding.pinSites": (windowId: string, ids: string[]) => pinSites(windowId, ids),
  "onboarding.dismissed": (windowId: string, requestId?: string | null) => {
    const current = useOnboarding.getState();
    if (current.windowId !== windowId || (current.requestId || null) !== (requestId || null)) return;
    useOnboarding.setState({ windowId: null, requestId: null, step: "intro", leaving: false, tourAfter: false });
  },
};
