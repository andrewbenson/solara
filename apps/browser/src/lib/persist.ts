import { prepareWebKitContentBlocker, removeLeftDownloadStaging, type Download } from "@solara/solaracore";
import { showToast } from "../components/layout/toasts";
import { persistenceRefused, refusePersistence } from "./persistLatch";
import { useBrowser, type BrowserState } from "../store/browser";
import { restoreLaunchLook, saveLaunchLook } from "./launchLook";
import { tabEngine } from "../store/engines";
import { startFavicons } from "./favicons";
import { startHistory } from "./history";
import { flushNativeStore, flushProblem } from "@solara/store";
import * as nativeSettings from "@solara/settings";
import { Alert } from "react-native";
import {
  attachReplica,
  dataFolderHandedOff,
  hydrateFromNative,
  nativeSafeMode,
  nativeSafeModeAfterFailedLaunches,
  nativeOwnsWorkspace,
  standDown,
  startNativeStore,
} from "../store/nativeStore";

function forgetStaging(id: string) {
  const s = useBrowser.getState();
  const download = s.downloads.find((d) => d.id === id);
  if (!download) return;
  const { staging: _, stagingId: _id, destination: _to, ...kept } = download;
  s.upsertDownload(kept);
}

function cleanStaging(downloads: Download[]) {
  for (const d of downloads) if (d.stagingId) void removeLeftDownloadStaging(d).then((removed) => removed && forgetStaging(d.id));
}

let frozen = false;

export function flushPersistence({ final = false } = {}) {
  if (final || nativeOwnsWorkspace()) {
    const result = flushNativeStore();
    if (final && flushProblem(result)) console.warn("Native store quit flush:", result);
  }
  if (final && !frozen && !persistenceRefused() && !nativeSafeMode()) saveLaunchLook(useBrowser.getState());
  if (final) frozen = true;
}

export function resumePersistence() {
  if (persistenceRefused()) return;
  frozen = false;
}

function prepareWebKitBlocker() {
  const s = useBrowser.getState();
  if (Object.keys(s.tabs).some((id) => tabEngine(s, id) === "webkit")) void prepareWebKitContentBlocker().catch(() => {});
}

export function startPersistence() {
  const store = startNativeStore();
  if (dataFolderHandedOff()) {
    refusePersistence("another instance is using this data folder");
    frozen = true;
    console.warn("Another instance is using this data folder; this one saves nothing.");
    return () => {};
  }
  if (!nativeOwnsWorkspace()) return savesNothing(store.modulePresent ? (store.reason ?? "the native store is frozen") : "the native store module is missing");
  if (nativeOwnsWorkspace()) {
    let hydrated = false;
    try {
      hydrated = hydrateFromNative(useBrowser);
    } catch (error) {
      return savesNothing(`its snapshot couldn't be read: ${String(error)}`);
    }
    if (!hydrated) return savesNothing("it returned no workspace");
    attachReplica(useBrowser);
    if (!nativeSafeMode()) {
      restoreLaunchLook();
      prepareWebKitBlocker();
    }
    cleanStaging(useBrowser.getState().downloads);
    tellSafeModeAfterFailedLaunches();
    return startDerivedServices();
  }
}

function tellSafeModeAfterFailedLaunches() {
  if (!nativeSafeModeAfterFailedLaunches()) return;
  const tell = (s: BrowserState) => {
    const publicWindow = (id: string) => s.windows[id] && !s.windows[id].incognito && s.windows[id].kind !== "small";
    const windowId = s.ui.focusOrder.find(publicWindow) ?? s.windowOrder.find(publicWindow);
    if (!windowId) return false;
    showToast(windowId, "Solara started in safe mode", "Your tabs are kept and come back the next time it opens normally.", {
      icon: "shield", sticky: true, key: "safe-mode", action: { title: "OK", run: () => {} },
    });
    return true;
  };
  if (tell(useBrowser.getState())) return;
  const stop = useBrowser.subscribe((s) => {
    if (tell(s)) stop();
  });
}

function savesNothing(reason: string) {
  refusePersistence(`the native store: ${reason}`);
  frozen = true;
  standDown();
  const message = `The native store isn't available (${reason}), so this window saves nothing. Quit and relaunch; your data is unchanged.`;
  console.error(message);
  let shown: boolean | null = null;
  try {
    shown = nativeSettings.nativePresentStoreUnavailable?.(reason) ?? null;
  } catch (error) {
    console.warn("Couldn't show the store-unavailable window", error);
  }
  if (shown) return () => {};
  try {
    Alert.alert("Your tabs couldn't load", message);
  } catch {}
  return () => {};
}

function startDerivedServices() {
  const stopFavicons = startFavicons();
  const stopHistory = startHistory();
  return () => {
    stopFavicons();
    stopHistory();
  };
}
