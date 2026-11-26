import { SolaraHostedView } from "@solara/settings";
import { StyleSheet } from "react-native";
import { hex, useTheme } from "../../lib/theme";

export function PersonalizeButton({ windowId }: { windowId: string }) {
  const theme = useTheme();
  return <SolaraHostedView
    kind="personalize"
    windowId={windowId}
    state={JSON.stringify({
      dark: theme.dark,
      tokens: {
        panel: hex(theme.panel),
        panelBorder: hex(theme.panelBorder),
        panelShadowOpacity: String(theme.panelShadowOpacity),
        textPrimary: theme.textPrimary,
        textSecondary: theme.textSecondary,
        textTertiary: theme.textTertiary,
        icon: theme.icon,
        toolbarHover: theme.toolbarHover,
        toolbarPressed: theme.toolbarPressed,
      },
    })}
    style={StyleSheet.absoluteFill}
  />;
}

if (__DEV__) {
  type HostedDebugModule = { setPersonalizeOpen?(windowId: string | null): void };
  const debug = globalThis as {
    expo?: { modules?: { SolaraHosted?: HostedDebugModule } };
    acPersonalize?: { open(windowId: string | null): void };
  };
  debug.acPersonalize = { open: (windowId) => debug.expo?.modules?.SolaraHosted?.setPersonalizeOpen?.(windowId) };
}
