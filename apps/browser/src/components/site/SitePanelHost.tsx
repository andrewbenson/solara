import { nativeWorkspaceCommand, NativeSitePanelView } from "@solara/settings";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { webviewMount, webviews } from "../../lib/webviews";
import type { Tab } from "../../store/types";
import type { Settings } from "../../store/settings";
import { builtInEngine, recommendedEngineFor, ruleFor, tabEngine } from "../../store/engines";
import { useShallow } from "zustand/react/shallow";
import { useBrowser, type BrowserState } from "../../store/browser";
import { engineProfile, isIncognitoProfile, tabLabel } from "../../store/model";
import { nativeOwnsWorkspace } from "../../store/nativeStore";
import { useEffect, useRef, useState } from "react";
import { StyleSheet } from "react-native";
import { useTheme } from "../../lib/theme";
import { usePage } from "../layout/pageState";
import { useThemeTokens } from "../omnibox/nativeBar";
import { siteControlsMounted } from "../overlayGates";

type Rect = [number, number, number, number];

type SiteControlsProps = { tabId: string; open: boolean; right?: number; left?: number; top: number };

function useNativeSiteControlsShown(open: boolean) {
  const [latched, setLatched] = useState(open);
  const current = useRef(open);
  current.current = open;
  useEffect(() => { if (open) setLatched(true); }, [open]);
  return { shown: siteControlsMounted(open, latched), onClosed: () => { if (!current.current) setLatched(false); } };
}

export function SiteControls({ tabId, open, right, left, top }: SiteControlsProps) {
  const { shown, onClosed } = useNativeSiteControlsShown(open);
  const theme = useTheme();
  const tokens = useThemeTokens(theme);
  const security = usePage(tabId, (p) => p.security);
  const blocked = usePage(tabId, (p) => p.blocked);
  const access = usePage(tabId, (p) => p.mediaAccess);
  const fallbackContext = useBrowser(useShallow((s) => nativeOwnsWorkspace() ? null : siteControlsFallbackContext(s, tabId)));
  const request = JSON.stringify({
    tabId, fallbackContext, open, top, right, left, dark: !!theme.dark, theme: tokens,
    security, blocked, camera: !!access?.camera, microphone: !!access?.microphone,
  });
  return shown ? <NativeSitePanelView style={StyleSheet.absoluteFill} request={request} onSitePanelClosed={onClosed} /> : null;
}

type LegacySiteSource = Pick<Tab, "url" | "windowId" | "profileId"> & {
  navigationSeq: number | null;
  mount: number | null;
};

const pageMountIds = new WeakMap<object, number>();
let nextMount = 0;

function pageMountId(tabId: string) {
  const mount = webviewMount(tabId);
  if (!mount) return null;
  const existing = pageMountIds.get(mount);
  if (existing !== undefined) return existing;
  pageMountIds.set(mount, ++nextMount);
  return nextMount;
}

function currentLegacySite(s: BrowserState, tabId: string, source: LegacySiteSource) {
  const tab = s.tabs[tabId];
  return !nativeOwnsWorkspace() && tab && tab.url === source.url && tab.windowId === source.windowId &&
    tab.profileId === source.profileId && (tab.navigation?.seq ?? null) === source.navigationSeq &&
    s.windows[tab.windowId]?.profileId === tab.profileId;
}

function siteControlsFallbackContext(s: BrowserState, tabId: string) {
  const tab = s.tabs[tabId];
  if (!tab) return null;
  return {
    tabId: tab.id, windowId: tab.windowId, url: tab.url, title: tab.title, customTitle: tab.customTitle ?? null,
    label: tabLabel(tab), favicon: tab.favicon ?? null, profileId: tab.profileId, profile: engineProfile(tab.profileId),
    privatePage: isIncognitoProfile(tab.profileId), navigationSeq: tab.navigation?.seq ?? null, mount: pageMountId(tabId), pageEngine: tabEngine(s, tabId), muted: tab.muted, playingAudio: s.live[tabId]?.playingAudio === true, zoom: tab.zoom,
    showFullUrl: s.settings.showFullUrl, developerMode: s.settings.developerMode, sleepInactiveTabs: s.settings.sleepInactiveTabs,
    keepAwakeSites: s.settings.keepAwakeSites, engineRule: ruleFor(s, tab.url) ?? null,
    streamingSite: builtInEngine(s, tab.url) === "webkit", recommendedEngine: recommendedEngineFor(s, tab.url),
  };
}

addNativeSettingsHandlers({
  "site.settings": (tabId: string, source: LegacySiteSource, changed: Partial<Pick<Settings, "showFullUrl" | "developerMode" | "keepAwakeSites">>) => {
    const s = useBrowser.getState();
    if (!currentLegacySite(s, tabId, source)) return;
    s.updateSettings(changed);
  },
  "site.muted": (tabId: string, source: LegacySiteSource, muted: boolean) => {
    const s = useBrowser.getState();
    if (!currentLegacySite(s, tabId, source)) return;
    s.updateTab(tabId, { muted });
  },
  "site.page": (tabId: string, method: string, args: unknown[], source: LegacySiteSource) => {
    if (!currentLegacySite(useBrowser.getState(), tabId, source) || source.mount === null || source.mount !== pageMountId(tabId)) return;
    const page = webviews.get(tabId);
    if (method === "getSecurityInfo") return page?.getSecurityInfo();
    if (method === "zoomStep") return page?.zoomStep(Math.sign(Number(args[0])) as -1 | 0 | 1);
    if (method === "setMuted") return page?.setMuted(!!args[0]);
    if (method === "clearSiteData") return page?.clearSiteData();
    if (method === "reload") return page?.reload();
  },
  "site.action": (tabId: string, action: string, args: { rect?: Rect }, snapshot: LegacySiteSource) => {
    const s = useBrowser.getState();
    if (!currentLegacySite(s, tabId, snapshot)) return;
    if (action === "share") return nativeWorkspaceCommand("share", JSON.stringify({ tabId, anchor: args.rect }), snapshot.windowId);
    if (action === "copy") return nativeWorkspaceCommand("copyUrl", JSON.stringify({ tabId: tabId }), snapshot.windowId);
    if (action === "find") return s.setFind(tabId, { open: true, replace: false, focusRequest: Date.now() });
  },
});
