import { windowNativeLayout } from "@solara/settings";
import { useState } from "react";
import { useTheme } from "../lib/theme";
import { useWindowId } from "../store/hooks";
import { useNativeWindowPreferences } from "./layout/windowLayout";
import { toolbarGeometry } from "./layout/geometry";
import { useNativePanePromptsTheme } from "./layout/nativePaneOverlays";
import { useFormColors } from "./settings/controls";
import { useNativeSplitChrome } from "./layout/nativeSplitChrome";
import { SplitToolbarFeed } from "./layout/NativeSplitToolbars";
import { FrozenPage } from "./layout/frozenPage";
import { NativePaneFallback, useNativePaneFallbacks } from "./layout/NativePaneFallback";
import { useContentServices } from "./ContentServices";
import { PaneContent } from "./PaneContent";
import "./layout/devExpose";


export function ContentCard({ small = false }: { small?: boolean }) {
  const windowId = useWindowId();
  const [nativeLayout] = useState(() => windowNativeLayout(windowId));
  if (nativeLayout) return <NativeContentGuests />;
  const { LegacyContentCard } = require("./LegacyContentCard") as typeof import("./LegacyContentCard");
  return <LegacyContentCard small={small} />;
}

function NativeContentGuests() {
  const windowId = useWindowId();
  const panes = useNativeWindowPreferences(windowId, (value) => value && ({
    activeTabId: value.activeTabId,
    tabIds: value.paneTabIds,
  }));
  const theme = useTheme();
  useContentServices();
  useNativePanePromptsTheme(true, windowId, theme, useFormColors());
  useNativeSplitChrome(windowId, true, theme);
  const fallbacks = useNativePaneFallbacks(windowId);
  const tabIds = panes?.tabIds ?? [];
  return (
    <>
      {Object.entries(fallbacks).map(([tabId, target]) => (
        <NativePaneFallback key={tabId} windowId={windowId} tabId={tabId} target={target}>
          <PaneContent windowId={windowId} tabId={tabId} shown nativeFallback />
        </NativePaneFallback>
      ))}
      {tabIds.map((tabId) => <SplitToolbarFeed key={tabId} windowId={windowId} tabId={tabId} geometry={toolbarGeometry({ sidebarButton: false })} focused={tabId === panes?.activeTabId} inSplit={tabIds.length > 1} />)}
      {tabIds.map((tabId) => <FrozenPage key={tabId} windowId={windowId} tabId={tabId} headless />)}
    </>
  );
}
