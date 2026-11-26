import "./components/layout/nativeDockEvents";
import { windowNativeLayout } from "@solara/settings";
import { useState } from "react";
import { StyleSheet, View } from "react-native";
import { CommandPanel } from "./components/CommandPanel";
import { ContentCard } from "./components/ContentCard";
import { BookmarkDialog } from "./components/bookmarks/BookmarkDialog";
import { EditBookmarkDialog } from "./components/bookmarks/EditBookmarkDialog";
import { DownloadMagnet, DownloadsPopover } from "./components/Downloads";
import { isUtilityWindowId } from "./components/settings/windows";
import { OnboardingOverlay } from "./components/onboarding";
import { CreateProfileHost } from "./components/profiles/CreateProfile";
import { useAddressBarInSidebar, useTabLayout } from "./components/layout/windowLayout";
import { WindowProfile } from "./components/layout/WindowProfile";
import { NativeTopStripFeed } from "./components/layout/NativeTopStrip";
import { NativeSidebar } from "./components/sidebar/NativeSidebar";
import { FolderPanel } from "./components/sidebar/FolderPanel";
import { useShellModal } from "./components/layout/shellModal";
import { ShellBackdrop } from "./components/layout/ShellBackdrop";
import { LittleSolaraWindow } from "./components/littleSolara/LittleSolaraWindow";
import { SidebarOverlays } from "./components/sidebar/Overlays";
import { ThemeScope } from "./lib/theme";
import { useBrowser } from "./store/browser";
import { useWindowId, useWindowProfileId, WindowContext } from "./store/hooks";
import { useNativeWindowBounds } from "./components/layout/windowLayout";
import { useNativeWindowAnchors } from "./components/layout/nativeWindowAnchors";

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
  const windowId = useWindowId();
  const [nativeLayout] = useState(() => windowNativeLayout(windowId));
  if (nativeLayout) return <NativeBrowserWindow />;
  const { LegacyWindow } = require("./LegacyWindow") as typeof import("./LegacyWindow");
  return <LegacyWindow />;
}

function NativeBrowserWindow() {
  const windowId = useWindowId();
  useNativeWindowAnchors(windowId);
  const width = useNativeWindowBounds((s) => s[windowId]?.[2] ?? 0);
  const topTabs = useTabLayout() === "top";
  return (
    <View testID={`solara-window-guest.${windowId}`} pointerEvents="box-none" style={StyleSheet.absoluteFill}>
      <ShellBackdrop shell />
      <WindowProfile />
      <NativeLayoutGuests topTabs={topTabs} />
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

function NativeLayoutGuests({ topTabs }: { topTabs: boolean }) {
  const windowId = useWindowId();
  const profileId = useWindowProfileId();
  const addressBar = useAddressBarInSidebar();
  return (
    <>
      <NativeShellModal windowId={windowId} />
      <ContentCard />
      {topTabs ? <NativeTopStripFeed windowId={windowId} profileId={profileId} /> : <NativeSidebar windowId={windowId} profileId={profileId} addressBar={addressBar} headless />}
      {!topTabs && <FolderPanel windowId={windowId} />}
    </>
  );
}

function NativeShellModal({ windowId }: { windowId: string }) {
  useShellModal(windowId);
  return null;
}
