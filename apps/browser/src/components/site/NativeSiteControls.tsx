import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { openSettings } from "../settings/windows";
import { webviews } from "../../lib/webviews";
import { openPageIn, togglePageEngine } from "../../lib/engines";
import { patchPage, setPopover, usePage } from "../layout/pageState";
import { showToast } from "../layout/splitActions";
import { toggleCastPicker } from "../media/cast";
import { togglePictureInPicture, useMedia } from "../media/state";
import { copyPageUrl } from "./selection";
import { shareTab } from "./share";
import type { PageEngine, SecurityInfo } from "@solara/solaracore";
import type { Tab } from "../../store/types";
import { NativeSitePanelView, type NativeSitePanelEvent } from "@solara/settings";
import { translation } from "@solara/shell";
import { useEffect, useRef, useState } from "react";
import { StyleSheet } from "react-native";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { isIncognitoProfile } from "../../store/model";
import { activateExtension, openWebStore, showExtensionMenu, useWindowExtensions } from "../extensions/state";
import { useThemeTokens } from "../omnibox/nativeBar";
import { siteControlsMounted } from "../overlayGates";
import { addExtensionMenu } from "./SiteExtensions";
import { chooseLanguage } from "./TranslateControls";
import { defaultTarget, isNeverTranslated, languageName, setNeverTranslate, toggleTranslation, useTranslateState } from "./translate";

type Rect = [number, number, number, number];

type SitePanelItem =
  | { kind: "section"; title: string; tight?: boolean }
  | { kind: "extensions"; columns: number; extensions: { id: string; name: string; icon?: string | null; symbol?: string; dimmed?: boolean }[] }
  | {
      kind: "row";
      id: string;
      icon?: string;
      title: string;
      pressable?: boolean;
      accessory?: { kind: "toggle"; value: boolean };
    }
  | { kind: "separator" }
  | { kind: "slot"; id: "extensions" | "translate"; columns?: number };

type SitePanelHandler = {
  press?(rect: Rect, clickAt: number): void;
  menu?(rect: Rect): void;
  toggle?(value: boolean): void;
  zoom?(step: number): void;
};

const anchorOf = ([x, y, width, height]: Rect) => ({ x, y, width, height });

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
  const windowId = useBrowser((s) => s.tabs[tabId]?.windowId ?? "");
  const extensions = useWindowExtensions(windowId);
  const translate = useTranslateState(tabId);
  const tab = useBrowser((s) => s.tabs[tabId]);
  useBrowser((s) => s.settings.neverTranslateSites);
  const onClose = () => setPopover(tabId, null);
  const all: Record<string, SitePanelHandler> = {};
  const items: SitePanelItem[] = [{ kind: "slot", id: "extensions" }, { kind: "slot", id: "translate" }];
  const video = useMedia((m) => !!m.sessions[tabId]?.hasVideo);
  const pip = useMedia((m) => !!m.pipOpen[tabId]);
  const security = usePage(tabId, (p) => p.security);
  const blocked = usePage(tabId, (p) => p.blocked);
  const access = usePage(tabId, (p) => p.mediaAccess);
  const playingAudio = useBrowser((s) => !!s.live[tabId]?.playingAudio);
  const contributed: { extensions: SitePanelItem[]; translate: SitePanelItem[] } = { extensions: [], translate: [] };

  for (const item of items) {
    if (item.kind !== "slot") continue;
    const expanded = contributed[item.id];
    if (item.id === "extensions") {
      expanded.push({ kind: "section", title: "Extensions" });
      expanded.push({
        kind: "extensions",
        columns: item.columns ?? 4,
        extensions: [
          ...extensions.map((ext) => ({ id: `ext:${ext.id}`, name: ext.pinned ? `${ext.actionTitle || ext.name} (pinned)` : ext.actionTitle || ext.name, icon: ext.actionIcon || ext.icon || null })),
          { id: "ext:add", name: "Add Extension", icon: null, symbol: "plus" },
        ],
      });
      for (const ext of extensions) {
        all[`ext:${ext.id}`] = {
          press: (rect) => {
            onClose();
            void activateExtension(windowId, ext, anchorOf(rect), undefined, tabId);
          },
          menu: () => void showExtensionMenu(windowId, ext),
        };
      }
      all["ext:add"] = {
        press: () => {
          onClose();
          openWebStore(windowId);
        },
        menu: () => void addExtensionMenu(windowId, onClose),
      };
      continue;
    }
    const never = tab ? isNeverTranslated(tab.profileId, tab.url) : false;
    if (!translation || !tab || (!translate.source && translate.status === "idle" && !never)) continue;
    const translated = translate.status !== "idle";
    if (!never) {
      expanded.push({
        kind: "row",
        id: "translate:toggle",
        icon: translated ? "arrow.uturn.backward" : "translate",
        title: translated ? `Show Original (${languageName(translate.source ?? "")})` : `Translate to ${languageName(defaultTarget())}`,
        pressable: true,
      });
      expanded.push({ kind: "row", id: "translate:choose", icon: "globe", title: "Choose Another Language…", pressable: true });
      all["translate:toggle"] = {
        press: () => {
          onClose();
          toggleTranslation(tabId);
        },
      };
      all["translate:choose"] = {
        press: () => {
          onClose();
          void chooseLanguage(tabId);
        },
      };
    }
    if (!isIncognitoProfile(tab.profileId)) {
      expanded.push({ kind: "row", id: "translate:never", icon: "nosign", title: "Never Translate This Site", accessory: { kind: "toggle", value: never } });
      all["translate:never"] = { toggle: (v) => setNeverTranslate(tabId, v) };
    }
    expanded.push({ kind: "separator" });
  }
  const request = JSON.stringify({
    tabId, open, top, right, left, dark: !!theme.dark, theme: tokens,
    video, pip, security, blocked, camera: !!access?.camera, microphone: !!access?.microphone, playingAudio,
    extensions: contributed.extensions, translate: contributed.translate,
  });
  const onEvent = (e: NativeSitePanelEvent) => {
    const handler = all[e.id];
    if (!handler) return;
    if (e.kind === "press") handler.press?.(e.rect, e.clickAt);
    else if (e.kind === "menu") handler.menu?.(e.rect);
    else if (e.kind === "toggle") handler.toggle?.(e.value);
    else handler.zoom?.(e.step);
  };
  return <NativeSitePanelView style={StyleSheet.absoluteFill} request={request} onSitePanelDismiss={onClose} onSitePanelClosed={onClosed} onSitePanelEvent={(e) => onEvent(e.nativeEvent)} />;
}

addNativeSettingsHandlers({
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
    if (action === "share") return shareTab(snapshot, snapshot.windowId, null, args.rect);
    if (action === "copy") return copyPageUrl(tabId);
    if (action === "find") return useBrowser.getState().setFind(tabId, { open: true, replace: false, focusRequest: Date.now() });
    if (action === "cast") return toggleCastPicker(snapshot.windowId);
    if (action === "pip") { void togglePictureInPicture(tabId, { clickAt: args.clickAt, control: 0 }); return; }
    if (action === "engine") return openPageIn(tabId, args.engine, { rule: args.rule });
    if (action === "other-engine") return togglePageEngine(tabId);
    if (action === "privacy") return openSettings("privacy");
    if (action === "toast") return showToast(snapshot.windowId, args.title, args.detail, { icon: args.icon });
  },
});
