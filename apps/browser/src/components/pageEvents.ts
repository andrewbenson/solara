import { unwrapPageEvent, type OpenWindowRequest, type PageEngine, type PageCreated, type PageIssue, type StoreReportDisposition, type ViewEventName, type WebViewProps } from "@solara/solaracore";
import { finishRNPageIssue, isPageCurrent, pageReport, updatePageContext, type PageContext, type PageIdentity, type PageIssuePreview } from "@solara/store";
import { nativeOwnsWorkspace } from "../store/nativeStore";
import { focus, switchToTab } from "../lib/actions";
import { adoptIconPage, dropOutlivedFavicon, noteFavicon, noteIconPage } from "../lib/favicons";
import { restoredThemeColor } from "../lib/launchLook";
import { takeStartedNavigation } from "../lib/earlyNavigate";
import { isQuitting } from "../lib/native";
import { noteDiscarded, noteReady } from "../lib/tabLifecycle";
import { clearEngineOffer, followSiteChoice, noteWebKitPage, offerWebKit } from "../lib/engines";
import { noteIssued, webviews } from "../lib/webviews";
import { handoffLoaded } from "../lib/pageHandoff";
import { useBrowser } from "../store/browser";
import { setPageProgress } from "../store/pageProgress";
import { engineProfile, navigationTo } from "../store/model";
import { splitOf } from "../store/splits";
import type { Tab } from "../store/types";
import { dismissPermissions } from "./site/permissions";
import { patchPage, pageOf, setBrowserId, setPopover, usePages } from "./layout/pageState";
import { openFromPage } from "./layout/openFromPage";
import { closeFolderPanelIn } from "./sidebar/tileFolderUi";
import { answerExternalApp, shouldPromptForPopups, showAutofillPrompt, showPasswordPrompt } from "./site/Prompts";
import { copyLinkToSelection, searchSelection, setPageSelection, type PageSelection } from "./site/selection";
import { requestDisplayMedia } from "./media/SharePicker";
import { setNowPlaying, setPictureInPictureState } from "./media/state";
import { noteScroll, revealToolbar } from "./layout/toolbarAutoHide";
import { closeWebNotification, showWebNotification } from "../lib/webNotifications";
import { closeLittleSolaraOnEscape } from "./littleSolara/actions";
import { closePeekOnEscape } from "./peek/actions";

export type PageSession = {
  tabId: string;
  factsOwner: "js" | "native";
  navigationOwner: "js" | "native";
  identity: PageIdentity | null;
  following: boolean;
  followAgain: boolean;
  engine: PageEngine;
  peekOf: string | undefined;
  profileId: string;
  adoptId: string | undefined;
  pending: string | null;
  lastPage: string | null;
  adopted: string | null;
  fromNewTab: boolean;
  arrived: boolean;
  loadsOnCreateSeq: number | undefined;
};

export type PageEventName =
  | "onPageCreated"
  | "onPageIssue"
  | "onReady"
  | "onNavigationChange"
  | "onLoadError"
  | "onDownloadNavigation"
  | "onProgress"
  | "onZoom"
  | "onFindResult"
  | "onFavicon"
  | "onMedia"
  | "onNowPlaying"
  | "onPictureInPicture"
  | "onDisplayMediaRequest"
  | "onOpenWindow"
  | "onStatus"
  | "onCrashed"
  | "onUnresponsive"
  | "onResponsive"
  | "onFullscreen"
  | "onMediaAccess"
  | "onSecurity"
  | "onContentBlocked"
  | "onPopupBlocked"
  | "onPasswordPrompt"
  | "onAutofillPrompt"
  | "onExternalApp"
  | "onPageFocus"
  | "onPagePress"
  | "onWindowClose"
  | "onNotification"
  | "onCommand"
  | "onPageMessage"
  | "onNotificationClose"
  | "onDiscarded"
  | "onActivateRequest";

export type PageEventHandlers = Required<Pick<WebViewProps, PageEventName>>;

