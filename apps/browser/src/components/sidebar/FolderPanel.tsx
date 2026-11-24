import { requireOptionalNativeModule } from "expo-modules-core";
import { useEffect } from "react";
import { useTheme } from "../../lib/theme";

type FolderPanelNative = {
  look(windowId: string, json: string): Promise<void>;
};

const nativePanel = requireOptionalNativeModule<FolderPanelNative>("SolaraFolderPanel");

export function FolderPanel({ windowId }: { windowId: string }) {
  const theme = useTheme();
  const look = JSON.stringify({ dark: !!theme.dark, theme: panelTokens(theme), panelShadowOpacity: theme.panelShadowOpacity });
  useEffect(() => {
    void nativePanel?.look(windowId, look);
  }, [look, windowId]);
  return null;
}

const panelTokens = (theme: ReturnType<typeof useTheme>) => ({
  panel: theme.panel,
  panelBorder: theme.panelBorder,
  textPrimary: theme.textPrimary,
  textSecondary: theme.textSecondary,
  textTab: theme.textTab,
  tabHover: theme.tabHover,
  tabPressed: theme.tabPressed,
  pinnedSelectedFill: theme.pinnedSelectedFill,
});
