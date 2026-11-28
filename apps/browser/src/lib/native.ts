import { keepAlivePagesChanged } from "./nativeKeepAlive";
import { usePages } from "../components/layout/pageState";
import { startPinnedLinks } from "./pinnedLinks";
import { lastTabClosesWindow, onDownload, releaseProfile } from "@solara/solaracore";
import {
  cancelFocusMove,
  claimFocus,
  closeWindow,
  isDarkAppearance,
  menuShortcuts,
  nativeBookmarkMenuSourceAvailable,
  onAppEvent,
  onCommand,
  onOpenURLs,
  onWindowEvent,
  openWindow,
  replyToTerminate,
  restoreFullScreen,
  setAppearance,
  setMenuStateParts,
  setThinScrollBars,
  setTrafficLightsCenter,
  setWindowTitle,
  windowIds,
  type MenuBookmark,
  type MenuState,
} from "@solara/shell";
import { Appearance } from "react-native";
import { cancelBookmarkQuit, flushBookmarkJournal } from "@solara/settings";
import { nativeOwnsWorkspace } from "../store/nativeStore";
import { folderChildren } from "../store/bookmarks";
import { useBrowser, type BrowserState } from "../store/browser";
import { bookmarkProfileId, windowTitle } from "../store/model";
import { setLastTabKeepsWindow } from "../store/newTabBar";
import type { Bookmarks, BookmarkNode } from "../store/types";
import { isUtilityWindowId } from "../components/settings/windows";
import { openingLightsCenter } from "../components/layout/windowLayout";
import { openWindow as createWindow } from "./actions";
import { createWindowSync, type WindowPort } from "./windowSync";
import { openExternalUrls } from "../components/littleSolara/actions";
import { SMALL_LIGHTS_CENTER } from "../components/littleSolara/SmallChrome";
import { runCommand } from "./commands";
import { setMenuBarShortcuts } from "./commandShortcuts";
import { finishAnimatedCloses } from "./closeAnimated";
import { setFocusSenders } from "./focusClaims";
import { cancelAbandonedFocusMoves, settlingCommandFocus } from "./focusHandoff";
import { flushPersistence, resumePersistence } from "./persist";
import { startWindowCloseGuard } from "./windowClose";

let quitting = false;
let quitAttempt = 0;
const quitHandlerCounts = __DEV__ ? { willQuit: 0, quitCancelled: 0 } : null;
export const devQuitHandlerCounts = () => __DEV__ ? { ...quitHandlerCounts! } : null;
export const isQuitting = () => quitting;

export const shellWindowPort: WindowPort = {
  open(id, options, lightsCenter) {
    void setTrafficLightsCenter(id, lightsCenter);
    void openWindow(id, options);
  },
  close: (id) => void closeWindow(id),
  setTitle: (id, title) => void setWindowTitle(id, title),
  windowIds,
  restoreFullScreen: (ids, focus) => void restoreFullScreen(ids, focus),
  onEvent: (listener) => void onWindowEvent(listener),
  releaseProfile: (profile) => void releaseProfile(profile),
};

