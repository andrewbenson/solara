import { appUrlOrigin, breadcrumb, urlForDisplay } from "@solara/core";
import { NativeToolbarView, type ToolbarClick } from "@solara/settings";
import { translation, WindowDragRegion } from "@solara/shell";
import { useEffect, useMemo } from "react";
import { StyleSheet, View } from "react-native";
import { useShortcutHint, withShortcut } from "../lib/commandShortcuts";
import { withLivePage } from "../lib/livePage";
import { layout, useTheme } from "../lib/theme";
import { webviews } from "../lib/webviews";
import { useBrowser } from "../store/browser";
import { useIsBookmarked, useSettings, useTabLive } from "../store/hooks";
import { bookmarkProfileId, tabLayoutOf } from "../store/model";
import { toggleBookmarkFromUI } from "../lib/bookmarkWriter";
import { usePageProgress } from "../store/pageProgress";
import { openModeFor, openUrl } from "./bookmarks/actions";
import { showNativePanelNow } from "./CommandPanel";
import { useNativeToolbarExtensions, useToolbarExtensionsWidth } from "./extensions/ToolbarExtensions";
import { pageExtensionButtons, pageExtensionsWidth, WEBKIT_PILL_ACTION } from "./extensions/webkitPill";
import { openPageIn } from "../lib/engines";
import { tabEngine } from "../store/engines";
import { type ToolbarGeometry } from "./layout/geometry";
import { closeHistoryMenu, goBack, goForward, historyItems, openHistoryMenu, useHistoryAvailability, useHistoryMenu } from "./layout/history";
import { setPopover, usePage, usePages } from "./layout/pageState";
import { closePane, openSplitPane, showSplitMenu } from "./layout/splitActions";
import { toolbarPalette } from "./layout/toolbarColors";
import { setToolbarExtensionsWidth } from "./layout/windowLayout";
import { showUrlBarMenu } from "./omnibox/paste";
import { endUrlEdit, startUrlEdit, submitUrlEdit, useTabDeveloperMode, useToolbarSiteColor, useUrlEdit } from "./site/developerMode";
import { developerReload, showDeveloperReloadMenu } from "./site/DeveloperButtons";
import { claimFocusTag, urlEditFocus } from "../lib/focusClaims";
import { findNodeHandle, Image } from "react-native";
import { useRef } from "react";
import { showTranslateMenu } from "./site/TranslateControls";
import { languageName, toggleTranslation, useTranslateState } from "./site/translate";
import { insecureLevel, urlFieldRight, useToolbarTab } from "./Toolbar";
import { installUpdateNow, UPDATE_PILL_SHORT_TEXT, UPDATE_PILL_TEXT, updatePillTooltip, usePendingUpdate } from "../lib/pendingUpdate";

const isWebUrl = (url: string) => /^https?:/i.test(url);

