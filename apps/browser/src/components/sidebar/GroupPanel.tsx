import { onHostedEvent, SolaraHostedView } from "@solara/settings";
import { useEffect, useMemo, useRef } from "react";
import { Image, StyleSheet } from "react-native";
import { useShallow } from "zustand/react/shallow";
import { useLifecycle } from "../../lib/tabLifecycle";
import { useTheme } from "../../lib/theme";
import { webviews } from "../../lib/webviews";
import { useBrowser } from "../../store/browser";
import { engineMark, ENGINE_SYMBOLS } from "../../store/engines";
import { activeTabId } from "../../store/model";
import { nativeOwnsWorkspace } from "../../store/nativeStore";
import { isPageUnloaded } from "../../store/pinShare";
import { sharedTabsIn, sharesTabs } from "../../store/tabShare";
import type { Tab } from "../../store/types";
import { PANEL } from "../layout/controls";
import { focusHeroBar } from "../omnibox/barState";
import { clickTab, tabTitle } from "./actions";
import { byRecentUse, groupTabIds, type GroupPanelTab } from "./groupPanelRows";
import { cardHoverProps, dismissHover, holdHover } from "./hover";
import { hoverCardOrigin } from "./hoverMotion";
import { useSidebarUi, type Anchor } from "./state";

const WIDTH = 264;
const ROW = 44;
const LIST_PAD = PANEL.inset - (ROW - PANEL.iconSlot) / 2;
const NEW_TAB_MARK: number = require("../../../assets/solara/new-tab-mark.png");
let nextPresentation = 0;

type Row = GroupPanelTab & { favicon: string | null; icon: string | null; profileId: string };

export function returnFocusToPage(windowId: string) {
  const s = useBrowser.getState();
  const active = activeTabId(s, windowId);
  if (!active) return;
  if (s.tabs[active]?.url) void webviews.get(active)?.focus();
  else focusHeroBar(windowId, active);
}

export function useGroupRows(groupId: string, windowId: string): Row[] {
  const ids = useBrowser(useShallow((s) => groupTabIds(s.groups, groupId)));
  const tabs = useBrowser(useShallow((s) => ids.map((id) => s.tabs[id])));
  return useMemo(() => {
    const s = useBrowser.getState();
    const shared = sharesTabs(s) ? sharedTabsIn(s.tabs, windowId) : null;
    const rows = tabs
      .filter((t): t is Tab => !!t)
      .map((t) => ({ id: t.id, title: tabTitle(t), url: t.url, usedAt: shared?.lastUsed(t) ?? t.lastActiveAt, favicon: t.favicon, icon: t.customIcon, profileId: t.profileId }));
    return byRecentUse(rows);
  }, [tabs, windowId]);
}

export function GroupPanel({ groupId, windowId, anchor, windowHeight }: { groupId: string; windowId: string; anchor: Anchor; windowHeight: number }) {
  const theme = useTheme();
  const exists = useBrowser((s) => !!s.groups[groupId]);
  const all = useGroupRows(groupId, windowId);
  const live = useSidebarUi((u) => u.hover?.kind === "group" && u.hover.id === groupId && u.hover.windowId === windowId);
  const presentation = useRef<string | null>(null);
  presentation.current ??= String(++nextPresentation);
  const token = presentation.current;
  const native = nativeOwnsWorkspace();
  const fallbackSleep = useLifecycle(useShallow((s) => all.map((row) => !!s.discarded[row.id])));
  const icons = useBrowser(useShallow((s) => all.map((row, index) => {
    const mark = engineMark(s, row.id);
    return JSON.stringify({ dimmed: (native ? !!s.live[row.id]?.discarded : fallbackSleep[index]) || (s.settings.fadeUnloadedTabs && isPageUnloaded(s, row.id)), engineSymbol: mark ? ENGINE_SYMBOLS[mark] : null });
  })));
  const panelHeight = 44 + StyleSheet.hairlineWidth + PANEL.separatorGap * 2 + LIST_PAD * 2 + Math.max(1, Math.min(7, all.length)) * ROW;
  const at = hoverCardOrigin(anchor);
  const top = Math.max(8, Math.min(at.top, windowHeight - panelHeight - 8));

  useEffect(() => onHostedEvent("groupPanel", windowId, (name, payload) => {
    if (payload.groupId !== groupId || payload.token !== token) return;
    if (name === "release") return holdHover(false);
    const hover = useSidebarUi.getState().hover;
    if (name === "focusPage") {
      if (!hover || (hover.kind === "group" && hover.id === groupId && hover.windowId === windowId)) return returnFocusToPage(windowId);
      return;
    }
    if (hover?.kind !== "group" || hover.id !== groupId || hover.windowId !== windowId) return;
    if (name === "enter") return cardHoverProps.onMouseEnter();
    if (name === "leave") return cardHoverProps.onMouseLeave();
    if (name === "hold") return holdHover(true);
    if (name === "close") return dismissHover();
    if (name === "choose" && typeof payload.tabId === "string") {
      const s = useBrowser.getState();
      if (!s.tabs[payload.tabId] || !groupTabIds(s.groups, groupId).includes(payload.tabId)) return;
      dismissHover();
      clickTab(windowId, payload.tabId);
    }
  }), [groupId, windowId, token]);

  if (!exists) return null;
  return <SolaraHostedView
    kind="groupPanel"
    windowId={windowId}
    state={JSON.stringify({
      token,
      live,
      newTabMark: Image.resolveAssetSource(NEW_TAB_MARK)?.uri ?? null,
      card: {
        groupId,
        rows: all.map((row, index) => ({ ...row, usedAt: row.usedAt ?? 0, ...JSON.parse(icons[index] ?? "{}") })),
        anchor: [anchor.x, anchor.y, anchor.width, anchor.height],
        windowHeight,
        dark: theme.dark,
        theme: { textPrimary: theme.textPrimary, textSecondary: theme.textSecondary, textTertiary: theme.textTertiary, placeholder: theme.placeholder, selection: theme.selection },
      },
    })}
    onLayout={cardHoverProps.onLayout}
    style={{ position: "absolute", left: at.left, top, width: WIDTH, height: panelHeight }}
  />;
}