export function startNativeSync() {
  const store = useBrowser;
  if (!store.getState().windowOrder.length) store.getState().createWindow();

  setFocusSenders(claimFocus, cancelFocusMove);
  cancelAbandonedFocusMoves();
  onCommand((e) => settlingCommandFocus(e, runCommand));
  startWindowCloseGuard();
  usePages.subscribe(keepAlivePagesChanged);
  startPinnedLinks();
  onOpenURLs((urls, pointer, profile) => openExternalUrls(urls, pointer, profile));
  void lastTabClosesWindow().then((closes) => setLastTabKeepsWindow(!closes));
  onDownload((d) => store.getState().upsertDownload(d));

  if (!nativeOwnsWorkspace()) store.getState().setAppDark(Appearance.getColorScheme() === "dark");
  void setAppearance(store.getState().settings.appearance);
  void setThinScrollBars(store.getState().settings.pageScrollBars === "thin");
  if (!nativeOwnsWorkspace()) void isDarkAppearance().then((dark) => {
    if (!nativeOwnsWorkspace()) store.getState().setAppDark(dark);
  });

  onAppEvent((e) => {
    const s = store.getState();
    if (e.type === "appearance" && !nativeOwnsWorkspace()) s.setAppDark(e.dark);
    if (e.type === "reopen") createWindow();
    if (e.type === "quitWarningSuppressed") s.updateSettings({ warnBeforeQuitting: false });
    if (e.type === "willQuit") {
      if (quitting) return;
      if (__DEV__ && quitHandlerCounts) quitHandlerCounts.willQuit++;
      quitting = true;
      const attempt = ++quitAttempt;
      finishAnimatedCloses();
      flushPersistence({ final: true });
      void (async () => {
        let durable = false;
        try { durable = await flushBookmarkJournal(); } catch {}
        if (attempt !== quitAttempt || !quitting) return;
        if (!durable) {
          quitting = false;
          cancelBookmarkQuit();
          resumePersistence();
        }
        await replyToTerminate(durable);
      })();
    }
    if (e.type === "quitCancelled") {
      if (__DEV__ && quitHandlerCounts) quitHandlerCounts.quitCancelled++;
      quitAttempt++;
      quitting = false;
      cancelBookmarkQuit();
      resumePersistence();
    }
  });

  const windows = createWindowSync({
    port: shellWindowPort,
    getState: store.getState,
    isQuitting,
    lightsCenter: (s, id) => (s.windows[id]?.kind === "small" ? SMALL_LIGHTS_CENTER : openingLightsCenter(s, id)),
    isUtilityWindow: isUtilityWindowId,
  });
  windows.listen();

  let lastMenu = "";
  let lastMenuItems = "";
  let lastBookmarkMenus: unknown[] = [];
  let menuTimer: ReturnType<typeof setTimeout> | undefined;
  const syncMenu = () => {
    menuTimer = undefined;
    const state = menuState(store.getState());
    const { bookmarkNative, bookmarkFolders, recentBookmarks, bookmarksBar, otherBookmarks, ...rest } = state;
    const bookmarkMenus = [bookmarkNative, bookmarkFolders, recentBookmarks, bookmarksBar, otherBookmarks];
    const json = JSON.stringify(rest);
    const bookmarksChanged = !bookmarkMenus.every((menu, i) => menu === lastBookmarkMenus[i]);
    if (json === lastMenu && !bookmarksChanged) return;
    lastMenu = json;
    lastBookmarkMenus = bookmarkMenus;
    const sent = setMenuStateParts(state, bookmarksChanged);
    const menuItems = JSON.stringify([state.profiles.map((p) => p.id), (state.extensions ?? []).map((e) => e.id)]);
    if (menuItems === lastMenuItems) return void sent;
    lastMenuItems = menuItems;
    void sent.then(menuShortcuts).then(setMenuBarShortcuts, () => {});
  };

  windows.sync(store.getState());
  syncMenu();
  windows.restoreFullScreen(store.getState());
  store.subscribe((s, prev) => {
    windows.sync(s, prev);
    menuTimer ??= setTimeout(syncMenu, 120);
  });
  store.subscribe((s, prev) => {
    if (s.settings.appearance !== prev.settings.appearance) void setAppearance(s.settings.appearance);
    if (s.settings.pageScrollBars !== prev.settings.pageScrollBars) void setThinScrollBars(s.settings.pageScrollBars === "thin");
  });
  void windows.sweep();
}

function menuBookmarks(b: Bookmarks, folderId: string, depth = 0): MenuBookmark[] {
  return folderChildren(b, folderId).map((n: BookmarkNode) =>
    n.kind === "url"
      ? { id: n.id, title: n.title || n.url, url: n.url }
      : { id: n.id, title: n.title, children: depth < 6 ? menuBookmarks(b, n.id, depth + 1) : [] },
  );
}