const isBlank = (url: string) => !url || url === "about:blank";
const pageKey = (url: string) => url.replace(/#.*$/, "");
const hostOf = (url: string) => url.match(/^[a-z][\w+.-]*:\/\/([^/?#]*)/i)?.[1]?.toLowerCase() ?? "";

export function newPageSession(tabId: string, engine: PageEngine, peekOf: string | undefined, handoff: { seq?: number } | null): PageSession {
  const t = useBrowser.getState().tabs[tabId];
  const navigation = t?.navigation;
  const adoptId = t?.adoptId;
  return {
    tabId,
    factsOwner: nativeOwnsWorkspace() ? "native" : "js",
    navigationOwner: "js",
    identity: null,
    following: false,
    followAgain: false,
    engine,
    peekOf,
    profileId: t?.profileId ?? "",
    adoptId,
    pending: navigation?.url ?? (adoptId ? (t?.url ?? null) : null),
    lastPage: null,
    adopted: null,
    fromNewTab: pageOf(tabId).wasNewTab && !adoptId,
    arrived: handoffLoaded(handoff, navigation?.seq),
    loadsOnCreateSeq: engine === "webkit" && !handoff ? navigation?.seq : undefined,
  };
}

const sessions = new Map<string, PageSession>();
const contexts = new Map<string, PageContext>();

export function currentPageContext(tabId: string): PageContext {
  const page = pageOf(tabId);
  const previous = contexts.get(tabId);
  const value = { navigationSeq: useBrowser.getState().tabs[tabId]?.navigation?.seq ?? null, wasNewTab: !!page.wasNewTab, newTabShownUrl: page.newTabShown?.url ?? null };
  if (previous && previous.navigationSeq === value.navigationSeq && previous.wasNewTab === value.wasNewTab && previous.newTabShownUrl === value.newTabShownUrl) return previous;
  const contextRevision = (previous?.contextRevision ?? 0) + 1;
  if (!Number.isSafeInteger(contextRevision)) throw new Error("page context revision exhausted");
  const context = { ...value, contextRevision };
  contexts.set(tabId, context);
  return context;
}

export function publishPageContext(tabId: string): PageContext {
  const context = currentPageContext(tabId);
  const session = sessions.get(tabId);
  if (session?.identity) updatePageContext(session.identity, context);
  return context;
}

export function releasePageSession(session: PageSession) {
  if (sessions.get(session.tabId) === session) sessions.delete(session.tabId);
}

export function observePageIdentity(session: PageSession, identity: PageIdentity, navigationOwner: "js" | "native" = "js", nativeContextRevision?: number): boolean {
  if (identity.tabId !== session.tabId || !isPageCurrent(identity)) return false;
  if (!session.identity || session.identity.sessionGeneration !== identity.sessionGeneration || session.identity.registrationGeneration !== identity.registrationGeneration) session.identity = identity;
  session.factsOwner = "native";
  session.navigationOwner = navigationOwner;
  sessions.set(session.tabId, session);
  if (nativeContextRevision !== undefined && Number.isSafeInteger(nativeContextRevision) && nativeContextRevision >= 0) {
    const context = currentPageContext(session.tabId);
    const contextRevision = Math.max(context.contextRevision, nativeContextRevision + 1);
    if (!Number.isSafeInteger(contextRevision)) throw new Error("page context revision exhausted");
    contexts.set(session.tabId, { ...context, contextRevision });
  }
  return true;
}

export function acceptPageReport(session: PageSession, report: StoreReportDisposition): boolean {
  if (report.kind === "rejected") return false;
  if (report.kind === "fallback") return session.factsOwner === "js";
  return observePageIdentity(session, { tabId: session.tabId, sessionGeneration: report.sessionGeneration, registrationGeneration: report.registrationGeneration }, session.navigationOwner);
}

export function deliverPageEvent(session: PageSession, name: ViewEventName, payload: unknown, identity: PageIdentity): boolean {
  if (!isPageCurrent(identity) || session.identity?.sessionGeneration !== identity.sessionGeneration || session.identity.registrationGeneration !== identity.registrationGeneration) return false;
  const handler = pageEventHandlers(session)[name as PageEventName] as ((...args: unknown[]) => void) | undefined;
  if (!handler) return false;
  const eventPayload = name === "onPageCreated" || name === "onPageIssue" ? { ...(payload as object), ...identity } : payload;
  handler(...unwrapPageEvent(name, eventPayload as never));
  return true;
}

export function followNavigation(session: PageSession, navigation: Tab["navigation"] | undefined, allowRetry = true) {
  const { tabId } = session;
  if (session.navigationOwner === "native") return;
  if (session.factsOwner === "native") {
    if (!session.identity || !isPageCurrent(session.identity)) return;
    if (session.following) { session.followAgain = true; return; }
    const context = publishPageContext(tabId);
    const response = pageReport(tabId, { type: "issued", generation: session.identity.sessionGeneration, navigation: navigation ?? null, startedEarly: false, ...context });
    const preview = response?.result as PageIssuePreview | undefined;
    if (!preview?.guard) return;
    session.following = true;
    const identity = session.identity;
    let retryRejected = false;
    void finishRNPageIssue(tabId, preview.guard).then(({ accepted }) => {
      retryRejected = !accepted && allowRetry;
    }).catch(() => {
      retryRejected = allowRetry;
    }).finally(() => {
      session.following = false;
      const requestedAgain = session.followAgain;
      session.followAgain = false;
      if ((requestedAgain || retryRejected) && session.identity === identity && isPageCurrent(identity)) {
        queueMicrotask(() => followNavigation(session, useBrowser.getState().tabs[tabId]?.navigation, requestedAgain));
      }
    });
    return;
  }
  if (!navigation) return;
  noteIssued(tabId, navigation.seq);
  if (session.arrived) {
    session.arrived = false;
    return;
  }
  if (navigation.url === session.adopted) {
    session.adopted = null;
    return;
  }
  session.pending = navigation.url;
  if (pageOf(tabId).newTabShown) patchPage(tabId, { newTabShown: null });
  if (session.loadsOnCreateSeq === navigation.seq) {
    session.loadsOnCreateSeq = undefined;
    return;
  }
  if (takeStartedNavigation(tabId, navigation.seq)) return;
  void webviews.get(tabId)?.loadUrl(navigation.url, { userInitiated: !!navigation.userInitiated });
}

export function pageEventHandlers(session: PageSession): PageEventHandlers {
  const { tabId, engine } = session;
  const tab = () => useBrowser.getState().tabs[tabId];
  const store = () => useBrowser.getState();
  const prewarmOnly = () => !tab()?.navigation && !session.adoptId;
  const activateSplitPane = () => {
    const t = tab();
    if (t && splitOf(store(), tabId) && store().windows[t.windowId]?.activeTabIds[t.profileId] !== tabId) store().activate(tabId);
  };

  const handlers: PageEventHandlers = {
    onPageCreated: (created: PageCreated) => {
      if (!observePageIdentity(session, created, session.navigationOwner)) return;
      publishPageContext(tabId);
      followNavigation(session, tab()?.navigation);
    },
    onPageIssue: (issue: PageIssue) => {
      if (!session.identity || issue.sessionGeneration !== session.identity.sessionGeneration || issue.registrationGeneration !== session.identity.registrationGeneration || !isPageCurrent(issue)) return;
      if (issue.clearNewTabShown) {
        const context = currentPageContext(tabId);
        const navigation = tab()?.navigation ?? null;
        const consumed = issue.navigation;
        const matchesNavigation = consumed === null ? navigation === null : !!consumed && !!navigation && consumed.seq === navigation.seq && consumed.url === navigation.url && !!consumed.userInitiated === !!navigation.userInitiated;
        if (issue.contextRevision === context.contextRevision && matchesNavigation) patchPage(tabId, { newTabShown: null });
      }
      if (issue.retry) queueMicrotask(() => followNavigation(session, tab()?.navigation));
    },
    onReady: (browserId) => {
      setBrowserId(tabId, browserId);
      noteReady(tabId, session.factsOwner);
      if (tab()?.muted) void webviews.get(tabId)?.setMuted(true);
    },
    onNavigationChange: ({ url: reported, title, canGoBack, canGoForward, isLoading, themeColor, themeColorSource, initialDocumentAccessed, committedInitial, committedUrl }) => {
      adoptIconPage(tabId);
      const url = initialDocumentAccessed && committedInitial ? "about:blank" : reported;
      const untouched = committedInitial === undefined ? reported === "" && !(tab()?.openerId && session.adoptId) : committedInitial && !initialDocumentAccessed;
      const target = session.pending ?? (session.lastPage === null ? (tab()?.navigation?.url ?? null) : null);
      if (target === null && prewarmOnly()) {
        if (isBlank(url)) return;
        session.adopted = url;
        if (session.factsOwner === "js") store().updateTab(tabId, { navigation: navigationTo(url) });
      }
      if (target !== null && isBlank(url) && !target.startsWith("about:") && untouched) {
        if (session.factsOwner === "js") store().updateLive(tabId, { isLoading: true });
        return;
      }
      const shownTheme = session.factsOwner === "js" ? restoredThemeColor(tabId, url, themeColor, isLoading) : themeColor;
      session.pending = null;
      const kept = pageOf(tabId).newTabShown;
      if (kept) {
        if (url === kept.url) {
          patchPage(tabId, { newTabShown: { ...kept, title } });
          if (session.factsOwner === "js") store().updateLive(tabId, { isLoading, canGoBack, canGoForward, themeColor: shownTheme });
          return;
        }
        patchPage(tabId, { newTabShown: null });
      }
      if (session.fromNewTab && url && !isBlank(url)) patchPage(tabId, { backToNewTab: true });
      if (session.factsOwner === "js") store().navigated(tabId, { url, title }, { isLoading, canGoBack, canGoForward, themeColor: shownTheme });
      dropOutlivedFavicon(tabId, url, isLoading);
      if (engine === "webkit") noteWebKitPage(tabId, { url, title, isLoading, committedUrl: committedUrl ?? "" });
      const lastPage = session.lastPage;
      if (lastPage !== null && pageKey(url) !== lastPage) {
        if (pageOf(tabId).externalApp && hostOf(url) !== hostOf(lastPage)) answerExternalApp(tabId, false);
        dismissPermissions(tabId);
        setPopover(tabId, null);
        setPageSelection(tabId, null);
        clearEngineOffer(tabId);
        patchPage(tabId, { popups: [], passwordPrompt: null, crashed: null, status: "" });
        revealToolbar(tabId);
        if (session.peekOf === undefined) followSiteChoice(tabId, engine, url, lastPage);
      }
      session.lastPage = pageKey(url);
      patchPage(tabId, { themeColorSource: themeColorSource ?? null });
    },
    onLoadError: () => {
      session.pending = null;
    },
    onDownloadNavigation: ({ committedUrl, skipped }) => {
      session.pending = null;
      const t = tab();
      if (!t) return;
      const s = store();
      if (session.factsOwner === "js") store().updateLive(tabId, { isLoading: false });
      if (committedUrl) {
        if (session.factsOwner === "js" && t.url !== committedUrl) store().updateTab(tabId, { url: committedUrl });
        return;
      }
      const others = s.windows[t.windowId]?.tabIds.some((id) => id !== tabId && s.tabs[id]?.profileId === t.profileId);
      const opened = !!(t.openerId || t.adoptId) && !pageOf(tabId).wasNewTab;
      if (session.factsOwner === "js" && !skipped && opened && !s.live[tabId]?.canGoBack && others) return store().closeTab(tabId);
      patchPage(tabId, { backToNewTab: false, newTabShown: null });
      if (session.factsOwner === "js") store().updateTab(tabId, { url: "", title: "", favicon: null });
    },
    onProgress: (progress) => {
      if (!prewarmOnly()) setPageProgress(tabId, progress);
    },
    onZoom: ({ zoom }) => store().updateTab(tabId, { zoom }),
    onFindResult: ({ count, active }) => store().setFind(tabId, { count, active }),
    onFavicon: (favicon) => {
      if (!favicon || !tab()) return;
      noteIconPage(tabId);
      store().faviconChanged(tabId, favicon);
      noteFavicon(tabId, favicon);
    },
    onMedia: ({ playing, muted }) => {
      if (session.factsOwner === "js") store().updateLive(tabId, { playingAudio: playing });
      if (tab()?.muted && !muted) void webviews.get(tabId)?.setMuted(true);
    },
    onNowPlaying: (state) => setNowPlaying(tabId, state),
    onPictureInPicture: (state) => setPictureInPictureState(tabId, state),
    onDisplayMediaRequest: (request) => requestDisplayMedia(tabId, request),
    onOpenWindow: (request: OpenWindowRequest) => {
      const t = tab();
      if (t) openFromPage(request, { windowId: t.windowId, profileId: t.profileId, tabId });
    },
    onStatus: (status) => patchPage(tabId, { status }),
    onCrashed: (crashed) => {
      if (!isQuitting()) patchPage(tabId, { crashed, unresponsive: false, fullscreen: false, status: "" });
    },
    onUnresponsive: () => patchPage(tabId, { unresponsive: true }),
    onResponsive: () => patchPage(tabId, { unresponsive: false }),
    onFullscreen: (fullscreen) => patchPage(tabId, { fullscreen }),
    onMediaAccess: (mediaAccess) => patchPage(tabId, { mediaAccess: mediaAccess.camera || mediaAccess.microphone || mediaAccess.screen ? mediaAccess : null }),
    onSecurity: (security) => {
      if (!prewarmOnly()) patchPage(tabId, { security });
    },
    onContentBlocked: ({ count }) => patchPage(tabId, { blocked: count }),
    onPopupBlocked: (popup) => {
      const first = !pageOf(tabId).popups.length;
      patchPage(tabId, { popups: [...pageOf(tabId).popups, popup] });
      if (first) void shouldPromptForPopups(engineProfile(session.profileId), popup.origin).then((ask) => ask && setPopover(tabId, "popups"));
    },
    onPasswordPrompt: (prompt) => showPasswordPrompt(tabId, prompt),
    onAutofillPrompt: (prompt, id) => showAutofillPrompt(tabId, prompt, id),
    onExternalApp: (externalApp) => patchPage(tabId, { externalApp }),
    onPageFocus: activateSplitPane,
    onPagePress: activateSplitPane,
    onWindowClose: (withWindow) => {
      if (!isQuitting()) store().closeTabs([tabId], { lastClosesWindow: true, windowClosedByChrome: withWindow });
    },
    onNotification: (notification) => showWebNotification(tabId, notification),
    onCommand: ({ command, text, modifiers }) => {
      if (command === "search") searchSelection(tabId, text, modifiers);
      else if (command === "copyLinkToHighlight") void copyLinkToSelection(tabId);
      else if (command === "escape" && usePages.getState().popover[tabId]) setPopover(tabId, null);
      else if (command === "escape" && !closeFolderPanelIn(tab()?.windowId) && !closePeekOnEscape(tabId)) closeLittleSolaraOnEscape(tabId);
    },
    onPageMessage: (kind, data) => {
      if (kind === "selection") setPageSelection(tabId, data as PageSelection | null);
      else if (kind === "scroll") noteScroll(tabId, data);
      else if (kind === "drm") offerWebKit(tabId, data);
    },
    onNotificationClose: (id) => closeWebNotification(tabId, id),
    onDiscarded: (url) => {
      session.pending = url;
      session.fromNewTab = false;
      patchPage(tabId, { backToNewTab: false, status: "" });
      if (session.factsOwner === "js") store().updateLive(tabId, { isLoading: false, canGoBack: false, canGoForward: false, playingAudio: false });
      setPageProgress(tabId, 0);
      if (session.factsOwner === "js") noteDiscarded(tabId);
    },
    onActivateRequest: () => {
      const t = tab();
      if (!t) return;
      switchToTab(tabId);
      focus(t.windowId);
    },
  };
  return Object.fromEntries(Object.entries(handlers).map(([name, handler]) => [name, (...args: unknown[]) => {
    if (name !== "onPageCreated" && session.identity && !isPageCurrent(session.identity)) return;
    (handler as (...values: unknown[]) => void)(...args);
  }])) as PageEventHandlers;
}
