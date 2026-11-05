import { unwrapPageEvent, type OpenWindowRequest } from "@solara/solaracore";
import { toEngineUrl } from "@solara/core";
import { focusPageIfUnclaimed, onHostedEvent, setWindowSidePanel } from "@solara/settings";
import { useEffect, useMemo, useRef } from "react";
import { View } from "react-native";
import { layout, useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { setWindowSidebar, sidePanelWidthOf } from "../../store/sidebarRail";
import { shownPageId } from "../../store/peek";
import { useWindowId } from "../../store/hooks";
import { useFullscreenTab } from "../layout/pageState";
import { openFromPage, pageProfileId } from "../layout/openFromPage";
import { closeSidePanel, findExtension, showExtensionMenu, useExtensions } from "./state";

let refocusing = false;
function refocusActivePageOnPanelLoss() {
  if (refocusing) return;
  refocusing = true;
  onHostedEvent("extensionSidePanel", null, (name, _payload, windowId) => {
    if (name !== "focusLost") return;
    const tabId = shownPageId(useBrowser.getState(), windowId);
    if (tabId) void focusPageIfUnclaimed(windowId, tabId);
  });
}

export function SidePanelRoom() {
  const windowId = useWindowId();
  const open = useExtensions((e) => !!e.sidePanels[windowId]);
  const width = useBrowser((s) => sidePanelWidthOf(s.windows[windowId], s.settings));
  const fullscreen = !!useFullscreenTab(windowId);
  return open && !fullscreen ? <View pointerEvents="none" style={{ width: width + layout.cardInset - 1 }} /> : null;
}

export function ExtensionSidePanel() {
  const windowId = useWindowId();
  const panel = useExtensions((e) => e.sidePanels[windowId]);
  const width = useBrowser((s) => sidePanelWidthOf(s.windows[windowId], s.settings));
  const fullscreen = !!useFullscreenTab(windowId);
  const theme = useTheme();
  const ext = useExtensions((e) => panel ? e.lists[panel.profile]?.find((x) => x.id === panel.extensionId) : undefined);
  const key = panel ? `${panel.extensionId}|${panel.pageProfile}|${panel.url}|${panel.opened}` : null;
  const live = useRef({ key, panel });
  live.current = { key, panel };
  refocusActivePageOnPanelLoss();

  useEffect(
    () => onHostedEvent("extensionSidePanel", windowId, (name, payload) => {
      const { key, panel } = live.current;
      if (!panel || payload.key !== key) return;
      const { profile, extensionId, pageProfile } = panel;
      if (name === "menu") {
        const found = findExtension(profile, extensionId);
        if (found) void showExtensionMenu(windowId, found);
      } else if (name === "close") closeSidePanel(windowId);
      else if (name === "windowClose") closeSidePanel(windowId, extensionId);
      else if (name === "openWindow") {
        const [request] = unwrapPageEvent("onOpenWindow", payload.request as OpenWindowRequest) as [OpenWindowRequest];
        openFromPage(request, { windowId, profileId: pageProfileId(windowId, pageProfile) });
      } else if (name === "resize" && payload.ended) setWindowSidebar(windowId, { sidePanelWidth: Number(payload.width) });
      else if (name === "resetWidth") setWindowSidebar(windowId, { sidePanelWidth: 360 });
    }),
    [windowId],
  );
  const state = useMemo(() => panel && !fullscreen ? {
    key: key!,
    pageProfile: panel.pageProfile,
    url: toEngineUrl(panel.url),
    title: ext?.actionTitle || ext?.name || "Extension",
    icon: ext?.actionIcon || ext?.icon || null,
    width,
    room: width + layout.cardInset - 1,
    look: {
      card: theme.card,
      text: theme.textPrimary,
      icon: theme.icon,
      hover: theme.toolbarHover,
      pressed: theme.toolbarPressed,
      hairline: theme.dark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.08)",
      radius: layout.cardRadius,
    },
  } : null, [panel, fullscreen, key, ext, width, theme]);
  useEffect(() => {
    void setWindowSidePanel(windowId, state);
  }, [windowId, state]);
  useEffect(() => () => { void setWindowSidePanel(windowId, null); }, [windowId]);
  return null;
}
