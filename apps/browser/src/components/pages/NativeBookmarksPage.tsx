import { NativePage } from "@solara/settings";
import { StyleSheet } from "react-native";
import { useTheme } from "../../lib/theme";
import { pageThemeState } from "./nativePageTheme";

export function NativeBookmarksPage({ tabId }: { tabId: string }) {
  const theme = useTheme();
  const state = JSON.stringify({ ...pageThemeState(theme), tabId });
  return <NativePage kind="bookmarks" state={state} style={StyleSheet.absoluteFill} />;
}
