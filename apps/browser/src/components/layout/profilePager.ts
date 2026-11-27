import { describeProfilePager, switchProfilePager } from "@solara/settings";

if (__DEV__) {
  (globalThis as { acPager?: unknown }).acPager = (windowId: string) => ({
    debug: () => describeProfilePager(windowId),
    switchTo: (profileId: string) => switchProfilePager(windowId, profileId),
  });
}
