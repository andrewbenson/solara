type ProfilePage = {
  profileId: string;
  url: string;
  navigation?: { url: string; seq: number } | null;
  adoptId?: string;
  unloaded?: boolean;
  engine?: string;
};

type ProfileState = {
  profiles: Record<string, { id: string; dataId?: string }>;
  windows: Record<string, { profileId: string; incognito: boolean; originalProfileId?: string }>;
  settings: { loadAllProfilesAtLaunch?: boolean };
  tabs?: Record<string, ProfilePage>;
};

export function regularEngineFor(state: ProfileState, profileId: string): string | null {
  const original = profileId.startsWith("incognito:") ? profileId.slice(profileId.indexOf("@") + 1) : profileId;
  const profile = state.profiles[original];
  if (!profile) return null;
  const id = profile.dataId ?? profile.id;
  return id === "default" ? "" : id;
}

export function profileLaunchTargets(state: ProfileState): string[] {
  const ids = state.settings.loadAllProfilesAtLaunch
    ? Object.keys(state.profiles).filter((id) => !id.startsWith("incognito:"))
    : Object.values(state.windows).map((window) => window.incognito ? window.originalProfileId ?? window.profileId : window.profileId);
  return [...new Set(ids.map((id) => regularEngineFor(state, id)).filter((engine): engine is string => engine !== null))];
}


export function profilePageTargets(state: ProfileState, previous?: ProfileState, needsProfile: (id: string) => boolean = () => true): string[] {
  const targets = new Set<string>();
  const tabs = state.tabs ?? {};
  const previousTabs = previous?.tabs;
  const sameProfiles = previous?.profiles === state.profiles;
  for (const id in tabs) {
    const tab = tabs[id]!;
    const before = previousTabs?.[id];
    if (before === tab && sameProfiles) continue;
    if (tab.unloaded || (!tab.navigation?.url && !tab.adoptId)) continue;
    const engine = regularEngineFor(state, tab.profileId);
    if (engine === null) continue;
    if (before && !before.unloaded && previous && regularEngineFor(previous, before.profileId) === engine &&
      before.navigation?.seq === tab.navigation?.seq && before.navigation?.url === tab.navigation?.url &&
      before.adoptId === tab.adoptId && before.engine === tab.engine) continue;
    if (!needsProfile(id)) continue;
    targets.add(engine);
  }
  return [...targets];
}
