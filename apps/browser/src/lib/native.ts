import { keepAlivePagesChanged } from "./nativeKeepAlive";
import { usePages } from "../components/layout/pageState";
import { lastTabClosesWindow, onDownload, releaseProfile } from "@solara/solaracore";
import {
  cancelFocusMove,
  claimFocus,
  closeWindow,
  isDarkAppearance,
  onAppEvent,
  onCommand,
  onOpenURLs,
  onWindowEvent,
  openWindow,
  replyToTerminate,
  restoreFullScreen,
  setAppearance,
  setThinScrollBars,
  setTrafficLightsCenter,
  setWindowTitle,
  windowIds,
} from "@solara/shell";
import { Appearance } from "react-native";
import { cancelBookmarkQuit, flushBookmarkJournal } from "@solara/settings";
import { nativeOwnsWorkspace } from "../store/nativeStore";
import { useBrowser } from "../store/browser";
import { setLastTabKeepsWindow } from "../store/newTabBar";
import { isUtilityWindowId } from "../components/settings/windows";
import { openingLightsCenter } from "../components/layout/windowLayout";
import { openWindow as createWindow } from "./actions";
import { createWindowSync, type WindowPort } from "./windowSync";
import { openExternalUrls } from "./linkRoutes";
import { runCommand } from "./commands";
import { startShortcutHints } from "./commandShortcuts";
import { finishAnimatedCloses } from "./closeAnimated";
import { setFocusSenders } from "./focusClaims";
import { cancelAbandonedFocusMoves } from "./focusHandoff";
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
  onCommand(runCommand);
  startWindowCloseGuard();
  usePages.subscribe(keepAlivePagesChanged);
  if (!nativeOwnsWorkspace()) onOpenURLs((urls, _pointer, profile) => openExternalUrls(urls, profile));
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
    lightsCenter: openingLightsCenter,
    isUtilityWindow: isUtilityWindowId,
  });
  windows.listen();

  startShortcutHints();
  windows.sync(store.getState());
  windows.restoreFullScreen(store.getState());
  store.subscribe((s, prev) => {
    windows.sync(s, prev);
  });
  store.subscribe((s, prev) => {
    if (s.settings.appearance !== prev.settings.appearance) void setAppearance(s.settings.appearance);
    if (s.settings.pageScrollBars !== prev.settings.pageScrollBars) void setThinScrollBars(s.settings.pageScrollBars === "thin");
  });
  void windows.sweep();
}
