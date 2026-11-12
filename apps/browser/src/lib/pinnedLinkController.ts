import { resolvePinnedLink, type PinnedLinkTarget } from "@solara/core";
import type { PinnedLinkEvent } from "@solara/solaracore";

export type PinnedLinkSource = {
  id: string;
  identity: string;
  url: string;
  pinned: boolean;
  topApp: boolean;
  target: PinnedLinkTarget;
  incognito: boolean;
};

export type PinnedLinkRoute = PinnedLinkTarget | "background";
export type PinnedLinkPoint = { x: number; y: number };

type Pending = { source: PinnedLinkSource; url: string; target: PinnedLinkTarget; expires: number };

type Ports = {
  source(id: string): PinnedLinkSource | null;
  present(id: string): boolean;
  answer(requestId: string, intercept: boolean): Promise<boolean>;
  open(source: PinnedLinkSource, url: string, route: PinnedLinkRoute, point: PinnedLinkPoint | null): void;
  now?: () => number;
};

const DECISION_LIFETIME_MS = 30000;
const MAX_PENDING = 128;
const MAX_SEEN = 256;

const withoutFragment = (url: string) => url.split("#", 1)[0]!;

const pointOf = (event: PinnedLinkEvent): PinnedLinkPoint | null =>
  event.point && Number.isFinite(event.point.x) && Number.isFinite(event.point.y) ? { x: event.point.x, y: event.point.y } : null;

export function pinnedLinkController({ source, present, answer, open, now = Date.now }: Ports) {
  const pending = new Map<string, Pending>();
  const seen = new Map<string, number>();
  return (event: PinnedLinkEvent) => {
    const time = now();
    for (const [id, expires] of seen) if (expires <= time) seen.delete(id);
    for (const [id, decision] of pending) if (decision.expires <= time) pending.delete(id);
    if (event.phase === "intercepted") {
      const decision = pending.get(event.requestId);
      pending.delete(event.requestId);
      if (!decision) return;
      const current = source(decision.source.id);
      const intact = !!current && current.identity === decision.source.identity && withoutFragment(current.url) === withoutFragment(event.sourceURL);
      if (intact) open(current, decision.url, decision.target, pointOf(event));
      else if (present(decision.source.id)) open(decision.source, decision.url, "background", null);
      return;
    }
    if (event.phase !== "decide" || seen.has(event.requestId)) return;
    seen.set(event.requestId, time + DECISION_LIFETIME_MS);
    if (seen.size > MAX_SEEN) seen.delete(seen.keys().next().value!);
    let current: PinnedLinkSource | null = null;
    let decision: ReturnType<typeof resolvePinnedLink> = null;
    try {
      current = source(event.sourceId);
      decision = current && withoutFragment(current.url) === withoutFragment(event.sourceURL) && pending.size < MAX_PENDING ? resolvePinnedLink({
        sourceUrl: current.url,
        targetUrl: event.url,
        pinned: current.pinned,
        topApp: current.topApp,
        isMainFrame: true,
        userGesture: true,
        navigationType: "link",
        method: "GET",
        download: false,
        hasOpener: false,
        disposition: event.newWindow ? "newTab" : "current",
        modified: false,
        target: current.target,
      }) : null;
    } catch {
      decision = null;
    }
    if (decision && current) {
      const target = current.incognito && decision.target === "littleSolara" ? "tab" : decision.target;
      pending.set(event.requestId, { source: current, url: decision.url, target, expires: time + DECISION_LIFETIME_MS });
    }
    void answer(event.requestId, !!decision).then((accepted) => {
      if (!accepted) pending.delete(event.requestId);
    }, () => pending.delete(event.requestId));
  };
}
