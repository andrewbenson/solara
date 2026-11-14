import type { Theme } from "../../lib/theme";

type SadTabTheme = Pick<Theme, "dark" | "textPrimary" | "textSecondary" | "panel" | "panelBorder" | "panelShadowOpacity" | "goButton" | "goButtonText">;

export function sadTabHostState(tabId: string, crashed: boolean, unresponsive: boolean, theme: SadTabTheme) {
  const { dark, textPrimary, textSecondary, panel, panelBorder, panelShadowOpacity, goButton, goButtonText } = theme;
  return { tabId, mode: crashed ? "crashed" : unresponsive ? "unresponsive" : null, dark, textPrimary, textSecondary, panel, panelBorder, panelShadowOpacity, goButton, goButtonText };
}
