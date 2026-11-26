import type { DisplayMediaRequest } from "@solara/solaracore";
import { create } from "zustand";
import { useBrowser } from "../../store/browser";

type Store = {
  displayRequests: Record<string, DisplayMediaRequest>;
  tabShares: Record<string, TabShare>;
};

export type TabShare = {
  capturedTabId: string;
  origin: string;
  dismissed: Record<string, true>;
};

export const useMedia = create<Store>()(() => ({ displayRequests: {}, tabShares: {} }));

useBrowser.subscribe((s, prev) => {
  if (s.tabs === prev.tabs) return;
  const m = useMedia.getState();
  const keys = ["displayRequests", "tabShares"] as const;
  const gone = [...new Set(keys.flatMap((k) => Object.keys(m[k])))].filter((id) => !s.tabs[id]);
  if (!gone.length) return;
  const next = Object.fromEntries(keys.map((k) => [k, { ...m[k] }])) as Pick<Store, (typeof keys)[number]>;
  for (const id of gone) for (const k of keys) delete next[k][id];
  useMedia.setState(next);
});

if (typeof __DEV__ !== "undefined" && __DEV__) {
  (globalThis as { acMedia?: unknown }).acMedia = { useMedia };
}
