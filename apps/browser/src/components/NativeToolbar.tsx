import { NativeToolbarView, type ToolbarClick } from "@solara/settings";
import { translation, WindowDragRegion } from "@solara/shell";
import { useEffect, useRef } from "react";
import { useShallow } from "zustand/react/shallow";
import { findNodeHandle, Image, StyleSheet, View } from "react-native";
import { useShortcutHint } from "../lib/commandShortcuts";
import { runCommand } from "../lib/commands";
import { withLivePage } from "../lib/livePage";
import { layout, useTheme } from "../lib/theme";
import { webviews } from "../lib/webviews";
import { useBrowser } from "../store/browser";
import { bookmarkProfileId } from "../store/model";
import { isBookmarked } from "../store/bookmarks";
import { nativeOwnsWorkspace } from "../store/nativeStore";
import { splitOf } from "../store/splits";
import { toggleBookmarkFromUI } from "../lib/bookmarkWriter";
import { usePageProgress } from "../store/pageProgress";
import { openModeFor, openUrl } from "./bookmarks/actions";
import { showNativePanelNow } from "./CommandPanel";
import { useNativeToolbarExtensions } from "./extensions/ToolbarExtensionHost";
import { openPageIn } from "../lib/engines";
import { type ToolbarGeometry } from "./layout/geometry";
import { closeHistoryMenu, goBack, goForward, historyItems, openHistoryMenu, useHistoryMenu } from "./layout/history";
import { setPopover, usePage, usePages } from "./layout/pageState";
import { closePane, openSplitPane, showSplitMenu } from "./layout/splitActions";
import { toolbarPalette } from "./layout/toolbarColors";
import { setToolbarExtensionsWidth } from "./layout/windowLayout";
import { showUrlBarMenu } from "./omnibox/paste";
import { runOmniboxFallback } from "./omnibox/nativeActions";
import { endUrlEdit, startUrlEdit, submitUrlEdit, tabInDeveloperMode, useUrlEdit } from "./site/developerMode";
import { developerReload, showDeveloperReloadMenu } from "./site/DeveloperButtons";
import { claimFocusTag, urlEditFocus } from "../lib/focusClaims";
import { showTranslateMenu } from "./site/TranslateControls";
import { languageName, toggleTranslation, useTranslateState } from "./site/translate";
import { insecureLevel } from "./Toolbar";
import { installUpdateNow, UPDATE_PILL_SHORT_TEXT, UPDATE_PILL_TEXT, updatePillTooltip, usePendingUpdate } from "../lib/pendingUpdate";


const WEBKIT_PILL_ACTION = "webkit:openInChromium";

const LIGHT_STRIPES = require("../../assets/developer-stripes-light.png");
const DARK_STRIPES = require("../../assets/developer-stripes-dark.png");
export const stripesUri = (palette: { text: string }) => {
  const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})/i.exec(palette.text);
  const onDark = !m || 0.2126 * parseInt(m[1]!, 16) + 0.7152 * parseInt(m[2]!, 16) + 0.0722 * parseInt(m[3]!, 16) > 128;
  return Image.resolveAssetSource(onDark ? LIGHT_STRIPES : DARK_STRIPES)?.uri ?? null;
};
const togglePopover = (tabId: string, name: "siteControls" | "zoom" | "popups") =>
  setPopover(tabId, (usePages.getState().popover[tabId] ?? null) === name ? null : name);

type NativeToolbarProps = {
  tabId: string;
  geometry: ToolbarGeometry;
  windowId: string;
  inSplit: boolean;
  focused: boolean;
  bare?: boolean;
  windowToolbar?: boolean;
  sidebar?: { extensionLimit: number; look: { resting: string; stroke: string; hover: string; placeholder: string; prompt: string } };
};

export function NativeToolbar(props: NativeToolbarProps) {
  const view = useRef<View>(null);
  const { json, onClick, onAnchors } = useNativeToolbarModel(props, () => findNodeHandle(view.current));

  return (
    <View style={{ height: layout.toolbarHeight }}>
      <WindowDragRegion style={StyleSheet.absoluteFill} />
      <View ref={view} collapsable={false} style={StyleSheet.absoluteFill} pointerEvents="box-none">
        <NativeToolbarView
          style={StyleSheet.absoluteFill}
          input={json}
          onToolbarClick={(e) => void onClick(e.nativeEvent)}
          onToolbarAnchors={(e) => onAnchors(e.nativeEvent.anchors)}
        />
      </View>
    </View>
  );
}

