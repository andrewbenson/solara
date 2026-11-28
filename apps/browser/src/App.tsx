import "./components/layout/nativeDockEvents";
import { windowNativeLayout } from "@solara/settings";
import { useState } from "react";
import { StyleSheet, View } from "react-native";
import { CommandPanel } from "./components/CommandPanel";
import { ContentCard } from "./components/ContentCard";
import { isUtilityWindowId } from "./components/settings/windows";
import { OnboardingOverlay } from "./components/onboarding";
import { CreateProfileHost } from "./components/profiles/CreateProfile";
import { NativeTopStripFeed } from "./components/layout/NativeTopStrip";
import { NativeSidebar } from "./components/sidebar/NativeSidebar";
import { useShellModal } from "./components/layout/shellModal";
import { ShellBackdrop } from "./components/layout/ShellBackdrop";
import { LittleSolaraWindow } from "./components/littleSolara/LittleSolaraWindow";
import { SidebarOverlays } from "./components/sidebar/Overlays";
import { switchOn } from "./lib/killSwitches";
import { ThemeScope } from "./lib/theme";
import { useWindowId, WindowContext } from "./store/hooks";
import { useNativeWindowBounds, useNativeWindowPreferences } from "./components/layout/windowLayout";
import { useNativeWindowAnchors } from "./components/layout/nativeWindowAnchors";

export function WindowRoot({ windowId, kind }: { windowId: string; kind: string }) {
  if (isUtilityWindowId(windowId) || (kind !== "browser" && kind !== "small")) return null;
  return <BrowserWindowRoot windowId={windowId} kind={kind} />;
}

function BrowserWindowRoot({ windowId, kind }: { windowId: string; kind: string }) {
  return (
    <WindowContext.Provider value={windowId}>
      <ThemeScope>{kind === "small" ? <LittleSolaraWindow /> : <BrowserWindow />}</ThemeScope>
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
  return (
    <View testID={`solara-window-guest.${windowId}`} pointerEvents="box-none" style={StyleSheet.absoluteFill}>
      <ShellBackdrop shell />
      <NativeLayoutGuests />
      <CommandPanel windowWidth={width} />
      <CreateProfileHost />
      <SidebarOverlays windowWidth={width} />
      <OnboardingOverlay />
    </View>
  );
}

function NativeLayoutGuests() {
  const windowId = useWindowId();
  const preferences = useNativeWindowPreferences(windowId, (value) => value && ({
    topTabs: value.topTabs,
    addressBar: value.addressBar && (value.sidebarOpen || switchOn("sidebarSlide")),
  }));
  return (
    <>
      <NativeShellModal windowId={windowId} />
      <ContentCard />
      {preferences && (preferences.topTabs ? <NativeTopStripFeed windowId={windowId} /> : <NativeSidebar windowId={windowId} addressBar={preferences.addressBar} headless />)}
    </>
  );
}

function NativeShellModal({ windowId }: { windowId: string }) {
  useShellModal(windowId);
  return null;
}
