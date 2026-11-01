import { endTopStripIncoming, hostedKinds, SolaraHostedView, topStripIncoming, topStripPeek } from "@solara/settings";
import { memo, useEffect, useMemo, useRef } from "react";
import { registerDownloadsAnchor } from "../Downloads";
import { openProfileMenu } from "../ProfileIndicator";
import { Image, StyleSheet, type ViewStyle } from "react-native";
import { useShallow } from "zustand/react/shallow";
import { toggleMute } from "../../lib/actions";
import { shortcutHint, useShortcutHint, withShortcut } from "../../lib/commandShortcuts";
import { PRODUCT } from "../../lib/productName";
import { useLifecycle } from "../../lib/tabLifecycle";
import { hex, profileNameColor, profileTheme, selectedTabGlow, spaceLookSource, useSelectedTabGlow, useTheme, type Theme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { useIsIncognito, useProfiles, useWindowProfile } from "../../store/hooks";
import { engineMark, ENGINE_SYMBOLS } from "../../store/engines";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { clickTab } from "../sidebar/actions";
import { pressGroupClose, pressTabClose } from "../sidebar/closeControl";
import { openGroupMenu, openTabMenu } from "../sidebar/menus";
import { openTileFolderMenu } from "../sidebar/tileFolderUi";
import { toggleNewTabBar } from "../omnibox/newTabBar";
import { developerModeFor } from "../site/developerMode";
import { isDeveloperMode } from "../../lib/developerMode";
import { usePages } from "./pageState";
import { usePagerPages } from "./profilePager";
import { openNewTabInSplit } from "./splitActions";
import { openFolderMenu, openTileFolderStripMenu } from "./stripFolderMenu";
import { tuckTarget } from "./stripGroups";
import { EXTERNAL_DRAG, setInsert, setInsertResolver, useTabDrag } from "./tabDrag";
import "./nativeTabDrag";

let nativeTopStrip: boolean | undefined;
let nativePeek: boolean | undefined;

export function nativeTopStripEnabled(): boolean {
  return (nativeTopStrip ??= hostedKinds().includes("topStrip"));
}

export function nativeStripPeekEnabled(): boolean {
  return (nativePeek ??= hostedKinds().includes("topStripPeek"));
}

const peekLive = new Map<string, (live: boolean, pageWidth: number) => void>();

addNativeSettingsHandlers({
  "topStrip.peek.action": (windowId: string, name: string, extra?: { live?: boolean; pageWidth?: number }) => {
    const s = useBrowser.getState();
    switch (name) {
      case "profileMenu":
        return void openProfileMenu(windowId);
      case "toggleDownloads":
        return s.setDownloadsOpen(windowId, !s.windowUi[windowId]?.downloadsOpen);
      case "live":
        return peekLive.get(windowId)?.(!!extra?.live, extra?.pageWidth ?? 0);
    }
  },
});

const NEW_TAB_MARK: number = PRODUCT === "Solara" ? require("../../../assets/solara/new-tab-mark.png") : require("../../../assets/new-tab-mark.png");
const THEME_KEYS = [
  "textTab",
  "tabSelectedText",
  "tabHover",
  "tabPressed",
  "tabSelected",
  "textPrimary",
  "textSecondary",
  "textTertiary",
  "icon",
  "pinnedResting",
  "pinnedRestingStroke",
  "pinnedSelectedFill",
  "accent",
  "toolbarHover",
  "toolbarPressed",
  "card",
] as const;
const NONE: string[] = [];

addNativeSettingsHandlers({
  "topStrip.action": (windowId: string, name: string, id: string, extra: { meta?: boolean; shift?: boolean; alt?: boolean; collapse?: boolean; split?: boolean }) => {
    const s = useBrowser.getState();
    switch (name) {
      case "click":
        return clickTab(windowId, id, { metaKey: !!extra.meta, shiftKey: !!extra.shift, altKey: !!extra.alt });
      case "activate":
        return s.activate(id);
      case "close":
        return pressTabClose(id);
      case "toggleMute":
        return toggleMute(id);
      case "tabMenu": {
        const tab = s.tabs[id];
        return tab ? void openTabMenu(windowId, tab) : undefined;
      }
      case "groupMenu":
        return void openGroupMenu(windowId, id);
      case "toggleGroup":
        return s.groups[id] ? s.updateGroup(id, { collapsed: !!extra.collapse }) : undefined;
      case "closeGroup":
        return pressGroupClose(id);
      case "tuck": {
        const group = s.groups[id];
        const target = group && tuckTarget(s, windowId, group.profileId, id);
        return target ? s.activate(target) : undefined;
      }
      case "folderMenu":
        return void openFolderMenu(windowId, id);
      case "tileFolder":
        return void openTileFolderStripMenu(windowId, id);
      case "tileFolderMenu":
        return void openTileFolderMenu(windowId, id);
      case "newTab":
        if (extra.split) return openNewTabInSplit(windowId);
        return void (toggleNewTabBar(windowId) || s.newTab(windowId, { newTabCommand: true }));
    }
  },
});

function themeTokens(theme: Theme): Record<string, string> {
  const tokens: Record<string, string> = {};
  for (const key of THEME_KEYS) tokens[key] = theme[key];
  tokens.windowTint = theme.windowTint[0]!;
  tokens.backdropTint = theme.backdrop.tintColor;
  return tokens;
}

function usePageLooks(windowId: string) {
  const { pages, paging } = usePagerPages(windowId);
  const ids = paging ? pages.map((p) => p.id) : NONE;
  const profiles = useBrowser((s) => s.profiles);
  const appDark = useBrowser((s) => s.ui.appDark);
  const source = useBrowser((s) => spaceLookSource(s.settings));
  const glowSetting = useBrowser((s) => s.settings.selectedTabGlow);
  const key = ids.join(",");
  return useMemo(() => {
    if (!key) return null;
    return key.split(",").map((profileId) => {
      const theme = profileTheme(profiles[profileId], appDark, source);
      const glow = selectedTabGlow(theme, glowSetting);
      return {
        profileId,
        dark: theme.dark,
        theme: themeTokens(theme),
        border: theme.tabSelectedBorder.map(hex),
        glow: { color: glow.shadowColor, opacity: glow.shadowOpacity, radius: glow.shadowRadius },
        tidy: false,
        incognito: false,
      };
    });
  }, [key, profiles, appDark, source, glowSetting]);
}

const split = (ids: string) => (ids ? ids.split(",") : NONE);


function useIncomingFile(windowId: string) {
  const point = useTabDrag((d) => (d.windowId === EXTERNAL_DRAG ? (d.overWindow === windowId && d.overPoint ? d.overPoint.join() : "") : null));
  const resolved = useRef<string | null | undefined>(undefined);
  const asked = useRef(0);
  const dragging = point !== null;
  useEffect(() => {
    if (!dragging) return;
    setInsertResolver(windowId, () => resolved.current);
    return () => {
      setInsertResolver(windowId, null);
      resolved.current = undefined;
      void endTopStripIncoming(windowId);
    };
  }, [dragging, windowId]);
  useEffect(() => {
    const ask = ++asked.current;
    if (point === null) return;
    const at = point ? (point.split(",").map(Number) as [number, number]) : null;
    void topStripIncoming(windowId, at).then((beforeId) => {
      if (ask !== asked.current) return;
      resolved.current = beforeId;
      setInsert(windowId, beforeId);
    });
  }, [point, windowId]);
}

function useTopStripState(windowId: string, profileId: string, floating: boolean, pageWidth: number): string {
  const theme = useTheme();
  const glow = useSelectedTabGlow();
  const bands = useBrowser(
    useShallow((s) => {
      const out: Record<string, string> = {};
      if (!s.settings.extendWebsiteColor) return out;
      for (const id of s.windows[windowId]?.tabIds ?? NONE) {
        const tab = s.tabs[id];
        const color = s.live[id]?.themeColor;
        if (tab?.url && color && !isDeveloperMode(tab.url, developerModeFor(s.settings, tab.profileId))) out[id] = color;
      }
      return out;
    }),
  );
  const playing = useBrowser((s) => {
    let out = "";
    for (const id of s.windows[windowId]?.tabIds ?? NONE) if (s.live[id]?.playingAudio) out += (out ? "," : "") + id;
    return out;
  });
  const sleeping = useLifecycle(useShallow((l) => Object.keys(l.discarded).filter((id) => l.discarded[id])));
  const closeHint = useBrowser((s) => shortcutHint("closeTab", s) ?? null);
  const engines = useBrowser(
    useShallow((s) => {
      const out: Record<string, string> = {};
      for (const id of s.windows[windowId]?.tabIds ?? NONE) {
        const mark = engineMark(s, id);
        if (mark) out[id] = ENGINE_SYMBOLS[mark];
      }
      return out;
    }),
  );
  const pages = usePageLooks(windowId);
  const selection = useBrowser(useShallow((s) => s.selection[windowId] ?? NONE));
  const capture = usePages(
    useShallow((p) => {
      const out: Record<string, "screen" | "camera"> = {};
      for (const id of Object.keys(p.pages)) {
        const access = p.pages[id]?.mediaAccess;
        if (access) out[id] = access.screen ? "screen" : "camera";
      }
      return out;
    }),
  );
  useIncomingFile(windowId);

  const state = useMemo(
    () =>
      JSON.stringify({
        profileId,
        dark: theme.dark,
        theme: themeTokens(theme),
        border: theme.tabSelectedBorder.map(hex),
        glow: { color: glow.shadowColor, opacity: glow.shadowOpacity, radius: glow.shadowRadius },
        floating,
        pageWidth,
        playing: split(playing),
        sleeping,
        engines,
        capture,
        bands,
        closeHint,
        newTabMark: Image.resolveAssetSource(NEW_TAB_MARK)?.uri ?? null,
        pages,
        selection,
      }),
    [pages, selection, theme, glow.shadowColor, glow.shadowOpacity, glow.shadowRadius, profileId, floating, pageWidth, playing, sleeping, engines, capture, bands, closeHint],
  );

  return state;
}

export const NativeTopStrip = memo(function NativeTopStrip({
  windowId,
  profileId,
  floating,
  pageWidth,
}: {
  windowId: string;
  profileId: string;
  floating: boolean;
  pageWidth: number;
}) {
  const state = useTopStripState(windowId, profileId, floating, pageWidth);
  return <SolaraHostedView kind={floating ? "topStripFloating" : "topStrip"} windowId={windowId} state={state} style={StyleSheet.absoluteFill} />;
});

export const NativeStripPeek = memo(function NativeStripPeek({
  windowId,
  profileId,
  enabled,
  bandLeft,
  style,
  onLive,
}: {
  windowId: string;
  profileId: string;
  enabled: boolean;
  bandLeft: number;
  style: ViewStyle;
  onLive(live: boolean, pageWidth: number): void;
}) {
  const theme = useTheme();
  const strip = useTopStripState(windowId, profileId, true, 0);
  const incognito = useIsIncognito();
  const profiles = useProfiles().length;
  const profile = useWindowProfile();
  const downloadsOpen = useBrowser((s) => !!s.windowUi[windowId]?.downloadsOpen);
  const hint = useShortcutHint("downloads");
  const latestLive = useRef(onLive);
  latestLive.current = onLive;

  useEffect(() => {
    const report = (live: boolean, pageWidth: number) => latestLive.current(live, pageWidth);
    peekLive.set(windowId, report);
    return () => void (peekLive.get(windowId) === report && peekLive.delete(windowId));
  }, [windowId]);

  useEffect(
    () =>
      registerDownloadsAnchor(windowId, async () => {
        const rect = (await topStripPeek(windowId).state())?.downloads;
        return rect ? { x: rect[0]!, y: rect[1]!, width: rect[2]!, height: rect[3]! } : null;
      }),
    [windowId],
  );

  const state = useMemo(
    () =>
      JSON.stringify({
        strip,
        controls: {
          title: incognito ? "Incognito" : profile.name,
          incognito,
          profiles,
          nameColor: incognito ? theme.textPrimary : profileNameColor(profile, theme.dark),
          downloadsOpen,
          downloadsTooltip: withShortcut("Downloads", hint),
        },
        theme: themeTokens(theme),
        enabled,
        held: downloadsOpen,
        bandLeft,
        look: { fill: hex(theme.windowTint[0]!), border: hex(theme.panelBorder), shadowOpacity: theme.panelShadowOpacity },
      }),
    [strip, incognito, profile, profiles, theme, downloadsOpen, hint, enabled, bandLeft],
  );
  return <SolaraHostedView kind="topStripPeek" windowId={windowId} state={state} style={style} />;
});
