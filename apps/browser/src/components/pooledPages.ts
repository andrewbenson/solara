import { pooledWebViewHandle, unwrapPageEvent, type PageEngine, type ViewEventName } from "@solara/solaracore";
import { isPageCurrent } from "@solara/store";
import type { PooledPageEvent, PooledPageIdentity, TabPool } from "@solara/settings";
import { keepAliveCreated, keepAliveHandled } from "../lib/keepAliveFeed";
import { persistEngine } from "../lib/engines";
import { holdModuleEvent } from "../lib/nativeEvents";
import { noteGone } from "../lib/tabLifecycle";
import { notePooledPage, webviewRef } from "../lib/webviews";
import { useBrowser, type BrowserState } from "../store/browser";
import { nativeOwnsWorkspace } from "../store/nativeStore";
import { engineProfile } from "../store/model";
import { setPageProgress } from "../store/pageProgress";
import { deliverPageEvent, followNavigation, newPageSession, observePageIdentity, pageEventHandlers, publishPageContext, releasePageSession, type PageEventHandlers, type PageSession } from "./pageEvents";

type PooledPage = {
  session: PageSession;
  handlers: PageEventHandlers;
  register: ReturnType<typeof webviewRef>;
  seq: number | undefined;
  windowId: string | undefined;
  followed: number | undefined | null;
  loadedSeq: number | undefined;
};

const pooled = new Map<string, PooledPage>();

const peekSource = (s: BrowserState, tabId: string) => {
  const t = s.tabs[tabId];
  const peek = t ? s.peeks[t.windowId] : undefined;
  return peek?.tabId === tabId ? peek.sourceId : undefined;
};

const following = new Set<string>();

const leftProfile = (tab: BrowserState["tabs"][string] | undefined, page: PooledPage) =>
  !!tab && engineProfile(tab.profileId) !== engineProfile(page.session.profileId);

function followLater(tabId: string) {
  if (following.size === 0) queueMicrotask(followNow);
  following.add(tabId);
}

function followNow() {
  const tabs = useBrowser.getState().tabs;
  const ids = [...following];
  following.clear();
  for (const tabId of ids) {
    const page = pooled.get(tabId);
    if (!page || leftProfile(tabs[tabId], page)) continue;
    const navigation = tabs[tabId]?.navigation;
    if (navigation?.seq === page.followed) continue;
    if (page.followed === null && navigation?.seq !== page.loadedSeq) page.session.arrived = false;
    page.followed = navigation?.seq;
    followNavigation(page.session, navigation);
  }
}

function pageCreated(pool: TabPool, tabId: string, engine: PageEngine, seq: number, identity?: PooledPageIdentity, contextRevision?: number) {
  if (identity && !isPageCurrent(identity)) return;
  const previousIdentity = pooled.get(tabId)?.session.identity;
  const sameIdentity = !!identity && previousIdentity?.sessionGeneration === identity.sessionGeneration && previousIdentity.registrationGeneration === identity.registrationGeneration;
  pageGone(tabId, sameIdentity);
  const s = useBrowser.getState();
  const navigation = s.tabs[tabId]?.navigation;
  const loadedSeq = seq >= 0 ? seq : navigation?.seq;
  const session = newPageSession(tabId, engine, peekSource(s, tabId), loadedSeq === undefined ? null : { seq: loadedSeq });
  if (identity && !observePageIdentity(session, identity, "native", contextRevision)) return;
  const register = webviewRef(tabId);
  register(pooledWebViewHandle((method, args) => pool.pageCall(tabId, method, args, identity?.registrationGeneration)));
  notePooledPage(tabId, true);
  pooled.set(tabId, { session, handlers: pageEventHandlers(session), register, seq: navigation?.seq, windowId: s.tabs[tabId]?.windowId, followed: null, loadedSeq });
  persistEngine(tabId, engine);
  if (identity) {
    keepAliveCreated(identity, "pool");
    publishPageContext(tabId);
  }
  else followLater(tabId);
}

