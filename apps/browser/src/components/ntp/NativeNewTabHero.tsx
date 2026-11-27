import { NativeNewTab, type NativeNewTabHandle } from "@solara/settings";
import { useEffect, useRef, useState } from "react";
import { StyleSheet } from "react-native";
import { heroBarFocus } from "../../lib/focusClaims";
import type { Theme } from "../../lib/theme";
import { journeyNavigate } from "../../lib/perfMarks";
import { registerHeroBar } from "../omnibox/barState";
import { openFromBar, useNativeBar, useThemeTokens } from "../omnibox/nativeBar";
import type { Disposition } from "../omnibox/open";

export type HeroLayout = { height: number; headingHeight: number };

export function NativeNewTabHero({
  windowId,
  tabId,
  onboarding,
  onIntro,
  under,
  theme,
  marks,
  onLayout,
}: {
  windowId: string;
  tabId: string;
  onboarding: boolean;
  onIntro(): void;
  under: number;
  theme: Theme;
  marks: { sun: string; back: string; front: string };
  onLayout(layout: HeroLayout): void;
}) {
  const ref = useRef<NativeNewTabHandle>(null);
  const [profileId, setProfileId] = useState("");
  const themeProps = useThemeTokens(theme);
  const go = (url: string, disposition: Disposition = "current") => {
    if (!url) return;
    if (disposition === "current") journeyNavigate(tabId);
    openFromBar(url, tabId, disposition);
  };
  const { props, claim } = useNativeBar({ ref, windowId, tabId, profileId, driverId: `${windowId}:hero`, focusTag: heroBarFocus(tabId), go });

  useEffect(() => {
    const focus = () => {
      void ref.current?.focus();
      claim();
    };
    return registerHeroBar(windowId, tabId, focus);
  }, [windowId, tabId]);

  return (
    <NativeNewTab
      ref={ref}
      style={StyleSheet.absoluteFill}
      windowId={windowId}
      tabId={tabId}
      onboarding={onboarding}
      onProfile={(e) => setProfileId(e.nativeEvent.profileId)}
      onIntro={onIntro}
      under={under}
      dark={!!theme.dark}
      theme={themeProps}
      marks={marks}
      {...props}
      onBarLayout={(e) => onLayout({ height: e.nativeEvent.height, headingHeight: e.nativeEvent.headingHeight })}
    />
  );
}
