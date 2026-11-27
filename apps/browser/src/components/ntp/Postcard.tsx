import { SolaraHostedView } from "@solara/settings";
import { Image, StyleSheet } from "react-native";
import { APP_ICON } from "../../lib/appIcon";
import { hex, useTheme } from "../../lib/theme";

export function ReleaseNotesNotices({ windowId, tabId, onboarding }: { windowId: string; tabId: string; onboarding: boolean }) {
  const theme = useTheme();
  const state = JSON.stringify({
    tabId,
    onboarding,
    dark: theme.dark,
    tokens: { panel: hex(theme.panel), panelBorder: hex(theme.panelBorder), textPrimary: theme.textPrimary, textSecondary: theme.textSecondary },
    iconUri: Image.resolveAssetSource(APP_ICON)?.uri ?? "",
  });
  return <>
    <SolaraHostedView kind="releaseNotesPostcard" windowId={windowId} state={state} style={StyleSheet.absoluteFill} />
    <SolaraHostedView kind="releaseNotesPage" windowId={windowId} state={state} style={StyleSheet.absoluteFill} />
  </>;
}
