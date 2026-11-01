import { hostedKinds, hostedSidebarShell, nativeOmniboxAvailable, publishSettingsTopic, sidebarAddressBarAvailable, SolaraHostedView, windowShellActive } from "@solara/settings";
import type { DroppedItem } from "@solara/shell";
import { memo, useEffect, useMemo } from "react";
import { Image, StyleSheet } from "react-native";
import { useShallow } from "zustand/react/shallow";
import { closeTab, toggleMute } from "../../lib/actions";
import { shortcutHint } from "../../lib/commandShortcuts";
import { PRODUCT } from "../../lib/productName";
import { useLifecycle } from "../../lib/tabLifecycle";
import { hex, profileNameColor, profileTheme, selectedTabGlow, spaceLookSource, useSelectedTabGlow, useTheme, type Theme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { engineMark, ENGINE_SYMBOLS } from "../../store/engines";
import { useSettings } from "../../store/hooks";
import { activeTabId, isIncognitoProfile } from "../../store/model";
import { cleanedTabsFor } from "../../store/organize";
import { canTidyPins } from "../../store/tidyPins";
import { cleanUpUpsellChoice, useCleanUpUpsellCount } from "./cleanUpUpsell";
import { usePagerPages } from "../layout/profilePager";
import { openNewTabInSplit } from "../layout/splitActions";
import { isDeveloperMode } from "../../lib/developerMode";
import { developerModeFor } from "../site/developerMode";
import { toggleNewTabBar } from "../omnibox/newTabBar";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { clickTab, commitRename, endRename, startRename } from "./actions";
import { pressGroupClose, pressTabClose } from "./closeControl";
import { dismissHover, nativeRowHover } from "./hover";
import { closeAllTabs, middleClickTab, openGroupMenu, openOverflowMenu, openSidebarMenu, openTabMenu } from "./menus";
import { setSidebarUi, sidebarUi, useSidebarUi } from "./state";
import { useSidebarTokens } from "./tokens";
import { useMedia, useSession } from "../media/state";
import { useArtwork } from "../media/artwork";
import { mediaTheme, playerState } from "../media/nativeMedia";
import { useSidebarPlayerTab } from "../media/SidebarPlayer";
import { useTab } from "../../store/hooks";
import { usePages } from "../layout/pageState";
import { openDroppedItems } from "../layout/fileDrop";
import { pagerFor } from "../layout/profilePager";
import type { TabPlacement } from "../../store/organize";
import { publishNativeLive, runNativeLive } from "./nativeLive";
import { tidyPins } from "./tidyPinsUi";
import { downloadsIn } from "../../store/ui";
import { useShortcutHint, withShortcut } from "../../lib/commandShortcuts";
import { openProfileMenu } from "../ProfileIndicator";
import { registerDownloadsAnchor } from "../Downloads";
import { useProfileDotsShown } from "../profiles/ProfileDots";
import { useTabDrag } from "../layout/tabDrag";
import { SidebarAddressBarState } from "./AddressBar";
import { closeFolderPanelIn, openTileFolderMenu, toggleFolderPanel } from "./tileFolderUi";

let nativeSidebar: boolean | undefined;

export function nativeSidebarEnabled(): boolean {
  nativeSidebar ??= hostedKinds().includes("sidebar");
  if (nativeSidebar) publishNativeLive();
  return nativeSidebar;
}

const SHELL_TOPIC = "sidebar.shell";
const shellColumns: Record<string, object> = {};

export function nativeSidebarShell(windowId: string): boolean {
  return nativeSidebarEnabled() && hostedKinds().includes(SHELL_TOPIC) && windowShellActive(windowId) && pagerFor(windowId).nativeOwned;
}

export function shellColumnFitsAddressBar(addressBar: boolean): boolean {
  return !addressBar || (nativeOmniboxAvailable() && sidebarAddressBarAvailable());
}

function publishShellColumn(windowId: string, column: object | null) {
  if (column) shellColumns[windowId] = column;
  else if (shellColumns[windowId]) delete shellColumns[windowId];
  else return;
  publishSettingsTopic(SHELL_TOPIC, { windows: shellColumns });
}

type ShellEvent = { items?: DroppedItem[]; placement?: string | null; width?: number | null };

addNativeSettingsHandlers({
  [SHELL_TOPIC]: (windowId: string, event: string, extra: ShellEvent) => {
    const s = useBrowser.getState();
    switch (event) {
      case "drop": {
        const placement = extra.placement ? (JSON.parse(extra.placement) as TabPlacement) : null;
        return void openDroppedItems(windowId, extra.items ?? [], placement);
      }
      case "profileMenu":
        return void openProfileMenu(windowId);
      case "toggleDownloads":
        return s.setDownloadsOpen(windowId, !s.windowUi[windowId]?.downloadsOpen);
      case "liveWidth": {
        const { [windowId]: _, ...rest } = sidebarUi().dragWidth;
        return setSidebarUi({ dragWidth: typeof extra.width === "number" ? { ...rest, [windowId]: extra.width } : rest });
      }
      case "commitWidth":
        return typeof extra.width === "number" ? s.updateSettings({ sidebarWidth: extra.width }) : undefined;
    }
  },
});

export type ShellColumn = { top: number; header: number; bottom: number; clip: boolean };

function useShellChrome(windowId: string, addressBar: boolean, theme: Theme): string {
  const incognito = useBrowser((s) => !!s.windows[windowId]?.incognito);
  const profile = useBrowser((s) => s.profiles[s.windows[windowId]?.profileId ?? ""]);
  const profiles = useBrowser((s) => s.profileOrder.length);
  const downloads = useBrowser((s) => downloadsIn(s, windowId).length > 0);
  const downloadsOpen = useBrowser((s) => !!s.windowUi[windowId]?.downloadsOpen);
  const hint = useShortcutHint("downloads");
  const savedWidth = useBrowser((s) => s.settings.sidebarWidth ?? 190);
  const dotsShown = useProfileDotsShown();
  const order = useBrowser(useShallow((s) => s.profileOrder));
  const names = useBrowser(useShallow((s) => order.map((id) => s.profiles[id]?.name ?? "")));
  const { pages } = usePagerPages(windowId);
  const dropOver = useTabDrag((d) => d.overWindow === windowId);
  return useMemo(
    () =>
      JSON.stringify({
        controls: {
          title: incognito ? "Incognito" : (profile?.name ?? ""),
          incognito,
          profiles,
          nameColor: incognito || !profile ? theme.textPrimary : profileNameColor(profile, theme.dark),
          downloadsOpen,
          downloadsTooltip: withShortcut("Downloads", hint),
        },
        downloads,
        addressBar,
        dark: theme.dark,
        theme: { ...themeTokens(theme), panel: theme.panel, panelBorder: theme.panelBorder },
        dots: dotsShown ? order.map((id, i) => ({ id, name: names[i] ?? "", slot: pages.find((p) => p.id === id)?.slot ?? null })) : [],
        savedWidth,
        dropOver,
      }),
    [incognito, profile, profiles, theme, downloadsOpen, hint, downloads, addressBar, dotsShown, order, names, pages, savedWidth, dropOver],
  );
}

function ShellColumnState({ windowId, state, chrome, addressWidth, top, header, bottom, clip }: ShellColumn & { windowId: string; state: string; chrome: string; addressWidth: number | null }) {
  useEffect(() => publishShellColumn(windowId, { state, chrome, top, header, bottom, clip }), [windowId, state, chrome, top, header, bottom, clip]);
  useEffect(() => () => publishShellColumn(windowId, null), [windowId]);
  useEffect(
    () =>
      registerDownloadsAnchor(windowId, async () => {
        const rect = (JSON.parse(await hostedSidebarShell(windowId)) as { downloads?: number[] } | null)?.downloads;
        return rect ? { x: rect[0]!, y: rect[1]!, width: rect[2]!, height: rect[3]! } : null;
      }),
    [windowId],
  );
  return addressWidth === null ? null : <SidebarAddressBarState width={addressWidth} />;
}

const NEW_TAB_MARK: number = PRODUCT === "Solara" ? require("../../../assets/solara/new-tab-mark.png") : require("../../../assets/new-tab-mark.png");
const THEME_KEYS = [
  "textTab",
  "tabSelectedText",
  "tabHover",
  "tabPressed",
  "tabSelected",
  "rowHover",
  "divider",
  "textPrimary",
  "textSecondary",
  "textTertiary",
  "icon",
  "pinnedResting",
  "pinnedRestingStroke",
  "pinnedSelectedFill",
  "pinnedSelectedRim",
  "pinnedSelectedOutline",
  "accent",
  "toolbarHover",
  "toolbarPressed",
] as const;
const NONE: string[] = [];

type Mods = { meta?: boolean; shift?: boolean; alt?: boolean };


addNativeSettingsHandlers({
  "sidebar.action": (
    windowId: string,
    name: string,
    id: string,
    extra: Mods & { kind?: "tab" | "group" | "folder" | "live"; split?: boolean; text?: string | null; action?: string; item?: string | null },
  ) => {
    const s = useBrowser.getState();
    if (name === "hover") return nativeRowHover(windowId, extra.kind && id ? { kind: extra.kind, id } : null);
    dismissHover();
    switch (name) {
      case "clicked":
        if (s.selectionAnchors[windowId] !== id) s.setSelectionAnchor(windowId, id);
        if (s.selection[windowId]?.length) s.setSelection(windowId, []);
        return;
      case "click":
        return clickTab(windowId, id, { metaKey: !!extra.meta, shiftKey: !!extra.shift, altKey: !!extra.alt });
      case "close":
        return pressTabClose(id);
      case "middleClick":
        return s.tabs[id]?.pinned && !s.tabs[id]?.pinnedAsRow ? void closeTab(id) : middleClickTab(id);
      case "rename":
        return void startRename(windowId, { kind: extra.kind === "group" ? "group" : "tab", id });
      case "backToPinned":
        return s.returnToPinnedUrl(id);
      case "tileDoubleClick":
        if (activeTabId(s, windowId) === id) s.returnToPinnedUrl(id);
        return;
      case "toggleMute":
        return toggleMute(id);
      case "tabMenu": {
        const tab = s.tabs[id];
        return tab ? void openTabMenu(windowId, tab) : undefined;
      }
      case "groupMenu":
        return void openGroupMenu(windowId, id);
      case "toggleGroup": {
        const group = s.groups[id];
        return group ? s.updateGroup(id, { collapsed: !group.collapsed }) : undefined;
      }
      case "closeGroup":
        return pressGroupClose(id);
      case "sidebarMenu":
        return void openSidebarMenu(windowId);
      case "overflowMenu":
        return void openOverflowMenu(windowId);
      case "newTab":
        if (extra.split) return openNewTabInSplit(windowId);
        return void (toggleNewTabBar(windowId) || s.newTab(windowId, { newTabCommand: true }));
      case "folder":
        return void toggleFolderPanel(windowId, id);
      case "folderMenu":
        return void openTileFolderMenu(windowId, id);
      case "scrolled":
        return void closeFolderPanelIn(windowId);
      case "tidy":
        return tidyPins(windowId, id || undefined);
      case "clear":
        return closeAllTabs(windowId);
      case "cleanUp":
        return cleanUpUpsellChoice(windowId, id);
      case "live":
        return runNativeLive(windowId, id, extra.action ?? "", extra.item ?? null, !!extra.meta);
      case "renamed": {
        const target = { kind: extra.kind === "group" ? ("group" as const) : ("tab" as const), id };
        return typeof extra.text === "string" ? commitRename(target, extra.text) : endRename(target);
      }
    }
  },
});

function liveIds(s: ReturnType<typeof useBrowser.getState>, windowId: string, key: "isLoading" | "playingAudio"): string {
  const ids = s.windows[windowId]?.tabIds ?? NONE;
  let out = "";
  for (const id of ids) if (s.live[id]?.[key]) out += (out ? "," : "") + id;
  return out;
}

const split = (ids: string) => (ids ? ids.split(",") : NONE);

function themeTokens(theme: Theme): Record<string, string> {
  const tokens: Record<string, string> = {};
  for (const key of THEME_KEYS) tokens[key] = theme[key];
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
  const tidy = useBrowser((s) => ids.filter((id) => canTidyPins(s, windowId, id)).join(","));
  const key = ids.join(",");
  return useMemo(() => {
    if (!key) return null;
    const tidyIds = new Set(split(tidy));
    return key.split(",").map((profileId) => {
      const theme = profileTheme(profiles[profileId], appDark, source);
      const glow = selectedTabGlow(theme, glowSetting);
      return {
        profileId,
        dark: theme.dark,
        theme: themeTokens(theme),
        border: theme.tabSelectedBorder.map(hex),
        glow: { color: glow.shadowColor, opacity: glow.shadowOpacity, radius: glow.shadowRadius },
        tidy: tidyIds.has(profileId),
        incognito: isIncognitoProfile(profileId),
      };
    });
  }, [key, profiles, appDark, source, glowSetting, tidy]);
}

function useNativeSidebarPlayer(windowId: string, profileId: string, theme: Theme, groupFill: string, groupStroke: string) {
  const tabId = useSidebarPlayerTab(windowId, profileId);
  const session = useSession(tabId);
  const tab = useTab(tabId);
  const artwork = useArtwork(tabId ?? "", session?.artwork);
  return useMemo(
    () => (session && tab ? playerState(session, tab, artwork, mediaTheme(theme, { groupFill: hex(groupFill), groupStroke: hex(groupStroke) })) : null),
    [session, tab, artwork, theme, groupFill, groupStroke],
  );
}

export const NativeSidebar = memo(function NativeSidebar({ windowId, profileId, addressBar, column, width }: { windowId: string; profileId: string; addressBar: boolean; column?: ShellColumn; width?: number }) {
  const theme = useTheme();
  const glow = useSelectedTabGlow();
  const selection = useBrowser((s) => s.selection[windowId] ?? NONE);
  const loading = useBrowser((s) => liveIds(s, windowId, "isLoading"));
  const playing = useBrowser((s) => liveIds(s, windowId, "playingAudio"));
  const sleeping = useLifecycle(useShallow((l) => Object.keys(l.discarded).filter((id) => l.discarded[id])));
  const renaming = useSidebarUi((u) => (u.renaming?.windowId === windowId && (u.renaming.kind === "tab" || u.renaming.kind === "group") ? `${u.renaming.kind}:${u.renaming.id}` : null));
  const clear = useSettings((s) => s.showClearButton);
  const tidy = useBrowser((s) => canTidyPins(s, windowId, profileId));
  const newTabAtTop = useSettings((s) => s.newTabButtonPosition === "top");
  const iconRing = useSettings((s) => s.pinnedTabIconRing);
  const cleaned = useBrowser((s) => cleanedTabsFor(s, windowId).length);
  const upsell = useCleanUpUpsellCount(windowId, true);
  const closeHint = useBrowser((s) => shortcutHint("closeTab", s) ?? null);
  const developer = useBrowser((s) => {
    let out = "";
    for (const id of s.windows[windowId]?.tabIds ?? NONE) {
      const tab = s.tabs[id];
      if (tab && isDeveloperMode(tab.url, developerModeFor(s.settings, tab.profileId))) out += (out ? "," : "") + id;
    }
    return out;
  });
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
  const tokens = useSidebarTokens();
  const player = useNativeSidebarPlayer(windowId, profileId, theme, tokens.groupFill, tokens.groupStroke);
  const pip = useMedia((m) => Object.keys(m.pipOpen).filter((id) => m.pipOpen[id]).sort().join(","));
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

  const state = useMemo(() => {
    return JSON.stringify({
      profileId,
      dark: theme.dark,
      theme: themeTokens(theme),
      border: theme.tabSelectedBorder.map(hex),
      glow: { color: glow.shadowColor, opacity: glow.shadowOpacity, radius: glow.shadowRadius },
      selection,
      loading: split(loading),
      playing: split(playing),
      sleeping,
      closeHint,
      backHint: null,
      renaming,
      addressBar,
      tidy,
      clear,
      iconRing,
      newTabAtTop,
      incognito: isIncognitoProfile(profileId),
      cleaned,
      upsell: upsell || null,
      product: PRODUCT,
      engines,
      developer: split(developer),
      newTabMark: Image.resolveAssetSource(NEW_TAB_MARK)?.uri ?? null,
      pages,
      player,
      pip: split(pip),
      capture,
      badge: [tokens.badge, tokens.badgeGlyph],
    });
  }, [player, pip, capture, tokens.badge, tokens.badgeGlyph, pages, theme, glow.shadowColor, glow.shadowOpacity, glow.shadowRadius, profileId, selection, loading, playing, sleeping, closeHint, renaming, addressBar, tidy, clear, iconRing, newTabAtTop, cleaned, upsell, engines, developer]);

  const chrome = useShellChrome(windowId, addressBar, theme);
  if (column) return <ShellColumnState windowId={windowId} state={state} chrome={chrome} addressWidth={addressBar && width ? width : null} {...column} />;
  return <SolaraHostedView kind="sidebar" windowId={windowId} state={state} style={StyleSheet.absoluteFill} />;
});
