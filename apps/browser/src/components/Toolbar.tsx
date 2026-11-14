import { Hairline } from "@solara/shell";
import { useShallow } from "zustand/react/shallow";
import { Animated, StyleSheet, View } from "react-native";
import { layout, useTheme } from "../lib/theme";
import { useBrowser } from "../store/browser";
import type { Tab } from "../store/types";
import type { ToolbarGeometry } from "./layout/geometry";
import type { PageState } from "./layout/pageState";
import { TOOLBAR_DIVIDER_THICKNESS, toolbarPalette, useEasedColor } from "./layout/toolbarColors";
import { DeveloperStripes } from "./site/DeveloperStripes";
import { useTabDeveloperMode, useToolbarSiteColor } from "./site/developerMode";
import { NativeToolbar } from "./NativeToolbar";

type ToolbarTab = Pick<Tab, "id" | "url" | "title" | "windowId" | "zoom">;
const toolbarTab = (t: Tab | undefined): ToolbarTab | undefined =>
  t && { id: t.id, url: t.url, title: isWebUrl(t.url) ? "" : t.title, windowId: t.windowId, zoom: t.zoom };
const isWebUrl = (url: string) => /^https?:/i.test(url);
export const useToolbarTab = (tabId: string | undefined) => useBrowser(useShallow((s) => toolbarTab(tabId ? s.tabs[tabId] : undefined)));

export const URL_FIELD = { top: 21.2 - 15, height: 30 } as const;
export const GLYPH = 13;
export const urlFieldRight = (inSplit: boolean, extensionsWidth: number) => (inSplit ? 12 + 2 * 28 : 12) + extensionsWidth;
const LOCK = { left: 7, width: 18, gap: 3 } as const;
const NATIVE_BADGE = { left: 1, size: 28, gap: 5.5 } as const;
export const urlTextLeft = (insecure: boolean, native = false) =>
  !insecure ? 8 : native ? NATIVE_BADGE.left + NATIVE_BADGE.size + NATIVE_BADGE.gap : LOCK.left + LOCK.width + LOCK.gap;
export const insecureLevel = (p: PageState) => {
  const level = p.security?.chromium;
  return level === "warning" || level === "dangerous" ? level : null;
};

type ToolbarProps = {
  tabId: string;
  geometry: ToolbarGeometry;
  windowId: string;
  inSplit: boolean;
  focused: boolean;
  bare?: boolean;
  windowToolbar?: boolean;
};

export function Toolbar(props: ToolbarProps) {
  return <NativeToolbar {...props} />;
}

export function ToolbarBackdrop({ tabId }: { tabId: string }) {
  const theme = useTheme();
  const url = useBrowser((s) => s.tabs[tabId]?.url ?? "");
  const palette = toolbarPalette(theme, useToolbarSiteColor(tabId));
  const band = useEasedColor(palette.background);
  const developer = useTabDeveloperMode(tabId);
  return (
    <View pointerEvents="none" style={{ height: layout.toolbarHeight }}>
      <Animated.View style={[StyleSheet.absoluteFill, { backgroundColor: band }]} />
      {developer && <DeveloperStripes palette={palette} />}
      {url ? <Hairline color={palette.divider} thickness={TOOLBAR_DIVIDER_THICKNESS} style={{ position: "absolute", left: 0, right: 0, bottom: 0, height: 1 }} /> : null}
    </View>
  );
}
