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
import { openFromPage, pageProfileId } from "../layout/openFromPage";
import { closeSidePanel, findExtension, showExtensionMenu, useExtensions } from "./state";
import type { SidePanel } from "./store";

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

function useSidePanelWidth(windowId: string) {
  return useBrowser((s) => sidePanelWidthOf(s.windows[windowId], s.settings));
}

export function SidePanelRoom({ fullscreen }: { fullscreen: boolean }) {
  const windowId = useWindowId();
  const open = useExtensions((e) => !!e.sidePanels[windowId]);
  return open && !fullscreen ? <SidePanelSpacer windowId={windowId} /> : null;
}

function SidePanelSpacer({ windowId }: { windowId: string }) {
  const width = useSidePanelWidth(windowId);
  return <View pointerEvents="none" style={{ width: width + layout.cardInset - 1 }} />;
}

export function ExtensionSidePanel({ fullscreen }: { fullscreen: boolean }) {
  const windowId = useWindowId();
  const panel = useExtensions((e) => e.sidePanels[windowId]);
  refocusActivePageOnPanelLoss();
  useEffect(() => {
    if (!panel) void setWindowSidePanel(windowId, null);
  }, [windowId, !!panel]);
  useEffect(() => () => { void setWindowSidePanel(windowId, null); }, [windowId]);
  return panel ? <OpenSidePanel windowId={windowId} panel={panel} fullscreen={fullscreen} /> : null;
}

function OpenSidePanel({ windowId, panel, fullscreen }: { windowId: string; panel: SidePanel; fullscreen: boolean }) {
  const width = useSidePanelWidth(windowId);
  const theme = useTheme();
  const ext = useExtensions((e) => e.lists[panel.profile]?.find((x) => x.id === panel.extensionId));
  const key = `${panel.extensionId}|${panel.pageProfile}|${panel.url}|${panel.opened}`;
  const live = useRef({ key, panel });
  live.current = { key, panel };

  useEffect(
    () => onHostedEvent("extensionSidePanel", windowId, (name, payload) => {
      const { key, panel } = live.current;
      if (payload.key !== key) return;
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
  const state = useMemo(() => fullscreen ? null : {
    key,
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
  }, [panel, fullscreen, key, ext, width, theme]);
  useEffect(() => {
    void setWindowSidePanel(windowId, state);
  }, [windowId, state]);
  return null;
}
