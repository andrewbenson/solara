import type { OpenWindowRequest, PageEngine, WebViewProps } from "@solara/solaracore";
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

export function followNavigation(session: PageSession, navigation: Tab["navigation"] | undefined) {
  const { tabId } = session;
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

  return {
    onReady: (browserId) => {
      setBrowserId(tabId, browserId);
      noteReady(tabId);
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
        store().updateTab(tabId, { navigation: navigationTo(url) });
      }
      if (target !== null && isBlank(url) && !target.startsWith("about:") && untouched) {
        store().updateLive(tabId, { isLoading: true });
        return;
      }
      const shownTheme = restoredThemeColor(tabId, url, themeColor, isLoading);
      session.pending = null;
      const kept = pageOf(tabId).newTabShown;
      if (kept) {
        if (url === kept.url) {
          patchPage(tabId, { newTabShown: { ...kept, title } });
          store().updateLive(tabId, { isLoading, canGoBack, canGoForward, themeColor: shownTheme });
          return;
        }
        patchPage(tabId, { newTabShown: null });
      }
      if (session.fromNewTab && url && !isBlank(url)) patchPage(tabId, { backToNewTab: true });
      store().navigated(tabId, { url, title }, { isLoading, canGoBack, canGoForward, themeColor: shownTheme });
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
      store().updateLive(tabId, { isLoading: false });
      if (committedUrl) {
        if (t.url !== committedUrl) store().updateTab(tabId, { url: committedUrl });
        return;
      }
      const others = s.windows[t.windowId]?.tabIds.some((id) => id !== tabId && s.tabs[id]?.profileId === t.profileId);
      const opened = !!(t.openerId || t.adoptId) && !pageOf(tabId).wasNewTab;
      if (!skipped && opened && !s.live[tabId]?.canGoBack && others) return store().closeTab(tabId);
      patchPage(tabId, { backToNewTab: false, newTabShown: null });
      store().updateTab(tabId, { url: "", title: "", favicon: null });
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
      store().updateLive(tabId, { playingAudio: playing });
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
      store().updateLive(tabId, { isLoading: false, canGoBack: false, canGoForward: false, playingAudio: false });
      setPageProgress(tabId, 0);
      noteDiscarded(tabId);
    },
    onActivateRequest: () => {
      const t = tab();
      if (!t) return;
      switchToTab(tabId);
      focus(t.windowId);
    },
  };
}
