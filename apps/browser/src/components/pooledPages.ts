import { pooledWebViewHandle, unwrapPageEvent, type PageEngine, type ViewEventName } from "@solara/solaracore";
import type { TabPool } from "@solara/settings";
import { persistEngine } from "../lib/engines";
import { holdModuleEvent } from "../lib/nativeEvents";
import { noteGone } from "../lib/tabLifecycle";
import { notePooledPage, webviewRef } from "../lib/webviews";
import { useBrowser, type BrowserState } from "../store/browser";
import { engineProfile } from "../store/model";
import { setPageProgress } from "../store/pageProgress";
import { followNavigation, newPageSession, pageEventHandlers, type PageEventHandlers, type PageSession } from "./pageEvents";

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

function pageCreated(pool: TabPool, tabId: string, engine: PageEngine, seq: number) {
  pageGone(tabId);
  const s = useBrowser.getState();
  const navigation = s.tabs[tabId]?.navigation;
  const loadedSeq = seq >= 0 ? seq : navigation?.seq;
  const session = newPageSession(tabId, engine, peekSource(s, tabId), loadedSeq === undefined ? null : { seq: loadedSeq });
  const register = webviewRef(tabId);
  register(pooledWebViewHandle((method, args) => pool.pageCall(tabId, method, args)));
  notePooledPage(tabId, true);
  pooled.set(tabId, { session, handlers: pageEventHandlers(session), register, seq: navigation?.seq, windowId: s.tabs[tabId]?.windowId, followed: null, loadedSeq });
  persistEngine(tabId, engine);
  followLater(tabId);
}

function pageGone(tabId: string) {
  const page = pooled.get(tabId);
  if (!page) return;
  pooled.delete(tabId);
  notePooledPage(tabId, false);
  page.register(null);
  noteGone(tabId);
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
    followLater(tabId);
  }
}

function pageEvent(tabId: string, name: ViewEventName, payload: unknown) {
  const handlers: Partial<Record<ViewEventName, (...args: never[]) => void>> | undefined = pooled.get(tabId)?.handlers;
  const handler = handlers?.[name] as ((...args: unknown[]) => void) | undefined;
  if (!handler) return;
  holdModuleEvent(`top${name.slice(2)}`, () => handler(...unwrapPageEvent(name, payload as never)));
}

export function startPooledPages(pool: TabPool) {
  const events = pool.addListener("onPageEvent", ({ tabId, name, payload }) => {
    if (name === "onPageCreated") {
      const { engine, seq } = payload as { engine: PageEngine; seq: number };
      pageCreated(pool, tabId, engine, seq);
    } else if (name === "onPageGone") pageGone(tabId);
    else pageEvent(tabId, name as ViewEventName, payload);
  });
  const stopStore = useBrowser.subscribe(followStore);
  void pool.livePages?.().then((live) => {
    for (const { tabId, engine, ready, navigation } of live) {
      if (pooled.has(tabId)) continue;
      pageCreated(pool, tabId, engine as PageEngine, -1);
      if (ready) pageEvent(tabId, "onReady", ready);
      if (navigation) pageEvent(tabId, "onNavigationChange", navigation);
    }
  });
  return () => {
    events.remove();
    stopStore();
    for (const tabId of [...pooled.keys()]) pageGone(tabId);
  };
}
