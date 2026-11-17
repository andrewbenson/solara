import { useEffect, useState, useSyncExternalStore } from "react";
import { everySlowly } from "../../lib/slowTimers";
import { useBrowser } from "../../store/browser";
import { activeTabId } from "../../store/model";
import { cleanUpCandidates } from "../../store/organize";

const UPSELL_MIN = 10;
let declined = false;
const listeners = new Set<() => void>();

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

export function declineCleanUpUpsell() {
  declined = true;
  for (const listener of listeners) listener();
}

export function cleanUpUpsellChoice(windowId: string, choice: string) {
  const s = useBrowser.getState();
  if (choice === "once") {
    s.cleanUpTabs(windowId);
    declineCleanUpUpsell();
  } else if (choice === "daily") {
    s.updateSettings({ cleanUpInactiveTabsAfterHours: 24 });
    s.cleanUpTabs(windowId);
  } else if (choice === "dontAskAgain") {
    s.updateSettings({ suggestTabCleanUp: false });
  } else if (choice === "dismiss") {
    declineCleanUpUpsell();
  }
}

export function useCleanUpUpsellCount(windowId: string, current: boolean): number {
  const [count, setCount] = useState(0);
  const hidden = useSyncExternalStore(subscribe, () => declined);
  const daily = useBrowser((s) => s.settings.cleanUpInactiveTabsAfterHours !== null);
  const suggest = useBrowser((s) => s.settings.suggestTabCleanUp);
  const tabIds = useBrowser((s) => s.windows[windowId]?.tabIds);
  const profileId = useBrowser((s) => s.windows[windowId]?.profileId);
  const activeId = useBrowser((s) => activeTabId(s, windowId));
  const off = !current || hidden || daily || !suggest;
  useEffect(() => {
    if (off) return;
    const check = () => setCount(cleanUpCandidates(useBrowser.getState(), windowId).length);
    check();
    return everySlowly({ every: 60_000, run: check });
  }, [windowId, off, tabIds, profileId, activeId]);
  return off || count < UPSELL_MIN ? 0 : count;
}
