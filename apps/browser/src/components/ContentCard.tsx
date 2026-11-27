import { windowNativeLayout } from "@solara/settings";
import { useEffect, useMemo, useState } from "react";
import { useTheme } from "../lib/theme";
import { useBrowser } from "../store/browser";
import { useActiveTabId, useWindowId } from "../store/hooks";
import { wake } from "../store/model";
import { needsPage } from "../store/pageSession";
import { splitOf } from "../store/splits";
import { NativeBookmarksBarFeed } from "./bookmarks/NativeBookmarksBar";
import { toolbarGeometry } from "./layout/geometry";
import { useNativePanePromptsTheme } from "./layout/nativePaneOverlays";
import { useFormColors } from "./settings/controls";
import { useNativeSplitChrome } from "./layout/nativeSplitChrome";
import { SplitToolbarFeed } from "./layout/NativeSplitToolbars";
import { FrozenPage } from "./layout/frozenPage";
import { holderOf } from "../store/pinShare";
import { useTabLayout } from "./layout/windowLayout";
import { NativeAutoHideStyleFeed } from "./NativeAutoHide";
import { NativePeekMount } from "./peek/NativePeekMount";
import { NativePaneFallback, useNativePaneFallbacks } from "./layout/NativePaneFallback";
import { useContentServices } from "./ContentServices";
import { PaneContent } from "./PaneContent";
import "./layout/devExpose";


export function ContentCard() {
  const windowId = useWindowId();
  const [nativeLayout] = useState(() => windowNativeLayout(windowId));
  if (nativeLayout) return <NativeContentGuests />;
  const { LegacyContentCard } = require("./LegacyContentCard") as typeof import("./LegacyContentCard");
  return <LegacyContentCard />;
}

function NativeContentGuests() {
  const windowId = useWindowId();
  const activeId = useActiveTabId();
  const split = useBrowser((s) => splitOf(s, activeId));
  const theme = useTheme();
  useContentServices();
  useNativePanePromptsTheme(true, windowId, theme, useFormColors());
  useNativeSplitChrome(windowId, true, theme, null, false, true, false);
  const fallbacks = useNativePaneFallbacks(windowId);
  const tabIds = useMemo(() => split?.tabIds ?? (activeId ? [activeId] : NO_TABS), [split, activeId]);
  useEffect(() => {
    const state = useBrowser.getState();
    for (const tabId of tabIds) {
      const tab = state.tabs[tabId];
      if (!tab || !needsPage(tab)) continue;
      const holder = holderOf(state, tabId);
      state.updateTab(tabId, holder ? { pageIn: holder.id, unloaded: undefined } : wake(tab));
    }
  }, [tabIds]);
  return (
    <>
      <NativeBookmarksBarFeed windowId={windowId} />
      {tabIds.map((tabId) => (
        <NativePaneFallback key={tabId} windowId={windowId} tabId={tabId} target={fallbacks[tabId]}>
          <PaneContent windowId={windowId} tabId={tabId} shown nativeFallback />
        </NativePaneFallback>
      ))}
      {tabIds.map((tabId) => <NativePaneChromeFeed key={tabId} windowId={windowId} tabId={tabId} inSplit={!!split} leading={tabId === tabIds[0]} focused={tabId === activeId} />)}
      {tabIds.map((tabId) => <FrozenPage key={tabId} windowId={windowId} tabId={tabId} headless />)}
      <NativePeekMount windowId={windowId} origin={null} fullscreen={false} />
    </>
  );
}

function NativePaneChromeFeed({ windowId, tabId, inSplit, leading, focused }: { windowId: string; tabId: string; inSplit: boolean; leading: boolean; focused: boolean }) {
  const tabLayout = useTabLayout();
  const showSidebarButton = useBrowser((s) => s.settings.showSidebarButton !== false);
  const geometry = toolbarGeometry({ sidebarButton: leading && tabLayout === "sidebar" && showSidebarButton });
  return (
    <>
      <SplitToolbarFeed tabId={tabId} windowId={windowId} geometry={geometry} focused={focused} inSplit={inSplit} />
      <NativeAutoHideStyleFeed windowId={windowId} tabId={tabId} />
    </>
  );
}

const NO_TABS: string[] = [];
