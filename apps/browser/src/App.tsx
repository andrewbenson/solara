import { windowMainOnTop } from "@solara/settings";
import { useState } from "react";
import { StyleSheet, View } from "react-native";
import { CommandPanel } from "./components/CommandPanel";
import { ContentCard } from "./components/ContentCard";
import { BookmarkDialog } from "./components/bookmarks/BookmarkDialog";
import { EditBookmarkDialog } from "./components/bookmarks/EditBookmarkDialog";
import { ExtensionOverlays } from "./components/extensions/ExtensionOverlays";
import { ExtensionSidePanel, SidePanelRoom } from "./components/extensions/SidePanel";
import { DownloadMagnet, DownloadsPopover } from "./components/Downloads";
import { isUtilityWindowId } from "./components/settings/windows";
import { OnboardingOverlay } from "./components/onboarding";
import { CreateProfileHost } from "./components/profiles/CreateProfile";
import { useFullscreenTab } from "./components/layout/pageState";
import { ProfileTint } from "./components/layout/ProfileSwipe";
import { TOP_CARD_INSET, TOP_STRIP_HEIGHT, TopStripPeek, TopTabStrip } from "./components/layout/TopTabStrip";
import { useTabLayout } from "./components/layout/windowLayout";
import { WindowProfile } from "./components/layout/WindowProfile";
import { DockedLayout } from "./components/layout/SidebarDock";
import { ShellBackdrop, useWindowShell } from "./components/layout/ShellBackdrop";
import { LittleSolaraWindow } from "./components/littleSolara/LittleSolaraWindow";
import { SidebarOverlays } from "./components/sidebar/Overlays";
import { layout, ThemeScope, useTheme } from "./lib/theme";
import { useBrowser } from "./store/browser";
import { useWindowId, WindowContext } from "./store/hooks";

export function WindowRoot({ windowId }: { windowId?: string }) {
  if (isUtilityWindowId(windowId)) return null;
  return <BrowserWindowRoot windowId={windowId} />;
}

function BrowserWindowRoot({ windowId }: { windowId?: string }) {
  const id = useBrowser((s) => windowId ?? s.ui.focusedWindowId ?? s.windowOrder[0] ?? null);
  const exists = useBrowser((s) => !!id && !!s.windows[id]);
  const small = useBrowser((s) => !!id && s.windows[id]?.kind === "small");
  if (!id || !exists) return null;
  return (
    <WindowContext.Provider value={id}>
      <ThemeScope>{small ? <LittleSolaraWindow /> : <BrowserWindow />}</ThemeScope>
    </WindowContext.Provider>
  );
}

function BrowserWindow() {
  const theme = useTheme();
  const windowId = useWindowId();
  const topTabs = useTabLayout() === "top";
  const fullscreen = !!useFullscreenTab(windowId);
  const [width, setWidth] = useState(0);
  const shell = useWindowShell();
  const [onTop] = useState(() => windowMainOnTop(windowId));
  const card = (
    <>
      <ContentCard />
      <SidePanelRoom fullscreen={fullscreen} />
    </>
  );

  return (
    <View pointerEvents={onTop ? "box-none" : "auto"} style={{ flex: 1, flexDirection: "row" }} onLayout={(e) => setWidth(e.nativeEvent.layout.width)}>
      <ShellBackdrop shell={shell} />
      <WindowProfile />
      <ExtensionSidePanel fullscreen={fullscreen} />
      <ProfileTint />
      <DockedLayout
        fullscreen={fullscreen}
        topTabs={topTabs}
        inset={topTabs ? { top: TOP_STRIP_HEIGHT, right: TOP_CARD_INSET, bottom: TOP_CARD_INSET, left: TOP_CARD_INSET } : { top: layout.cardTop, right: layout.cardInset, bottom: layout.cardInset, left: layout.cardInset }}
        topStrip={
          topTabs
            ? { strip: <TopTabStrip width={width} hidden={fullscreen} />, peek: <TopStripPeek windowWidth={width} enabled={!fullscreen} /> }
            : undefined
        }
      >
        {card}
      </DockedLayout>
      <CommandPanel windowWidth={width} />
      <DownloadsPopover />
      <ExtensionOverlays />
      <DownloadMagnet />
      <BookmarkDialog />
      <EditBookmarkDialog />
      <CreateProfileHost />
      <SidebarOverlays windowWidth={width} />
      <OnboardingOverlay />
    </View>
  );
}
