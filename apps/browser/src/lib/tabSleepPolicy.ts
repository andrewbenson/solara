export type TabSleepConfiguration = {
  idleMs: number;
  protectedRecent: number;
  perSweep: number;
};

export type TabSleepTab = {
  id: string;
  url: string;
  profileId: string;
  lastActiveAt: number;
};

export type TabSleepPressure = "normal" | "warning" | "critical";

export function tabSleepCandidates(input: {
  tabs: readonly TabSleepTab[];
  shownIds: Iterable<string>;
  discardedIds: Iterable<string>;
  loadedIds: readonly string[];
  hiddenAt: Readonly<Record<string, number>>;
  now: number;
  pressure: TabSleepPressure;
  unusedProfileIds: Iterable<string>;
  policy: TabSleepConfiguration;
  keepAliveReasons: Readonly<Record<string, string | null | undefined>>;
}): string[] {
  const { tabs, loadedIds, hiddenAt, now, pressure, policy, keepAliveReasons } = input;
  const shown = new Set(input.shownIds);
  const discarded = new Set(input.discardedIds);
  const unused = new Set(input.unusedProfileIds);
  const byId = new Map(tabs.map((tab) => [tab.id, tab]));
  const recent = new Set(
    tabs.filter((tab) => tab.url)
      .sort((a, b) => b.lastActiveAt - a.lastActiveAt)
      .slice(0, pressure === "critical" ? 0 : policy.protectedRecent)
      .map((tab) => tab.id),
  );
  return loadedIds.filter((id) => {
    const tab = byId.get(id);
    if (!tab || shown.has(id) || discarded.has(id)) return false;
    const idle = now - (hiddenAt[id] ?? now);
    if (!unused.has(tab.profileId) && (recent.has(id) || (pressure === "normal" && idle < policy.idleMs))) return false;
    return !keepAliveReasons[id];
  }).sort((a, b) => (hiddenAt[a] ?? now) - (hiddenAt[b] ?? now));
}

export function unusedTabSleepProfiles(input: {
  profileIds: readonly string[];
  shownProfileIds: Iterable<string>;
  unusedSince: Readonly<Record<string, number>>;
  now: number;
  idleMs: number;
}): { unusedSince: Record<string, number>; eligibleIds: string[] } {
  const { profileIds, now, idleMs } = input;
  const shown = new Set(input.shownProfileIds);
  const unusedSince: Record<string, number> = {};
  const eligibleIds: string[] = [];
  for (const id of profileIds) {
    if (shown.has(id)) continue;
    const since = input.unusedSince[id] ?? now;
    unusedSince[id] = since;
    if (now - since >= idleMs) eligibleIds.push(id);
  }
  return { unusedSince, eligibleIds };
}
