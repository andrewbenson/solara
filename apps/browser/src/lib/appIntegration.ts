import {
  completeNativeAppStartup,
  hostedKinds,
  nativeAppIntegrationCommand,
  nativeAppIntegrationFirstWindow,
  nativeAppIntegrationNotification,
  onAppIntegrationPresentation,
  startNativeAppStartup,
} from "@solara/settings";
import { onNotificationResponse, setScriptLoading } from "@solara/shell";
import { startOnboarding, resumeOnboarding, useOnboarding } from "../components/onboarding/state";
import { startToolTour } from "../components/onboarding/tour/state";
import { applyPendingReleaseNotes, releaseNotesVersions } from "../components/ntp/releaseNotes";
import { useBrowser } from "../store/browser";
import { nativeSafeMode } from "../store/nativeStore";
import { resolveWindowId } from "../store/model";
import { openUrls } from "./actions";
import { persistenceRefused } from "./persistLatch";

let startup: Promise<void> = Promise.resolve();
let presentationStarted = false;

export function startAppIntegrationPresentation() {
  if (presentationStarted) return;
  presentationStarted = true;
  onAppIntegrationPresentation(({ action, windowId, url }) => {
    try {
      switch (action) {
        case "showOnboarding":
          if (!hostedKinds().includes("onboarding")) return void console.warn("[appIntegration] native onboarding host is off");
          if (!resolveWindowId(useBrowser.getState(), windowId)) return void console.warn("[appIntegration] no window for onboarding");
          return startOnboarding(windowId);
        case "toolTour":
          if (!resolveWindowId(useBrowser.getState(), windowId)) return void console.warn("[appIntegration] no window for tool tour");
          return void startToolTour(windowId).catch((error) => console.warn("[appIntegration] tool tour failed", error));
        case "openURL":
          if (url) openUrls([url], windowId);
      }
    } catch (error) {
      console.warn(`[appIntegration] ${action} presentation failed`, error);
    }
  });
  onNotificationResponse((response) => {
    void nativeAppIntegrationNotification(response).catch((error) => console.warn("[appIntegration] notification failed", error));
  });
  startup = startNativeAppStartup({
    development: __DEV__,
    persistenceRefused: persistenceRefused(),
    safeMode: nativeSafeMode(),
    hostedOnboarding: hostedKinds().includes("onboarding"),
    releaseNotesVersions: releaseNotesVersions(),
  }).then(async ({ pendingJSON, onboarding, savedJSON }) => {
    if (pendingJSON !== null) applyPendingReleaseNotes(JSON.parse(pendingJSON));
    if (onboarding !== "none" && !resolveWindowId(useBrowser.getState(), null)) {
      console.warn("[appIntegration] no window for automatic onboarding");
    } else {
      if (onboarding === "start") startOnboarding();
      if (onboarding === "resume" && savedJSON) resumeOnboarding(JSON.parse(savedJSON));
    }
    await completeNativeAppStartup();
  }).catch((error) => console.warn("[appIntegration] startup failed", error));
}

export async function offerNativeDefaultBrowserAfterFirstWindow() {
  await startup;
  await nativeAppIntegrationFirstWindow(useOnboarding.getState().windowId !== null);
}

export async function sendFeedback(windowId?: string | null) {
  await nativeAppIntegrationCommand("sendFeedback", windowId);
}

export function startScriptLoading() {
  let lastJson = "";
  const push = () => {
    const s = useBrowser.getState();
    const ids = Object.keys(s.live).filter((id) => s.live[id]?.isLoading);
    const json = JSON.stringify(ids);
    if (json === lastJson) return;
    lastJson = json;
    void setScriptLoading(ids);
  };
  let timer: ReturnType<typeof setTimeout> | undefined;
  useBrowser.subscribe((s, prev) => {
    if (s.live === prev.live) return;
    timer ??= setTimeout(() => {
      timer = undefined;
      push();
    }, 100);
  });
  push();
}
