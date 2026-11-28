import { nativeCliIndicatorShown, SolaraHostedView } from "@solara/settings";
import { StyleSheet, type StyleProp, type ViewStyle } from "react-native";
import { useCliIndicator } from "../../lib/cliControl";
import type { Theme } from "../../lib/theme";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";

export type NativeMediaKind = "media.cliPill" | "media.tabBadge" | "littleSolara.bar";

const THEME_KEYS = [
  "panel",
  "panelBorder",
  "textPrimary",
  "textSecondary",
  "textTertiary",
  "placeholder",
  "icon",
  "accent",
  "rowHover",
  "toolbarHover",
  "toolbarPressed",
  "urlPill",
  "goButton",
  "goButtonText",
] as const;

export function mediaTheme(theme: Theme, extra?: Record<string, string>) {
  const colors: Record<string, string> = { ...extra };
  for (const key of THEME_KEYS) colors[key] = theme[key];
  return { dark: theme.dark, colors, panelShadowOpacity: theme.panelShadowOpacity };
}

export function NativeMediaView({ kind, windowId, state, style }: { kind: NativeMediaKind; windowId: string; state: unknown; style?: StyleProp<ViewStyle> }) {
  return <SolaraHostedView kind={kind} windowId={windowId} state={JSON.stringify(state)} pointerEvents="box-none" style={style ?? StyleSheet.absoluteFill} />;
}

type MediaActionHandler = (windowId: string, tabId: string, extra: Record<string, unknown>) => unknown;

const actions: Record<string, MediaActionHandler> = {
  cliIndicator: (_windowId, _tabId, extra) => useCliIndicator.setState({ shown: extra.shown === true }),
};

const cliShownAtLoad = nativeCliIndicatorShown();
if (cliShownAtLoad !== null) useCliIndicator.setState({ shown: cliShownAtLoad });

export function addMediaActions(added: Record<string, MediaActionHandler>) {
  Object.assign(actions, added);
}


addNativeSettingsHandlers({
  "media.action": (windowId: string, name: string, tabId: string, extra: Record<string, unknown>) => actions[name]?.(windowId, tabId, extra ?? {}),
});