const LIGHT_STRIPES = require("../../assets/developer-stripes-light.png");
const DARK_STRIPES = require("../../assets/developer-stripes-dark.png");
export const stripesUri = (palette: { text: string }) => {
  const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})/i.exec(palette.text);
  const onDark = !m || 0.2126 * parseInt(m[1]!, 16) + 0.7152 * parseInt(m[2]!, 16) + 0.0722 * parseInt(m[3]!, 16) > 128;
  return Image.resolveAssetSource(onDark ? LIGHT_STRIPES : DARK_STRIPES)?.uri ?? null;
};
const DIA_INK = {
  light: { urlHost: "rgba(0,0,0,0.8)", urlPath: "rgba(0,0,0,0.3)", icon: "rgba(0,0,0,0.83)", iconDisabled: "rgba(0,0,0,0.43)" },
  dark: { urlHost: "rgba(255,255,255,0.55)", urlPath: "rgba(255,255,255,0.2)", icon: "rgba(255,255,255,0.51)", iconDisabled: "rgba(255,255,255,0.24)" },
};
const developerUrl = (url: string) => url.replace(/^([a-z][a-z0-9+.-]*:\/\/[^/?#]*)\/$/i, "$1");
const DEVELOPER_PANELS = [
  { panel: "console", icon: "terminal", tooltip: "Toggle Console" },
  { panel: "network", icon: "network", tooltip: "Toggle Network Panel" },
  { panel: "elements", icon: "scope", tooltip: "Inspect Element" },
] as const;

function safeDecode(s: string) {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
}

const togglePopover = (tabId: string, name: "siteControls" | "zoom" | "popups") =>
  setPopover(tabId, (usePages.getState().popover[tabId] ?? null) === name ? null : name);

type NativeToolbarProps = {
  tabId: string;
  geometry: ToolbarGeometry;
  windowId: string;
  inSplit: boolean;
  focused: boolean;
  bare?: boolean;
  sidebar?: { extensionLimit: number };
};

export function NativeToolbar(props: NativeToolbarProps) {
  const view = useRef<View>(null);
  const { tab, json, onClick, onAnchors } = useNativeToolbarModel(props, () => findNodeHandle(view.current));

  if (!tab || !json) return <View style={{ height: layout.toolbarHeight }} />;

  return (
    <View style={{ height: layout.toolbarHeight }}>
      <WindowDragRegion style={StyleSheet.absoluteFill} />
      <View ref={view} collapsable={false} style={StyleSheet.absoluteFill} pointerEvents="box-none">
        <NativeToolbarView
          style={StyleSheet.absoluteFill}
          state={json}
          onToolbarClick={(e) => void onClick(e.nativeEvent)}
          onToolbarAnchors={(e) => onAnchors(e.nativeEvent.anchors)}
        />
      </View>
    </View>
  );
}

export function useNativeToolbarModel({ tabId, geometry, windowId, inSplit, focused, bare, sidebar }: NativeToolbarProps, focusHandle: () => number | null) {
  const theme = useTheme();
  const tab = useToolbarTab(tabId);
  const isLoading = useTabLive(tabId, (l) => l.isLoading);
  const siteColor = useToolbarSiteColor(tabId);
  const palette = toolbarPalette(theme, sidebar ? null : siteColor);
  const history = useHistoryAvailability(tabId);
  const extensionLimit = sidebar?.extensionLimit ?? Infinity;
  const engine = useBrowser((s) => tabEngine(s, tabId));
  const extensionsWidth = pageExtensionsWidth(engine, useToolbarExtensionsWidth(windowId, extensionLimit));
  const extensions = useNativeToolbarExtensions(windowId, tabId, extensionLimit);
  const extensionsJson = JSON.stringify(pageExtensionButtons(engine, extensions.buttons));
  useEffect(() => {
    if (!sidebar) setToolbarExtensionsWidth(windowId, extensionsWidth);
  }, [windowId, extensionsWidth, !sidebar]);
  const showFullUrl = useSettings((s) => s.showFullUrl);
  const topTabs = useBrowser((s) => tabLayoutOf(s, windowId) === "top");
  const pending = usePendingUpdate();
  const update = pending && topTabs && !sidebar && (!inSplit || focused) ? { text: UPDATE_PILL_TEXT, short: UPDATE_PILL_SHORT_TEXT, tooltip: updatePillTooltip(pending) } : null;
  const bookmarked = useIsBookmarked(tab?.url ?? "");
  const insecure = usePage(tabId, insecureLevel);
  const developer = useTabDeveloperMode(tabId);
  const editing = useUrlEdit((u) => u.tabId === tabId);
  const editRequest = useUrlEdit((u) => u.request);
  useEffect(() => () => endUrlEdit(tabId), [tabId]);
  useEffect(() => {
    if (!developer) endUrlEdit(tabId);
  }, [developer, tabId]);
  const popups = usePage(tabId, (p) => p.popups.length);
  const capture = usePage(tabId, (p) => p.mediaAccess);
  const popover = usePages((p) => p.popover[tabId] ?? null);
  const progress = usePageProgress(tabId);
  const translate = useTranslateState(tabId);
  const hints = {
    sidebar: useShortcutHint("toggleSidebar"),
    back: useShortcutHint("back"),
    forward: useShortcutHint("forward"),
    reload: useShortcutHint("reload"),
    bookmark: useShortcutHint("bookmarkPage"),
    split: useShortcutHint("openSplitPane"),
  };

  const state = useMemo(() => {
    if (!tab) return null;
    const url = tab.url;
    const isFile = url.startsWith("file:");
    const shownHost = isFile ? "File" : url ? breadcrumb(url).host : "";
    const full = isFile ? ` ${safeDecode(url.slice("file://".length))}` : url ? urlForDisplay(url) : "";
    const path = !isFile && full.startsWith(shownHost) ? full.slice(shownHost.length) : full;
    const schemeEnd = url.indexOf("://");
    const scheme = insecure && shownHost && schemeEnd > 0 ? url.slice(0, schemeEnd + 3) : "";
    const host = scheme + shownHost;
    const restTrail = insecure ? path : showFullUrl ? path.replace(/\/$/, "") : !isWebUrl(url) && appUrlOrigin(url) && tab.title ? ` / ${tab.title}` : "";
    const small = { size: 13, box: 24, radius: 6 };
    const translated = translate.status !== "idle";
    const trailing = [
      ...(capture
        ? [{
            id: "capture",
            icon: capture.screen ? "rectangle.inset.filled.on.rectangle" : capture.camera ? "video.fill" : "mic.fill",
            size: 12,
            box: 24,
            color: "#FF453A",
            plain: true,
            tooltip: `This page is using your ${[capture.camera && "camera", capture.microphone && "microphone", capture.screen && "screen"].filter(Boolean).join(" and ")}`,
          }]
        : []),
      ...(developer
        ? [
            { id: "divider-dev-start", icon: "" },
            ...DEVELOPER_PANELS.map((p) => ({ id: `dev:${p.panel}`, icon: p.icon, ...small, tooltip: p.tooltip })),
            { id: "divider-dev-end", icon: "" },
          ]
        : []),
      ...(translation && (translate.source || translated)
        ? [{
            id: "translate",
            icon: "translate",
            ...small,
            color: translated ? theme.accent : undefined,
            menu: true,
            tooltip: translated ? `Show Original (${languageName(translate.source ?? "")})` : "Translate this page",
          }]
        : []),
      ...(Math.abs(tab.zoom - 1) >= 0.001
        ? [{ id: "zoom", icon: tab.zoom > 1 ? "plus.magnifyingglass" : "minus.magnifyingglass", ...small, active: popover === "zoom", tooltip: `Zoom: ${Math.round(tab.zoom * 100)}%` }]
        : []),
      ...(popups > 0 ? [{ id: "popups", icon: "macwindow.badge.plus", ...small, active: popover === "popups", tooltip: "Pop-ups blocked on this page" }] : []),
    ];
    return {
      tabId,
      height: layout.toolbarHeight,
      bare: !!bare,
      focused,
      palette: sidebar ? palette : { ...palette, ...DIA_INK[(palette.background ? /^#FFFFFF/i.test(palette.text) : !!theme.dark) ? "dark" : "light"] },
      accent: theme.accent,
      geometry: { ...geometry, urlRight: urlFieldRight(inSplit, extensionsWidth) },
      left: [
        ...(geometry.sidebarButton !== null ? [{ id: "sidebar", icon: "sidebar.left", size: 13, tooltip: withShortcut("Auto-Hide Tabs", hints.sidebar) }] : []),
        { id: "back", icon: "chevron.left", size: 13, enabled: history.back, menu: true, longPress: true, middle: true, tooltip: withShortcut("Go Back", hints.back) },
        { id: "forward", icon: "chevron.right", size: 13, enabled: history.forward, menu: true, longPress: true, middle: true, tooltip: withShortcut("Go Forward", hints.forward) },
        {
          id: "reload",
          icon: isLoading ? "xmark" : "arrow.clockwise",
          size: 13,
          enabled: !!url,
          menu: developer,
          longPress: developer,
          tooltip: isLoading ? "Stop Loading This Page" : developer ? `${withShortcut("Refresh", hints.reload)} · Right-Click for Reload Options` : withShortcut("Refresh", hints.reload),
        },
      ],
      url: url
        ? {
            developer: developer ? { text: developerUrl(url), editing, request: editRequest } : null,
            host,
            restTrail,
            hoverTrail: path,
            insecure,
            pinned: popover === "siteControls",
            hoverButtons: [
              { id: "bookmark", icon: bookmarked ? "bookmark.fill" : "bookmark", ...small, tooltip: bookmarked ? "Remove Bookmark" : withShortcut("Bookmark This Page", hints.bookmark) },
              ...(!inSplit && !sidebar ? [{ id: "split", icon: "rectangle.split.2x1", ...small, tooltip: withShortcut("Open Split View", hints.split) }] : []),
              { id: "siteControls", icon: "slider.horizontal.3", ...small, active: popover === "siteControls", tooltip: "Site Controls" },
            ],
            trailing,
          }
        : null,
      right: inSplit
        ? [
            { id: "splitMenu", icon: "rectangle.split.2x1", size: 14, box: 30, tooltip: "Split View" },
            { id: "closePane", icon: "xmark", size: 12, weight: "medium", box: 30, tooltip: "Close Pane" },
          ]
        : [],
      rightInset: 8,
      extensions: JSON.parse(extensionsJson),
      extensionsRight: inSplit ? 8 + 60 : 8,
      update,
      hairline: !!url && !bare,
      progress: isLoading ? progress : null,
      stripes: developer ? stripesUri(palette) : null,
    };
  }, [tab, tabId, bare, focused, palette, theme, geometry, inSplit, !sidebar, extensionsWidth, showFullUrl, bookmarked, insecure, popups, capture, popover, progress, translate, isLoading, history, developer, editing, editRequest, hints.sidebar, hints.back, hints.forward, hints.reload, hints.bookmark, hints.split, extensionsJson, update?.tooltip]);
  const json = useMemo(() => (state ? JSON.stringify(state) : null), [state]);

  const focus = () => {
    if (!focused) useBrowser.getState().activate(tabId);
  };
  const onClick = async (c: ToolbarClick) => {
    if (!tab) return;
    focus();
    const m = { metaKey: c.meta, altKey: c.alt, shiftKey: c.shift };
    switch (c.id) {
      case "sidebar":
        return useBrowser.getState().toggleSidebar(windowId);
      case "back":
      case "forward": {
        const direction = c.id === "back" ? -1 : 1;
        if (c.kind === "menu") {
          const open = useHistoryMenu.getState().menu;
          if (open?.tabId === tabId && open.direction === direction) return closeHistoryMenu();
          return void openHistoryMenu(tabId, direction);
        }
        closeHistoryMenu();
        const mode = openModeFor({ ...m, middle: c.kind === "middle" });
        if (mode === "current" || mode === "split") return direction < 0 ? goBack(tabId) : goForward(tabId);
        const [target] = await historyItems(tabId, direction, 1);
        if (target?.url) openUrl(target.url, windowId, mode);
        return;
      }
      case "reload":
        if (c.kind === "menu") return void showDeveloperReloadMenu(tabId);
        if (isLoading) return void webviews.get(tabId)?.stopLoading();
        if (m.metaKey) return void useBrowser.getState().newTab(tab.windowId, { url: tab.url, background: true, openerId: tab.id });
        if (developer && !m.shiftKey) return developerReload(tabId);
        return void withLivePage(tabId, (page) => (m.shiftKey ? page.forceReload() : page.reload()));
      case "url":
        if (c.kind === "menu") return void showUrlBarMenu(tab);
        if (developer) return editing ? undefined : startUrlEdit(tabId);
        showNativePanelNow(windowId, tab.url);
        return useBrowser.getState().openPanel(windowId, tab.url);
      case "urlEdit":
        if (c.kind === "focus") return claimFocusTag(windowId, urlEditFocus(tabId), focusHandle);
        if (c.kind === "submit") submitUrlEdit(tabId, c.text ?? "");
        else endUrlEdit(tabId);
        if (c.kind !== "blur") void webviews.get(tabId)?.focus();
        return;
      case "lock":
      case "capture":
      case "siteControls":
        return togglePopover(tabId, "siteControls");
      case "bookmark": {
        const s = useBrowser.getState();
        const page = s.tabs[tabId];
        if (page) void toggleBookmarkFromUI(bookmarkProfileId(s, s.windows[windowId]), { url: page.url, title: page.title, favicon: page.favicon });
        return;
      }
      case "split":
        return openSplitPane(windowId, { anchorTabId: tabId });
      case "translate":
        if (c.kind === "menu") return void showTranslateMenu(tabId);
        return toggleTranslation(tabId);
      case "zoom":
        return togglePopover(tabId, "zoom");
      case "popups":
        return togglePopover(tabId, "popups");
      case "dev:console":
      case "dev:network":
      case "dev:elements":
        return void webviews.get(tabId)?.showDevTools(`toggle:${c.id.slice(4)}`);
      case "splitMenu":
        return showSplitMenu(tabId);
      case "closePane":
        return closePane(tabId);
      case "update":
        return installUpdateNow();
      case WEBKIT_PILL_ACTION:
        return void openPageIn(tabId, "chromium");
      default:
        if (c.id.startsWith("ext")) extensions.onClick(c.id, c.kind === "menu" ? "menu" : "press");
    }
  };

  return { tab, state, json, onClick, onAnchors: extensions.onAnchors };
}
