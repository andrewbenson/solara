import { windowMainOnTop } from "@solara/settings";
import "./components/layout/nativeDock";
import { useState } from "react";
import { View } from "react-native";
import { CommandPanel } from "./components/CommandPanel";
import { ContentCard } from "./components/ContentCard";
import { BookmarkDialog } from "./components/bookmarks/BookmarkDialog";
import { EditBookmarkDialog } from "./components/bookmarks/EditBookmarkDialog";
import { requireNativeViewManager } from "expo-modules-core";
import { DownloadMagnet, DownloadsPopover } from "./components/Downloads";
import { OnboardingOverlay } from "./components/onboarding";
import { CreateProfileHost } from "./components/profiles/CreateProfile";
import { useFullscreenTab } from "./components/layout/pageState";
import { TOP_CARD_INSET, TOP_STRIP_HEIGHT, TopStripPeek, TopTabStrip } from "./components/layout/TopTabStrip";
import { useTabLayout } from "./components/layout/windowLayout";
import { WindowProfile } from "./components/layout/WindowProfile";
import { DockedLayout } from "./components/layout/SidebarDock";
import { ShellBackdrop, useWindowShell } from "./components/layout/ShellBackdrop";
import { SidebarOverlays } from "./components/sidebar/Overlays";
import { layout, useTheme } from "./lib/theme";
import { useWindowId } from "./store/hooks";


const SidePanelSpacer = requireNativeViewManager<{ windowId: string; pointerEvents: "none" }>("SolaraWindowShell");

export function LegacyWindow() {
  const theme = useTheme();
  const windowId = useWindowId();
  const topTabs = useTabLayout() === "top";
  const fullscreen = !!useFullscreenTab(windowId);
  const [width, setWidth] = useState(0);
  const shell = useWindowShell();
  const [onTop] = useState(() => windowMainOnTop(windowId));
  return (
    <View testID={`solara-window-guest.${windowId}`} pointerEvents={onTop ? "box-none" : "auto"} style={{ flex: 1, flexDirection: "row" }} onLayout={(e) => setWidth(e.nativeEvent.layout.width)}>
      <ShellBackdrop shell={shell} />
      <WindowProfile />
      {<DockedLayout
        fullscreen={fullscreen}
        topTabs={topTabs}
        inset={topTabs ? { top: TOP_STRIP_HEIGHT, right: TOP_CARD_INSET, bottom: TOP_CARD_INSET, left: TOP_CARD_INSET } : { top: layout.cardTop, right: layout.cardInset, bottom: layout.cardInset, left: layout.cardInset }}
        topStrip={
          topTabs
            ? { strip: <TopTabStrip hidden={fullscreen} />, peek: <TopStripPeek windowWidth={width} enabled={!fullscreen} /> }
            : undefined
        }
      >
        <ContentCard />
        <SidePanelSpacer windowId={windowId} pointerEvents="none" />
      </DockedLayout>}
      <CommandPanel windowWidth={width} />
      <DownloadsPopover />
      <DownloadMagnet />
      <BookmarkDialog />
      <EditBookmarkDialog />
      <CreateProfileHost />
      <SidebarOverlays windowWidth={width} />
      <OnboardingOverlay />
    </View>
  );
}
