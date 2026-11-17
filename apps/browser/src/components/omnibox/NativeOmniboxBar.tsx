import { NativeOmnibox, type NativeOmniboxHandle, type NativeOmniboxVariant } from "@solara/settings";
import { useRef, useState } from "react";
import { StyleSheet, View } from "react-native";
import { commandBarFocus } from "../../lib/focusClaims";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { useWindowId, useWindowProfileId } from "../../store/hooks";
import type { NewTabTarget } from "../../store/types";
import { setPopover } from "../layout/pageState";
import type { BarDismissal } from "./barState";
import { openFromBar, useNativeBar, useThemeTokens } from "./nativeBar";
import { openFromNewTabBar } from "./newTabBar";
import type { Disposition } from "./open";
import { runOmniboxFallback } from "./nativeActions";

export function NativeOmniboxBar({
  variant,
  tabId,
  initialText = "",
  onCancel,
  onDone = onCancel,
  opensTab,
  floating = false,
  panel,
  idle = false,
}: {
  variant: NativeOmniboxVariant;
  panel?: string;
  idle?: boolean;
  floating?: boolean;
  tabId: string;
  initialText?: string;
  opensTab?: NewTabTarget;
  onCancel?(): void;
  onDone?(reason?: BarDismissal): void;
}) {
  const theme = useTheme();
  const windowId = useWindowId();
  const profileId = useWindowProfileId();
  const incognito = useBrowser((s) => !!s.windows[windowId]?.incognito);
  const currentUrl = useBrowser((s) => (opensTab ? "" : (s.tabs[tabId]?.url ?? "")));
  const themeProps = useThemeTokens(theme);
  const ref = useRef<NativeOmniboxHandle>(null);
  const [height, setHeight] = useState<number | null>(null);

  const go = (url: string, disposition: Disposition = "current") => {
    if (!url) return;
    if (opensTab && (disposition === "current" || disposition === "newTab")) return openFromNewTabBar(windowId, opensTab, url);
    openFromBar(url, tabId, disposition);
  };
  const { props } = useNativeBar({ ref, windowId, tabId, profileId, driverId: idle ? "" : `${windowId}:${variant}`, focusTag: commandBarFocus, go });

  return (
    <View style={panel === undefined ? { height: height ?? undefined } : StyleSheet.absoluteFill} pointerEvents={panel === undefined ? "auto" : "box-none"}>
      <NativeOmnibox
        ref={ref}
        panel={panel}
        style={panel === undefined ? { flex: 1, minHeight: height ?? 1 } : StyleSheet.absoluteFill}
        windowId={windowId}
        tabId={tabId}
        profileId={profileId}
        variant={variant}
        floating={floating}
        opensTab={!!opensTab}
        initialText={initialText}
        incognito={incognito}
        currentUrl={currentUrl}
        dark={!!theme.dark}
        theme={themeProps}
        {...props}
        onDone={(e) => runOmniboxFallback("done", e.nativeEvent, () => onDone?.(e.nativeEvent.reason ?? undefined))}
        onCancel={(e) => runOmniboxFallback("cancel", e.nativeEvent, () => onCancel?.())}
        onSiteControls={(e) => runOmniboxFallback("siteControls", e.nativeEvent, () => {
          onCancel?.();
          setPopover(tabId, "siteControls");
        })}
        onBarLayout={(e) => setHeight(e.nativeEvent.height)}
      />
    </View>
  );
}