type BookmarkMenus = Pick<MenuState, "bookmarkNative" | "bookmarkFolders" | "recentBookmarks" | "bookmarksBar" | "otherBookmarks">;
let bookmarkMenuRevision = 0;
const bookmarkMenuCache = new WeakMap<Bookmarks, Map<string, BookmarkMenus>>();

function bookmarkMenus(b: Bookmarks, profileId: string): BookmarkMenus {
  let perProfile = bookmarkMenuCache.get(b);
  if (!perProfile) bookmarkMenuCache.set(b, (perProfile = new Map()));
  const cached = perProfile.get(profileId);
  if (cached) return cached;
  if (nativeBookmarkMenuSourceAvailable()) {
    const menus: BookmarkMenus = { bookmarkNative: { profileId, revision: ++bookmarkMenuRevision }, bookmarkFolders: [], recentBookmarks: [], bookmarksBar: [], otherBookmarks: [] };
    perProfile.set(profileId, menus);
    return menus;
  }
  const roots = b.roots[profileId];
  const menus: BookmarkMenus = roots
    ? {
        bookmarkFolders: [
          { id: roots.bar, title: "Bookmarks Bar" },
          { id: roots.other, title: "Other Bookmarks" },
          ...[...folderChildren(b, roots.bar), ...folderChildren(b, roots.other)]
            .filter((n) => n.kind === "folder")
            .map((n) => ({ id: n.id, title: n.title })),
        ],
        recentBookmarks: Object.values(b.nodes)
          .filter((n): n is Extract<BookmarkNode, { kind: "url" }> => n.kind === "url" && isInTree(b, n.id, [roots.bar, roots.other]))
          .sort((x, y) => y.addedAt - x.addedAt)
          .slice(0, 5)
          .map((n) => ({ id: n.id, title: n.title || n.url, url: n.url })),
        bookmarksBar: menuBookmarks(b, roots.bar),
        otherBookmarks: menuBookmarks(b, roots.other),
      }
    : { bookmarkFolders: [], recentBookmarks: [], bookmarksBar: [], otherBookmarks: [] };
  perProfile.set(profileId, menus);
  return menus;
}

export function menuState(s: BrowserState): MenuState {
  const windowId = s.ui.focusedWindowId && s.windows[s.ui.focusedWindowId] ? s.ui.focusedWindowId : undefined;
  const w = windowId ? s.windows[windowId] : undefined;
  const bookmarkProfile = bookmarkProfileId(s, w);
  const regularWindows = s.windowOrder.filter((id) => !s.windows[id]!.incognito && s.windows[id]!.kind !== "small");

  return {
    profiles: s.profileOrder.map((id) => ({ id, title: s.profiles[id]!.name, current: w?.profileId === id })),
    windows: w?.incognito ? [] : regularWindows.filter((id) => id !== windowId).map((id) => ({ id, title: windowTitle(s, id) })),
    ...bookmarkMenus(s.bookmarks, bookmarkProfile),
    warnBeforeQuitting: s.settings.warnBeforeQuitting,
    warnBeforeClosingWindow: s.settings.warnBeforeClosingWindow,
    undoReopensClosedTab: s.settings.undoReopensClosedTab,
    downloadsInProgress: s.downloads.filter((d) => d.state === "downloading").length,
    shortcuts: s.settings.shortcuts,
    shortcutPrecedence: s.settings.shortcutPrecedence,
  };
}

function isInTree(b: Bookmarks, id: string, roots: string[]): boolean {
  let node = b.nodes[id];
  for (let i = 0; node && i < 64; i++) {
    if (roots.includes(node.id)) return true;
    node = node.parentId ? b.nodes[node.parentId] : undefined;
  }
  return false;
}
