import { onHostedEvent, SolaraHostedView } from "@solara/settings";
import { useEffect } from "react";
import { StyleSheet } from "react-native";
import { create } from "zustand";
import { hex, PROFILE_COLORS, useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import type { ProfileColor } from "../../store/types";

const usePanel = create<{ windowId: string | null }>(() => ({ windowId: null }));
const setOpen = (windowId: string | null) => usePanel.setState({ windowId });

export function PersonalizeButton({ windowId }: { windowId: string }) {
  const theme = useTheme();
  const open = usePanel((state) => state.windowId === windowId);
  const window = useBrowser((state) => state.windows[windowId]);
  const profile = useBrowser((state) => window ? state.profiles[window.profileId] : undefined);
  const fallbackLayout = useBrowser((state) => state.settings.tabLayout);
  useEffect(() => () => {
    if (usePanel.getState().windowId === windowId) setOpen(null);
  }, [windowId]);
  useEffect(() => onHostedEvent("personalize", windowId, (name, payload) => {
    const state = useBrowser.getState();
    const current = state.windows[windowId];
    if (!current || current.incognito) return;
    if (name === "open") {
      if (payload.open === true) setOpen(windowId);
      else if (payload.open === false && usePanel.getState().windowId === windowId) setOpen(null);
      return;
    }
    if (usePanel.getState().windowId !== windowId || payload.profileId !== current.profileId) return;
    if (name === "color" && typeof payload.color === "string" && Object.hasOwn(PROFILE_COLORS, payload.color) && state.profiles[current.profileId]) {
      state.updateProfile(current.profileId, { color: payload.color as ProfileColor });
    } else if (name === "layout" && (payload.layout === "sidebar" || payload.layout === "top") && payload.layout !== (current.tabLayout ?? state.settings.tabLayout)) {
      state.toggleTabLayout(windowId);
    }
  }), [windowId]);
  if (!window || window.incognito) return null;
  return <SolaraHostedView
    kind="personalize"
    windowId={windowId}
    state={JSON.stringify({
      open,
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
      color: profile?.color ?? null,
      layout: window.tabLayout ?? fallbackLayout,
      canPickColor: !!profile,
      profileId: window.profileId,
    })}
    style={StyleSheet.absoluteFill}
  />;
}

if (__DEV__) (globalThis as { acPersonalize?: unknown }).acPersonalize = { open: setOpen };
