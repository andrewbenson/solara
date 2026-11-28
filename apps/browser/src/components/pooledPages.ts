import { pooledWebViewHandle, type PageEngine, type ViewEventName } from "@solara/solaracore";
import { isPageCurrent } from "@solara/store";
import type { PooledPageEvent, PooledPageIdentity, TabPool } from "@solara/settings";
import { keepAliveHandled } from "../lib/keepAliveFeed";
import { holdModuleEvent } from "../lib/nativeEvents";
import { notePooledPage, webviewRef } from "../lib/webviews";
import { setPageProgress } from "../store/pageProgress";
import { deliverPageEvent, newPageSession, observePageIdentity, publishPageContext, releasePageSession, type PageSession } from "./pageEvents";

type PooledPage = {
  session: PageSession;
  register: ReturnType<typeof webviewRef>;
};

const pooled = new Map<string, PooledPage>();

function pageIdentity({ tabId, sessionGeneration, registrationGeneration }: PooledPageIdentity): PooledPageIdentity | undefined {
  if (typeof sessionGeneration !== "string" || !sessionGeneration || !Number.isSafeInteger(registrationGeneration) || registrationGeneration <= 0) return;
  return { tabId, sessionGeneration, registrationGeneration };
}

function pageCreated(pool: TabPool, engine: PageEngine, seq: number, identity: PooledPageIdentity, contextRevision?: number) {
  const { tabId, registrationGeneration, sessionGeneration } = identity;
  if (!isPageCurrent(identity)) return;
  const previous = pooled.get(tabId)?.session.identity;
  const sameIdentity = previous?.sessionGeneration === sessionGeneration && previous.registrationGeneration === registrationGeneration;
  pageGone(tabId, sameIdentity);
  const session = newPageSession(tabId, engine, seq < 0 ? null : { seq });
  if (!observePageIdentity(session, identity, "pool", contextRevision)) return;
  const register = webviewRef(tabId);
  register(pooledWebViewHandle((method, args) => pool.pageCall(tabId, method, args, registrationGeneration)));
  notePooledPage(tabId, true);
  pooled.set(tabId, { session, register });
  publishPageContext(tabId);
}

function pageGone(tabId: string, preserveKeepAlive = false) {
  const page = pooled.get(tabId);
  if (!page) return;
  pooled.delete(tabId);
  notePooledPage(tabId, false);
  page.register(null);
  releasePageSession(page.session, preserveKeepAlive);
  setPageProgress(tabId, 0);
}

function pageEvent(identity: PooledPageIdentity, name: ViewEventName, payload: unknown, eventSeq?: number) {
  const page = pooled.get(identity.tabId);
  if (!page) return;
  holdModuleEvent(`top${name.slice(2)}`, () => { deliverPageEvent(page.session, name, payload, identity, eventSeq); });
}

export function startPooledPages(pool: TabPool) {
  const events = pool.addListener("onPageEvent", (event: PooledPageEvent) => {
    const identity = pageIdentity(event);
    if (!identity) return;
    const { tabId, name, payload } = event;
    if (name === "onPageCreated") {
      const { engine, seq } = payload as { engine: PageEngine; seq: number };
      pageCreated(pool, engine, seq, identity, event.contextRevision);
      if (isPageCurrent(identity)) keepAliveHandled(identity, event.eventSeq);
    } else if (name === "onPageGone") {
      const current = pooled.get(tabId)?.session.identity;
      if (current?.sessionGeneration === identity.sessionGeneration && current.registrationGeneration === identity.registrationGeneration) pageGone(tabId);
    } else pageEvent(identity, name as ViewEventName, payload, event.eventSeq);
  });
  let stopped = false;
  void pool.livePages?.().then((live) => {
    if (stopped) return;
    for (const page of live) {
      if (pooled.has(page.tabId)) continue;
      const identity = pageIdentity(page);
      if (!identity) continue;
      pageCreated(pool, page.engine as PageEngine, -1, identity, page.contextRevision);
      if (page.ready) pageEvent(identity, "onReady", page.ready);
      if (page.navigation) pageEvent(identity, "onNavigationChange", page.navigation);
    }
  });
  return () => {
    stopped = true;
    events.remove();
    for (const tabId of [...pooled.keys()]) pageGone(tabId);
  };
}
