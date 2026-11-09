import type { KeepAliveKeep, KeepAliveReveal, PageIdentity, PageReport } from "@solara/store";

type Snapshot = { route: string; keep: KeepAliveKeep; reveal: KeepAliveReveal };
type Host = "rn" | "pool";
type Options = {
  running(): boolean;
  register(): number;
  read(identity: PageIdentity): Snapshot | "pending" | null;
  send(id: string, report: Extract<PageReport, { type: "keepAlive" }>): void;
  schedule(run: () => void): void;
  waiting?(pending: boolean): void;
};
type Page = { identity: PageIdentity; host: Host; handled: number; route: string | null; sent: string | null; resend: boolean; failed: boolean };
const sameIdentity = (a: PageIdentity, b: PageIdentity) => a.tabId === b.tabId && a.sessionGeneration === b.sessionGeneration && a.registrationGeneration === b.registrationGeneration;

export function createKeepAliveFeed(options: Options) {
  const pages = new Map<string, Page>();
  const registrations = new Map<string, number>();
  let epoch = 0;
  let seq = 0;
  let scheduled = false;
  let renew = false;
  const changed = () => {
    if (scheduled) return;
    scheduled = true;
    options.schedule(flush);
  };
  const flush = () => {
    scheduled = false;
    if (!options.running()) {
      epoch = 0;
      options.waiting?.(false);
      return;
    }
    if (!epoch || renew) {
      epoch = options.register();
      seq = 0;
      renew = false;
      for (const page of pages.values()) page.resend = true;
    }
    let pending = false;
    for (const [id, page] of pages) {
      if (page.failed) continue;
      const snapshot = options.read(page.identity);
      if (!snapshot || snapshot === "pending") {
        if (snapshot === "pending") pending = true;
        page.sent = null;
        page.route = null;
        page.resend = true;
        continue;
      }
      if (page.route !== null && page.route !== snapshot.route) page.resend = true;
      page.route = snapshot.route;
      const value = JSON.stringify({ keep: snapshot.keep, reveal: snapshot.reveal, handled: page.handled });
      if (!page.resend && value === page.sent) continue;
      if (!options.running()) return;
      if (!Number.isSafeInteger(seq + 1)) throw new Error("keepalive sequence exhausted");
      options.send(id, { type: "keepAlive", generation: page.identity.sessionGeneration, epoch, seq: ++seq, handled: page.handled, keep: snapshot.keep, reveal: snapshot.reveal });
      page.sent = value;
      page.resend = false;
    }
    options.waiting?.(pending);
  };
  return {
    changed,
    tracks: () => pages.size > 0,
    created(identity: PageIdentity, host: Host) {
      const previous = pages.get(identity.tabId);
      const registration = registrations.get(identity.tabId);
      if (host === "rn" && registration !== undefined && registration !== identity.registrationGeneration) renew = true;
      registrations.set(identity.tabId, identity.registrationGeneration);
      const sameSession = previous?.identity.sessionGeneration === identity.sessionGeneration;
      pages.set(identity.tabId, { identity, host, handled: sameSession ? previous.handled : 0, route: null, sent: null, resend: true, failed: sameSession ? previous.failed : false });
      changed();
    },
    handled(identity: PageIdentity, eventSeq: number | undefined) {
      const page = pages.get(identity.tabId);
      if (!page || !sameIdentity(page.identity, identity) || !Number.isSafeInteger(eventSeq) || eventSeq! < 0) return;
      page.handled = Math.max(page.handled, eventSeq!);
      changed();
    },
    failed(identity: PageIdentity) {
      const page = pages.get(identity.tabId);
      if (page && sameIdentity(page.identity, identity)) page.failed = true;
    },
    gone(identity: PageIdentity) {
      const page = pages.get(identity.tabId);
      if (page && sameIdentity(page.identity, identity)) pages.delete(identity.tabId);
    },
  };
}

type Observer = {
  created(identity: PageIdentity, host: Host): void;
  handled(identity: PageIdentity, eventSeq: number | undefined): void;
  gone(identity: PageIdentity): void;
  failed(identity: PageIdentity): void;
};
const observers = new Set<Observer>();
const current = new Map<string, { identity: PageIdentity; host: Host; handled: number; failed: boolean }>();
export const keepAliveCreated = (identity: PageIdentity, host: Host) => {
  const previous = current.get(identity.tabId);
  const sameSession = previous?.identity.sessionGeneration === identity.sessionGeneration;
  current.set(identity.tabId, { identity, host, handled: sameSession ? previous.handled : 0, failed: sameSession ? previous.failed : false });
  for (const observer of observers) observer.created(identity, host);
};
export const keepAliveHandled = (identity: PageIdentity, eventSeq: number | undefined) => {
  const page = current.get(identity.tabId);
  if (!page || !sameIdentity(page.identity, identity) || !Number.isSafeInteger(eventSeq) || eventSeq! < 0) return;
  page.handled = Math.max(page.handled, eventSeq!);
  for (const observer of observers) observer.handled(identity, eventSeq);
};
export const keepAliveFailed = (identity: PageIdentity) => {
  const page = current.get(identity.tabId);
  if (!page || !sameIdentity(page.identity, identity)) return;
  page.failed = true;
  for (const observer of observers) observer.failed(identity);
};
export const keepAliveGone = (identity: PageIdentity) => {
  const page = current.get(identity.tabId);
  if (page && sameIdentity(page.identity, identity)) current.delete(identity.tabId);
  for (const observer of observers) observer.gone(identity);
};
export function observeKeepAlive(observer: Observer) {
  observers.add(observer);
  for (const { identity, host, handled, failed } of current.values()) {
    observer.created(identity, host);
    observer.handled(identity, handled);
    if (failed) observer.failed(identity);
  }
  return () => { observers.delete(observer); };
}
