import "./lib/jsErrors";
import "./lib/productName";
import "./lib/nativeEvents";
import { tabPool, tabPoolAvailable, windowPagesPoolActive } from "@solara/settings";
import { useEffect, useState } from "react";
import { AppRegistry, unstable_batchedUpdates } from "react-native";
import { WindowRoot } from "./App";
import { registerPaneRoot } from "./PaneRoot";
import { AreaBoundary } from "./components/AreaBoundary";
import { startTranslate } from "./components/site/translate";
import { afterFirstWindow, firstWindowCommitted } from "./lib/afterFirstWindow";
import { jsErrorsSurvivable } from "./lib/jsErrors";
import { offerNativeDefaultBrowserAfterFirstWindow, startAppIntegrationPresentation, startScriptLoading } from "./lib/appIntegration";
import { startNativeSync } from "./lib/native";
import { startPersistence } from "./lib/persist";
import { startNewTabBar } from "./components/omnibox/newTabBar";
import { startPooledPages } from "./components/pooledPages";
import { perfMark, perfProbeEnabled, probeStore } from "./lib/perfProbe";
import { startTabLifecycle } from "./lib/tabLifecycle";
import { startTabPages } from "./lib/tabPages";
import { startTabReveal } from "./lib/tabReveal";
import { startPairingSync } from "./sync/pairingNative";
import { setStoreBatching, useBrowser } from "./store/browser";
import { startPerfMarks } from "./lib/perfMarks";
import { startNotifications } from "./lib/notifications";
import { startNativeSettings } from "./components/settings/nativeSettings";

probeStore("browser", useBrowser);
setStoreBatching(unstable_batchedUpdates);
startNotifications();
startPersistence();
startNewTabBar();
startTabPages();
if (tabPool && windowPagesPoolActive() && tabPoolAvailable()) startPooledPages(tabPool);
startTabReveal();
startNativeSync();
startScriptLoading();
startAppIntegrationPresentation();
afterFirstWindow(() => {
  void offerNativeDefaultBrowserAfterFirstWindow().catch((error) => console.warn("[defaultBrowserOffer]", error));
});
startTabLifecycle();
startTranslate();
startPairingSync();
startPerfMarks();
afterFirstWindow(startNativeSettings);
if (__DEV__ || perfProbeEnabled) require("./lib/devHarness").startDevHarness();

const devMountDelay = () => (__DEV__ ? ((globalThis as { acDevMountDelayMs?: number }).acDevMountDelayMs ?? 0) : 0);

function Root({ windowId }: { windowId: string }) {
  const [delay] = useState(devMountDelay);
  const [held, setHeld] = useState(delay > 0);
  useEffect(() => {
    if (!held) return;
    const timer = setTimeout(() => setHeld(false), delay);
    return () => clearTimeout(timer);
  }, []);
  useEffect(() => {
    perfMark("firstWindow");
    firstWindowCommitted();
    jsErrorsSurvivable();
  }, []);
  if (held) return null;
  return (
    <AreaBoundary area="window" windowId={windowId}>
      <WindowRoot windowId={windowId} />
    </AreaBoundary>
  );
}

AppRegistry.registerComponent("main", () => Root);
registerPaneRoot();
perfMark("bundleEnd");
