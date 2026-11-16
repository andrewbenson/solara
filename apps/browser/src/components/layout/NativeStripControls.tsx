import { hostedKinds, SolaraHostedView } from "@solara/settings";
import { memo, useEffect, useMemo, useRef } from "react";
import { View, type ViewStyle } from "react-native";
import { withShortcut, useShortcutHint } from "../../lib/commandShortcuts";
import { profileNameColor, useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { useIsIncognito, useProfiles, useWindowProfile } from "../../store/hooks";
import { registerDownloadsAnchor } from "../Downloads";
import { useTabDrag } from "./tabDrag";

let nativeControls: boolean | undefined;

export function nativeStripControlsEnabled(): boolean {
  return (nativeControls ??= hostedKinds().includes("topStripControls"));
}

const DOWNLOADS_BOX = 34;

export const NativeStripControls = memo(function NativeStripControls({ windowId, indicator, leadingInset, windowFullscreen, style }: { windowId: string; indicator: boolean; leadingInset: number; windowFullscreen?: boolean; style: ViewStyle }) {
  const theme = useTheme();
  const incognito = useIsIncognito();
  const profiles = useProfiles().length;
  const profile = useWindowProfile();
  const downloadsOpen = useBrowser((s) => !!s.windowUi[windowId]?.downloadsOpen);
  const hint = useShortcutHint("downloads");
  const box = useRef<View>(null);
  const downloadsTop = windowFullscreen === undefined && indicator ? 0.5 : 0;

  useEffect(() => {
    const node = box.current;
    if (!node) return;
    return registerDownloadsAnchor(
      windowId,
      () =>
        new Promise((resolve) =>
          node.measureInWindow((x, y, width, height) =>
            resolve(width > 0 && height > 0 ? { x: x + width - DOWNLOADS_BOX, y: y + downloadsTop, width: DOWNLOADS_BOX, height: DOWNLOADS_BOX } : null),
          ),
        ),
    );
  }, [windowId, downloadsTop, windowFullscreen]);

  const state = useMemo(
    () =>
      JSON.stringify({
        leadingInset,
        windowFullscreen,
        controls: {
          title: incognito ? "Incognito" : profile.name,
          incognito,
          profiles,
          nameColor: incognito ? theme.textPrimary : profileNameColor(profile, theme.dark),
          downloadsOpen,
          downloadsTooltip: withShortcut("Downloads", hint),
        },
        theme: {
          textPrimary: theme.textPrimary,
          tabHover: theme.tabHover,
          tabPressed: theme.tabPressed,
          icon: theme.icon,
          toolbarHover: theme.toolbarHover,
          toolbarPressed: theme.toolbarPressed,
        },
      }),
    [incognito, profile, profiles, theme, downloadsOpen, hint, leadingInset, windowFullscreen],
  );
  return (
    <View ref={box} collapsable={false} pointerEvents="box-none" style={style}>
      <SolaraHostedView kind="topStripControls" windowId={windowId} state={state} style={{ flex: 1 }} />
    </View>
  );
});

export const NativeStripDropGlow = memo(function NativeStripDropGlow({ windowId, style }: { windowId: string; style: ViewStyle }) {
  const theme = useTheme();
  const over = useTabDrag((d) => d.overWindow === windowId);
  const state = useMemo(() => JSON.stringify({ over, accent: theme.accent, dark: theme.dark }), [over, theme.accent, theme.dark]);
  return <SolaraHostedView pointerEvents="none" kind="topStripGlow" windowId={windowId} state={state} style={style} />;
});