function pageGone(tabId: string, preserveKeepAlive = false) {
  const page = pooled.get(tabId);
  if (!page) return;
  pooled.delete(tabId);
  notePooledPage(tabId, false);
  page.register(null);
  releasePageSession(page.session, preserveKeepAlive);
  if (page.session.factsOwner === "js") noteGone(tabId);
  setPageProgress(tabId, 0);
}

function followStore(s: BrowserState, prev: BrowserState) {
  if (s.tabs === prev.tabs && s.peeks === prev.peeks) return;
  for (const [tabId, page] of pooled) {
    const tab = s.tabs[tabId];
    if (leftProfile(tab, page)) continue;
    const sameProfile = !tab || page.session.profileId === tab.profileId;
    if (tab) {
      page.session.profileId = tab.profileId;
      page.session.adoptId = tab.adoptId;
    }
    page.session.peekOf = peekSource(s, tabId);
    const moved = !!tab && tab.windowId !== page.windowId;
    if (tab) page.windowId = tab.windowId;
    const seq = tab?.navigation?.seq;
    if (seq === page.seq) continue;
    page.seq = seq;
    if (tab && moved && sameProfile) page.session.arrived = true;
    if (page.session.navigationOwner === "js") followLater(tabId);
  }
}

function pageEvent(tabId: string, name: ViewEventName, payload: unknown, identity?: PooledPageIdentity, eventSeq?: number) {
  const page = pooled.get(tabId);
  if (!page) return;
  if (identity) {
    holdModuleEvent(`top${name.slice(2)}`, () => { deliverPageEvent(page.session, name, payload, identity, eventSeq); });
    return;
  }
  if (page.session.factsOwner === "native") return;
  const handler = page.handlers[name as keyof PageEventHandlers] as ((...args: unknown[]) => void) | undefined;
  if (handler) holdModuleEvent(`top${name.slice(2)}`, () => handler(...unwrapPageEvent(name, payload as never)));
}

export function startPooledPages(pool: TabPool) {
  const events = pool.addListener("onPageEvent", (event: PooledPageEvent) => {
    const { tabId, name, payload } = event;
    const identity = typeof event.sessionGeneration === "string" && !!event.sessionGeneration && Number.isSafeInteger(event.registrationGeneration) && event.registrationGeneration > 0
      ? { tabId, sessionGeneration: event.sessionGeneration, registrationGeneration: event.registrationGeneration } : undefined;
    if (!identity && nativeOwnsWorkspace()) return;
    if (name === "onPageCreated") {
      const { engine, seq } = payload as { engine: PageEngine; seq: number };
      pageCreated(pool, tabId, engine, seq, identity, event.contextRevision);
      if (identity && isPageCurrent(identity)) keepAliveHandled(identity, (event as PooledPageEvent & { eventSeq?: number }).eventSeq);
    } else if (name === "onPageGone") {
      const current = pooled.get(tabId)?.session.identity;
      if (!identity || (current?.sessionGeneration === identity.sessionGeneration && current.registrationGeneration === identity.registrationGeneration)) pageGone(tabId);
    } else pageEvent(tabId, name as ViewEventName, payload, identity, (event as PooledPageEvent & { eventSeq?: number }).eventSeq);
  });
  const stopStore = useBrowser.subscribe(followStore);
  void pool.livePages?.().then((live) => {
    for (const { tabId, engine, ready, navigation, sessionGeneration, registrationGeneration, contextRevision } of live) {
      if (pooled.has(tabId)) continue;
      const identity = typeof sessionGeneration === "string" && !!sessionGeneration && Number.isSafeInteger(registrationGeneration) && registrationGeneration > 0
        ? { tabId, sessionGeneration, registrationGeneration } : undefined;
      if (!identity && nativeOwnsWorkspace()) continue;
      pageCreated(pool, tabId, engine as PageEngine, -1, identity, contextRevision);
      if (ready) pageEvent(tabId, "onReady", ready, identity);
      if (navigation) pageEvent(tabId, "onNavigationChange", navigation, identity);
    }
  });
  return () => {
    events.remove();
    stopStore();
    for (const tabId of [...pooled.keys()]) pageGone(tabId);
  };
}
