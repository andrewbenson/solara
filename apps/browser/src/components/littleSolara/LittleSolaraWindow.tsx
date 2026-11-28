import { WindowBackdrop } from "@solara/shaders";
import { littleSolaraShellActive, setLittleSolaraBackdrop, setLittleSolaraBar } from "@solara/settings";
import { setTrafficLightsCenter, WindowDragRegion } from "@solara/shell";
import { useEffect, useRef, useState } from "react";
import { StyleSheet, View } from "react-native";
import { profileAccent, useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { useActiveTab, useTabLive, useWindowId, useWindowProfile, useWindowUi } from "../../store/hooks";
import { CommandPanel } from "../CommandPanel";
import { ContentCard } from "../ContentCard";
import { DownloadsSurface } from "../Downloads";
import { setUrlAnchor } from "../layout/windowLayout";
import { profileSymbol } from "../profiles/icons";
import { mediaTheme, NativeMediaView } from "../media/nativeMedia";
import { breadcrumb } from "@solara/core";
import { usePageProgress } from "../../store/pageProgress";
import { usePage } from "../layout/pageState";
import { insecureLevel } from "../Toolbar";
import { SMALL_BAR_BUTTON, SMALL_BAR_HEIGHT, SMALL_INSET, SMALL_LIGHTS_CENTER } from "./SmallChrome";
import { PRODUCT } from "../../lib/productName";

const FIELD_LEFT = 84;

export function LittleSolaraWindow() {
  const theme = useTheme();
  const windowId = useWindowId();
  const [shell] = useState(() => littleSolaraShellActive(windowId));
  const [width, setWidth] = useState(0);
  return (
    <View style={{ flex: 1 }} pointerEvents={shell ? "box-none" : "auto"} onLayout={(e) => setWidth(e.nativeEvent.layout.width)}>
      {shell ? null : <WindowBackdrop vibrancy {...theme.backdrop} colors={theme.windowTint} grainOpacity={theme.grain} style={StyleSheet.absoluteFill} />}
      <View
        pointerEvents={shell ? "box-none" : "auto"}
        style={{ flex: 1, flexDirection: "row", paddingTop: SMALL_BAR_HEIGHT, paddingLeft: SMALL_INSET, paddingRight: SMALL_INSET, paddingBottom: SMALL_INSET }}
      >
        <ContentCard small />
      </View>
      {shell ? (
        <ShellLittleSolaraBar width={width} />
      ) : (
        <View style={{ position: "absolute", left: 0, right: 0, top: 0 }}>
          <LittleSolaraBar />
        </View>
      )}
      <CommandPanel windowWidth={width} />
      <DownloadsSurface windowId={windowId} />
    </View>
  );
}

function useSmallBarState() {
  const theme = useTheme();
  const windowId = useWindowId();
  const tab = useActiveTab();
  const panelOpen = useWindowUi().panel.open;
  const profile = useWindowProfile();
  const severalProfiles = useBrowser((s) => s.profileOrder.length > 1);
  const live = useTabLive(tab?.id ?? "");
  const progress = usePageProgress(tab?.id ?? "");
  const insecure = usePage(tab?.id ?? "", (p) => !!insecureLevel(p));
  const buttons = [
    { id: "copy", icon: "link", size: 14, disabled: !tab?.url, tooltip: "Copy Link (⇧⌘C)" },
    { id: "open", icon: "arrow.up.left.and.arrow.down.right", size: 13, tooltip: `Open in ${PRODUCT} (⌘O)` },
  ];
  const count = buttons.length + (severalProfiles ? 1 : 0);
  const url = tab?.url ?? "";
  const host = !url ? "" : url.startsWith("file:") ? "File" : breadcrumb(url).host;
  const state = {
    tabId: tab?.id ?? null,
    icon: insecure ? "insecure" : url ? "favicon" : "search",
    url,
    favicon: tab?.favicon ?? null,
    profileId: tab?.profileId ?? profile.id,
    host,
    title: tab ? tab.customTitle || tab.title : "",
    loading: !!live.isLoading,
    progress,
    hidden: panelOpen || !tab,
    buttons,
    profile: severalProfiles
      ? { swatch: profileAccent(profile), symbol: profileSymbol(profile.icon), text: profile.icon ?? (profile.name.trim()[0] ?? "?").toUpperCase(), emoji: !!profile.icon, tooltip: `Profile: ${profile.name}` }
      : null,
    theme: mediaTheme(theme, { iconDisabled: theme.iconDisabled }),
  };
  return { windowId, tab, state, count };
}

function useBarAnchor(windowId: string, count: number) {
  const holder = useRef<View>(null);
  useEffect(() => {
    void setTrafficLightsCenter(windowId, SMALL_LIGHTS_CENTER);
  }, [windowId]);
  const anchor = () =>
    holder.current?.measureInWindow((x, y, width) => {
      const fieldWidth = width - FIELD_LEFT - barRight(count);
      if (fieldWidth > 0) setUrlAnchor(windowId, { left: x + FIELD_LEFT, top: y + (SMALL_BAR_HEIGHT - 28) / 2, width: fieldWidth, sidebar: { height: 28 } });
    });
  useEffect(anchor, [count]);
  return { holder, anchor };
}

const barRight = (count: number) => SMALL_INSET + count * SMALL_BAR_BUTTON + Math.max(0, count - 1) * 2 + 6;

function ShellLittleSolaraBar({ width }: { width: number }) {
  const theme = useTheme();
  const { windowId, state, count } = useSmallBarState();
  const json = JSON.stringify(state);
  const backdrop = JSON.stringify({ vibrancy: true, colors: theme.windowTint, angle: 180, grainScale: 1, ...theme.backdrop, grainOpacity: theme.grain });
  useEffect(() => void setLittleSolaraBar(windowId, json), [windowId, json]);
  useEffect(() => void setLittleSolaraBackdrop(windowId, backdrop), [windowId, backdrop]);
  useEffect(() => void setTrafficLightsCenter(windowId, SMALL_LIGHTS_CENTER), [windowId]);
  useEffect(() => {
    const fieldWidth = width - FIELD_LEFT - barRight(count);
    if (width > 0 && fieldWidth > 0) setUrlAnchor(windowId, { left: FIELD_LEFT, top: (SMALL_BAR_HEIGHT - 28) / 2, width: fieldWidth, sidebar: { height: 28 } });
  }, [windowId, width, count]);
  return null;
}

function LittleSolaraBar() {
  const { windowId, state, count } = useSmallBarState();
  const { holder, anchor } = useBarAnchor(windowId, count);
  return (
    <View ref={holder} onLayout={anchor} style={{ height: SMALL_BAR_HEIGHT }}>
      <WindowDragRegion style={StyleSheet.absoluteFill} />
      <NativeMediaView kind="littleSolara.bar" windowId={windowId} state={state} />
    </View>
  );
}
