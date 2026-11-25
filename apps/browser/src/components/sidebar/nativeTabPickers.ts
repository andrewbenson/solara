import { hex, useTheme } from "../../lib/theme";
import { useSidebarTokens } from "./tokens";

export function useTabPickerTheme() {
  const theme = useTheme();
  const tokens = useSidebarTokens();
  return {
    dark: !!theme.dark,
    theme: {
      panel: hex(theme.panel),
      panelBorder: hex(theme.panelBorder),
      panelShadowOpacity: String(theme.panelShadowOpacity),
      textPrimary: theme.textPrimary,
      textSecondary: theme.textSecondary,
      textTertiary: theme.textTertiary,
      placeholder: theme.placeholder,
      selection: theme.selection,
      divider: theme.divider,
      rowSelected: theme.rowSelected,
      icon: theme.icon,
      switcherFocus: tokens.switcherFocus,
      switcherOutline: tokens.switcherOutline,
    },
  };
}

export type NativeSearchRow = { kind: "tab" | "closed"; id: string; title: string; url: string; favicon: string | null; icon: string | null; profileId: string; detail: string | null };

export function hostOf(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return "";
  }
}