export function useNativeToolbarModel({ tabId, geometry, windowId, focused, bare, windowToolbar, sidebar }: NativeToolbarProps, focusHandle: () => number | null) {
  const theme = useTheme();
  const fullscreenTabs = usePages(useShallow((s) => Object.keys(s.pages).filter((id) => s.pages[id]?.fullscreen)));
  const fallback = useBrowser(useShallow((s) => {
    if (nativeOwnsWorkspace()) return undefined;
    const tab = s.tabs[tabId];
    const window = s.windows[windowId];
    const holder = tab?.pageIn ?? tabId;
    return {
      window, tab, opener: tab?.openerId ? s.tabs[tab.openerId] : undefined, split: splitOf(s, tabId),
      live: s.live[tabId], holderLive: s.live[holder], settings: s.settings,
      bookmarked: !!tab && isBookmarked(s.bookmarks, bookmarkProfileId(s, window), tab.url),
    };
  }));
  const extensions = useNativeToolbarExtensions(windowId, tabId);
  const pending = usePendingUpdate();
  const insecure = usePage(tabId, insecureLevel);
  const editing = useUrlEdit((u) => u.tabId === tabId);
  const editRequest = useUrlEdit((u) => u.tabId === tabId ? u.request : 0);
  useEffect(() => () => endUrlEdit(tabId), [tabId]);
  const popups = usePage(tabId, (p) => p.popups.length);
  const capture = usePage(tabId, (p) => p.mediaAccess);
  const newTabShown = usePage(tabId, (p) => !!p.newTabShown);
  const backToNewTab = usePage(tabId, (p) => p.backToNewTab);
  const historyKnown = usePage(tabId, (p) => p.historyKnown);
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
  const translated = translate.status !== "idle";
  const json = JSON.stringify({
    windowId, tabId, geometry, bare: !!bare, windowToolbar: !!windowToolbar, fullscreenTabs, fallback,
    palette: toolbarPalette(theme, null), accent: theme.accent, dark: !!theme.dark,
    lightStripes: Image.resolveAssetSource(LIGHT_STRIPES)?.uri ?? null,
    darkStripes: Image.resolveAssetSource(DARK_STRIPES)?.uri ?? null,
    sidebar: sidebar?.look, extensionLimit: sidebar?.extensionLimit,
    hints, insecure, editing, editRequest, popups, capture, popover, progress,
    newTabShown, backToNewTab, historyKnown,
    translation: translation && (translate.source || translated) ? { translated, language: languageName(translate.source ?? "") } : null,
    update: pending ? { text: UPDATE_PILL_TEXT, short: UPDATE_PILL_SHORT_TEXT, tooltip: updatePillTooltip(pending) } : null,
  });

  const onClick = async (c: ToolbarClick) => {
    const state = useBrowser.getState();
    const tab = state.tabs[tabId];
    if ((c.tabId !== undefined && c.tabId !== tabId) || !tab || tab.windowId !== windowId || tab.profileId !== state.windows[windowId]?.profileId) return;
    const focus = () => {
      if (!focused) state.activate(tabId);
    };
    focus();
    const m = { metaKey: c.meta, altKey: c.alt, shiftKey: c.shift };
    const developer = tabInDeveloperMode(tabId);
    switch (c.id) {
      case "sidebar":
        return runCommand({ command: "toggleSidebar", arg: null, windowId });
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
        const current = useBrowser.getState().tabs[tabId];
        if (target?.url && current?.windowId === windowId && current.profileId === tab.profileId && current.navigation?.seq === tab.navigation?.seq)
          openUrl(target.url, windowId, mode);
        return;
      }
      case "reload":
        if (c.kind === "menu") return void showDeveloperReloadMenu(tabId);
        if (state.live[tabId]?.isLoading) return void webviews.get(tabId)?.stopLoading();
        if (m.metaKey) return void useBrowser.getState().newTab(tab.windowId, { url: tab.url, background: true, openerId: tab.id });
        if (developer && !m.shiftKey) return developerReload(tabId);
        return void withLivePage(tabId, (page) => (m.shiftKey ? page.forceReload() : page.reload()));
      case "url":
        if (c.kind === "menu") return void showUrlBarMenu(tab);
        if (developer) return useUrlEdit.getState().tabId === tabId ? undefined : startUrlEdit(tabId);
        showNativePanelNow(windowId, tab.url);
        return useBrowser.getState().openPanel(windowId, tab.url);
      case "urlEdit":
        if (c.kind === "focus") return claimFocusTag(windowId, urlEditFocus(tabId), focusHandle);
        if (c.kind === "submit") runOmniboxFallback("developerSubmit", c, () => submitUrlEdit(tabId, c.text ?? ""));
        else endUrlEdit(tabId);
        if (c.kind !== "blur") void webviews.get(tabId)?.focus();
        return;
      case "lock":
      case "capture":
      case "siteControls":
        return togglePopover(tabId, "siteControls");
      case "bookmark":
        return void toggleBookmarkFromUI(bookmarkProfileId(state, state.windows[windowId]), { url: tab.url, title: tab.title, favicon: tab.favicon });
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

  const onAnchors = ({ toolbarExtensionsWidth, ...anchors }: Record<string, [number, number, number, number]>) => {
    if (toolbarExtensionsWidth && !sidebar && focused) setToolbarExtensionsWidth(windowId, toolbarExtensionsWidth[2]);
    extensions.onAnchors(anchors);
  };

  return { json, onClick, onAnchors };
}
