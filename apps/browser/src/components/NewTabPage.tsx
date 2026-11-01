import { PowerUp } from "@solara/shaders";
import { useEffect, useState } from "react";
import { AccessibilityInfo, Image, StyleSheet, View } from "react-native";
import { layout, useTheme } from "../lib/theme";
import { useBrowser } from "../store/browser";
import { useWindowId, useWindowProfileId } from "../store/hooks";
import { NewTabExtras } from "./ntp";
import { NativeNewTabHero, type HeroLayout } from "./ntp/NativeNewTabHero";
import { DIA_OFFSET, newTabBarTop } from "./ntp/newTabLayout";
import { useOnboarding } from "./onboarding/state";

const BAR_HEIGHT = 112;
const MARKS = {
  green: { back: require("../../assets/solara/ntp-mark-back.png"), front: require("../../assets/solara/ntp-mark-front.png"), sun: require("../../assets/solara/ntp-mark-sun.png") },
  plum: { back: require("../../assets/solara/ntp-mark-plum-back.png"), front: require("../../assets/solara/ntp-mark-plum-front.png"), sun: require("../../assets/solara/ntp-mark-plum-sun.png") },
  blue: { back: require("../../assets/solara/ntp-mark-blue-back.png"), front: require("../../assets/solara/ntp-mark-blue-front.png"), sun: require("../../assets/solara/ntp-mark-blue-sun.png") },
  purple: { back: require("../../assets/solara/ntp-mark-purple-back.png"), front: require("../../assets/solara/ntp-mark-purple-front.png"), sun: require("../../assets/solara/ntp-mark-purple-sun.png") },
  pink: { back: require("../../assets/solara/ntp-mark-pink-back.png"), front: require("../../assets/solara/ntp-mark-pink-front.png"), sun: require("../../assets/solara/ntp-mark-pink-sun.png") },
  red: { back: require("../../assets/solara/ntp-mark-red-back.png"), front: require("../../assets/solara/ntp-mark-red-front.png"), sun: require("../../assets/solara/ntp-mark-red-sun.png") },
  orange: { back: require("../../assets/solara/ntp-mark-orange-back.png"), front: require("../../assets/solara/ntp-mark-orange-front.png"), sun: require("../../assets/solara/ntp-mark-orange-sun.png") },
  yellow: { back: require("../../assets/solara/ntp-mark-yellow-back.png"), front: require("../../assets/solara/ntp-mark-yellow-front.png"), sun: require("../../assets/solara/ntp-mark-yellow-sun.png") },
  neutral: { back: require("../../assets/solara/ntp-mark-neutral-back.png"), front: require("../../assets/solara/ntp-mark-neutral-front.png"), sun: require("../../assets/solara/ntp-mark-neutral-sun.png") },
};
type Size = { width: number; height: number };
const introPlayed = new Set<string>();

let reduceMotion = false;
AccessibilityInfo.isReduceMotionEnabled().then((on) => (reduceMotion = on), () => {});
AccessibilityInfo.addEventListener("reduceMotionChanged", (on) => (reduceMotion = on));

function sameSize(a: Size, b: Size) {
  return a.width === b.width && a.height === b.height;
}

export function barWidth(viewWidth: number) {
  const content = viewWidth < 708 ? (viewWidth <= 636 ? viewWidth - 20 : 616) : viewWidth < 1700 ? 652 : 774;
  return Math.min(content, viewWidth - 28);
}

const markUris = new Map<string, { sun: string; back: string; front: string }>();

function marksFor(color: string) {
  let uris = markUris.get(color);
  if (!uris) {
    const set = (MARKS as Record<string, (typeof MARKS)["green"]>)[color] ?? MARKS.green;
    const uri = (source: number) => Image.resolveAssetSource(source)?.uri ?? "";
    markUris.set(color, (uris = { sun: uri(set.sun), back: uri(set.back), front: uri(set.front) }));
  }
  return uris;
}

export function NewTabPage(props: { tabId: string; toolbar?: boolean }) {
  return <NativeNewTabPage {...props} />;
}

function NativeNewTabPage({ tabId, toolbar = true }: { tabId: string; toolbar?: boolean }) {
  const theme = useTheme();
  const windowId = useWindowId();
  const profileId = useWindowProfileId();
  const incognito = useBrowser((s) => !!s.windows[windowId]?.incognito);
  const onboarding = useOnboarding((s) => s.windowId === windowId);
  const [size, setSize] = useState<Size | null>(null);
  const [hero, setHero] = useState<HeroLayout>({ height: BAR_HEIGHT, headingHeight: 0 });
  const [playIntro] = useState(() => !introPlayed.has(tabId));
  useEffect(() => {
    introPlayed.add(tabId);
  }, [tabId]);
  const under = toolbar ? 0 : layout.toolbarHeight;
  const heading = !onboarding && incognito;
  const bar = size
    ? (() => {
        const width = barWidth(size.width);
        const x = Math.max(size.width / 2 - width / 2, 14) + DIA_OFFSET;
        const top = newTabBarTop(size.height, under, heading ? hero.headingHeight : 0);
        return { x, y: top, width, height: hero.height };
      })()
    : null;
  return (
    <View style={{ flex: 1 }} onLayout={(e) => {
        const next = e.nativeEvent.layout;
        setSize((prev) => (prev && sameSize(prev, next) ? prev : next));
      }}>
      {playIntro && theme.powerUpPalette && bar && (
        <PowerUp style={StyleSheet.absoluteFill} palette={theme.powerUpPalette} speed={1} origin={0.5} cornerRadius={20} halo={bar} />
      )}
      <NativeNewTabHero
        windowId={windowId}
        tabId={tabId}
        profileId={profileId}
        incognito={incognito}
        onboarding={onboarding}
        playIntro={playIntro && !reduceMotion}
        under={under}
        theme={theme}
        marks={marksFor(theme.profileColor === "incognito" ? "neutral" : theme.profileColor)}
        onLayout={setHero}
      />
      {size && bar && <NewTabExtras size={size} bar={bar} />}
    </View>
  );
}

