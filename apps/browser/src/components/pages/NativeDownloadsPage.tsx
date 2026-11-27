import { NativePage } from "@solara/settings";
import { StyleSheet } from "react-native";
import { useTheme } from "../../lib/theme";
import { pageThemeState } from "./nativePageTheme";

export function NativeDownloadsPage({ tabId }: { tabId: string }) {
  const theme = useTheme();
  return <NativePage kind="downloads" state={JSON.stringify({ tabId, ...pageThemeState(theme) })} style={StyleSheet.absoluteFill} />;
}
