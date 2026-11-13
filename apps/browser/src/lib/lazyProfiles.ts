import { ensureProfile, loadedProfiles, onProfileLoaded } from "@solara/solaracore";
import { internalPageOf } from "../components/pages/internalUrls";
import { useBrowser, type BrowserState } from "../store/browser";
import { tabEngine } from "../store/engines";
import { profileLaunchTargets, profilePageTargets } from "./profileLoading";

const loaded = new Set<string>();
const listeners = new Set<() => void>();
let generation = 0;
let admitting = false;

export const engineProfileLoaded = (engine: string) => !admitting || loaded.has(engine);
export const onLoadedProfilesChanged = (listener: () => void) => {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
};

function record(engines: string[]) {
  const live = liveEngines();
  let changed = false;
  for (const engine of engines) if (live.has(engine) && !loaded.has(engine)) { loaded.add(engine); changed = true; }
  if (changed) for (const listener of [...listeners]) listener();
}

let liveCache: { profiles: BrowserState["profiles"]; engines: Set<string> } | null = null;

function liveEngines() {
  const profiles = useBrowser.getState().profiles;
  if (liveCache?.profiles !== profiles) liveCache = { profiles, engines: new Set(Object.values(profiles).map((p) => p.dataId ?? p.id).map((id) => id === "default" ? "" : id)) };
  return liveCache.engines;
}

export async function refreshLoadedProfiles() {
  const ticket = generation;
  const engines = await loadedProfiles();
  if (ticket === generation) record(engines);
}

export function startProfileLoading() {
  admitting = true;
  const ticket = ++generation;
  let stopped = false;
  const pending = new Set<string>();
  const failed = new Set<string>();
  const event = onProfileLoaded(({ profile }) => { if (!stopped) record([profile]); });
  const request = (previous?: BrowserState) => {
    const state = useBrowser.getState();
    const pages = profilePageTargets(state, previous, (id) => {
      const tab = state.tabs[id]!;
      return internalPageOf(tab.navigation?.url ?? tab.url) === null && tabEngine(state, id) === "chromium";
    });
    const intents = new Set(pages);
    for (const engine of new Set([...profileLaunchTargets(state), ...pages])) {
      if (loaded.has(engine) || pending.has(engine) || (failed.has(engine) && !intents.has(engine))) continue;
      pending.add(engine);
      void ensureProfile(engine).then((ok) => { if (stopped) return; if (ok) record([engine]); else failed.add(engine); })
        .catch((error) => { failed.add(engine); console.warn("[profiles] loading failed", engine, error); })
        .finally(() => pending.delete(engine));
    }
  };
  const allRequested = () => {
    for (const engine of liveEngines()) if (!loaded.has(engine) && !pending.has(engine)) return false;
    return true;
  };
  let queuedFrom: BrowserState | undefined;
  const requestSoon = (prev: BrowserState) => {
    if (queuedFrom) return;
    queuedFrom = prev;
    void Promise.resolve().then(() => {
      const from = queuedFrom;
      queuedFrom = undefined;
      if (!stopped) request(from);
    });
  };
  const stop = useBrowser.subscribe((s, prev) => {
    if (s.profiles !== prev.profiles || s.windows !== prev.windows) failed.clear();
    if (s.profiles !== prev.profiles) {
      const live = liveEngines();
      for (const engine of loaded) if (!live.has(engine)) loaded.delete(engine);
      if ([...live].some((engine) => !loaded.has(engine))) void loadedProfiles().then((engines) => { if (!stopped) record(engines); }).catch(() => {});
    }
    if (s.windows !== prev.windows || s.profiles !== prev.profiles || s.tabs !== prev.tabs || s.settings.loadAllProfilesAtLaunch !== prev.settings.loadAllProfilesAtLaunch) {
      if (!queuedFrom && allRequested()) return;
      requestSoon(prev);
    }
  });
  void loadedProfiles().then((engines) => { if (!stopped) { record(engines); request(); } })
    .catch((error) => { console.warn("[profiles] inventory unavailable", error); if (!stopped) request(); });
  return () => { stopped = true; stop(); event.remove(); if (ticket === generation) { generation++; loaded.clear(); } };
}
