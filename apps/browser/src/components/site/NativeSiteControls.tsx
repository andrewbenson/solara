import { nativeWorkspaceCommand } from "@solara/settings";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { openSettings } from "../settings/windows";
import { webviews } from "../../lib/webviews";
import { openPageIn, togglePageEngine } from "../../lib/engines";
import { patchPage, setPopover, usePage } from "../layout/pageState";
import { showToast } from "../layout/splitActions";
import type { PageEngine, SecurityInfo } from "@solara/solaracore";
import type { Tab } from "../../store/types";
import type { Settings } from "../../store/settings";
import { builtInEngine, recommendedEngineFor, ruleFor, tabEngine } from "../../store/engines";
import { useShallow } from "zustand/react/shallow";
import { NativeSitePanelView } from "@solara/settings";
import { useEffect, useRef, useState } from "react";
import { StyleSheet } from "react-native";
import { useTheme } from "../../lib/theme";
import { useBrowser, type BrowserState } from "../../store/browser";
import { engineProfile, isIncognitoProfile, tabLabel } from "../../store/model";
import { useThemeTokens } from "../omnibox/nativeBar";
import { siteControlsMounted } from "../overlayGates";

type Rect = [number, number, number, number];

type SiteControlsProps = { tabId: string; open: boolean; right?: number; left?: number; top: number };

export function useNativeSiteControlsShown(open: boolean) {
  const [latched, setLatched] = useState(open);
  const current = useRef(open);
  current.current = open;
  useEffect(() => { if (open) setLatched(true); }, [open]);
  return { shown: siteControlsMounted(open, latched), onClosed: () => { if (!current.current) setLatched(false); } };
}

export function NativeSiteControls({ tabId, open, right, left, top, onClosed }: SiteControlsProps & { onClosed: () => void }) {
  const theme = useTheme();
  const tokens = useThemeTokens(theme);
  const onClose = () => setPopover(tabId, null);
  const security = usePage(tabId, (p) => p.security);
  const blocked = usePage(tabId, (p) => p.blocked);
  const access = usePage(tabId, (p) => p.mediaAccess);
  const playingAudio = useBrowser((s) => !!s.live[tabId]?.playingAudio);
  const fallbackContext = useBrowser(useShallow((s) => siteControlsFallbackContext(s, tabId)));
  const request = JSON.stringify({
    tabId, fallbackContext, open, top, right, left, dark: !!theme.dark, theme: tokens,
    security, blocked, camera: !!access?.camera, microphone: !!access?.microphone, playingAudio,
  });
  return <NativeSitePanelView style={StyleSheet.absoluteFill} request={request} onSitePanelDismiss={onClose} onSitePanelClosed={onClosed} />;
}

function siteControlsFallbackContext(s: BrowserState, tabId: string) {
  const tab = s.tabs[tabId];
  if (!tab) return null;
  return {
    tabId: tab.id, windowId: tab.windowId, url: tab.url, title: tab.title, customTitle: tab.customTitle ?? null,
    label: tabLabel(tab), favicon: tab.favicon ?? null, profileId: tab.profileId, profile: engineProfile(tab.profileId),
    privatePage: isIncognitoProfile(tab.profileId), pageEngine: tabEngine(s, tabId), muted: tab.muted, zoom: tab.zoom,
    showFullUrl: s.settings.showFullUrl, developerMode: s.settings.developerMode, sleepInactiveTabs: s.settings.sleepInactiveTabs,
    keepAwakeSites: s.settings.keepAwakeSites, engineRule: ruleFor(s, tab.url) ?? null,
    streamingSite: builtInEngine(s, tab.url) === "webkit", recommendedEngine: recommendedEngineFor(s, tab.url),
  };
}

addNativeSettingsHandlers({
  "site.settings": (tabId: string, url: string, changed: Partial<Pick<Settings, "showFullUrl" | "developerMode" | "keepAwakeSites">>) => {
    const s = useBrowser.getState();
    if (s.tabs[tabId]?.url !== url) return;
    s.updateSettings(changed);
  },
  "site.muted": (tabId: string, url: string, muted: boolean) => {
    const s = useBrowser.getState();
    if (s.tabs[tabId]?.url !== url) return;
    s.updateTab(tabId, { muted });
  },
  "site.security": (tabId: string, security: SecurityInfo) => patchPage(tabId, { security }),
  "site.page": (tabId: string, method: string, args: unknown[]) => {
    const page = webviews.get(tabId);
    if (method === "getSecurityInfo") return page?.getSecurityInfo();
    if (method === "zoomStep") return page?.zoomStep(Math.sign(Number(args[0])) as -1 | 0 | 1);
    if (method === "setMuted") return page?.setMuted(!!args[0]);
    if (method === "clearSiteData") return page?.clearSiteData();
    if (method === "reload") return page?.reload();
  },
  "site.action": (tabId: string, action: string, args: { rect: Rect; clickAt: number; engine: PageEngine; rule: PageEngine | null; title: string; detail: string; icon: string }, snapshot: Pick<Tab, "url" | "title" | "customTitle"> & { windowId: string }) => {
    if (action === "share") return nativeWorkspaceCommand("share", JSON.stringify({ tabId, anchor: args.rect }), snapshot.windowId);
    if (action === "copy") return nativeWorkspaceCommand("copyUrl", JSON.stringify({ tabId: tabId }), snapshot.windowId);
    if (action === "find") return useBrowser.getState().setFind(tabId, { open: true, replace: false, focusRequest: Date.now() });
    if (action === "engine") return openPageIn(tabId, args.engine, { rule: args.rule });
    if (action === "other-engine") return togglePageEngine(tabId);
    if (action === "privacy") return openSettings("privacy");
    if (action === "sleepSettings") return openSettings("tabs", null, args.detail || null);
    if (action === "toast") return showToast(snapshot.windowId, args.title, args.detail, { icon: args.icon });
  },
});
