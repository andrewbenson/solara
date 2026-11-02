import { requireOptionalNativeModule, type EventSubscription } from "expo-modules-core";
import { useEffect } from "react";
import { useShallow } from "zustand/react/shallow";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { activeTabId } from "../../store/model";
import { folderIn, folderLabel, folderMembers } from "../../store/tileFolders";
import { clickTab, tabTitle } from "./actions";
import { openTabMenu } from "./menus";
import { closeFolderPanel, openTileFolderMenu, useFolderPanel } from "./tileFolderUi";

type FolderPanelNative = {
  show(windowId: string, json: string): Promise<void>;
  hide(windowId: string): Promise<void>;
  addListener(event: "onFolderPanelEvent", listener: (e: { windowId: string; folderId: string; kind: string; tabId?: string }) => void): EventSubscription;
};

const nativePanel = requireOptionalNativeModule<FolderPanelNative>("SolaraFolderPanel");

export function FolderPanel({ windowId }: { windowId: string }) {
  const open = useFolderPanel((u) => (u.open?.windowId === windowId ? u.open : null));
  return <NativeFolderPanel windowId={windowId} folderId={open?.folderId ?? null} />;
}

function NativeFolderPanel({ windowId, folderId }: { windowId: string; folderId: string | null }) {
  const theme = useTheme();
  const members = useBrowser(useShallow((s) => (folderId ? folderMembers(s, windowId, folderId) : [])));
  const label = useBrowser((s) => (folderId ? folderLabel(folderIn(s, windowId, folderId)) : ""));
  const rows = useBrowser(
    useShallow((s) => {
      const active = activeTabId(s, windowId);
      return members.map((id) => {
        const tab = s.tabs[id];
        return tab ? `${id}\u0001${tabTitle(tab)}\u0001${id === active ? 1 : 0}` : "";
      });
    }),
  );
  useEffect(() => {
    if (folderId && !members.length) closeFolderPanel();
  }, [folderId, members.length]);
  useEffect(
    () =>
      useBrowser.subscribe((s, prev) => {
        if (!folderId || s.windows === prev.windows) return;
        const w = s.windows[windowId];
        if (!w || w.profileId !== prev.windows[windowId]?.profileId || activeTabId(s, windowId) !== activeTabId(prev, windowId)) closeFolderPanel();
      }),
    [windowId, folderId],
  );
  useEffect(() => {
    const sub = nativePanel?.addListener("onFolderPanelEvent", (e) => {
      if (e.windowId !== windowId || e.folderId !== folderId) return;
      const tab = e.tabId ? useBrowser.getState().tabs[e.tabId] : undefined;
      if (e.kind === "open" && e.tabId) {
        closeFolderPanel();
        clickTab(windowId, e.tabId);
      } else if (e.kind === "tabMenu" && tab) void openTabMenu(windowId, tab);
      else if (e.kind === "folderMenu" && folderId) void openTileFolderMenu(windowId, folderId);
      else if (e.kind === "outsidePress") closeFolderPanel();
    });
    return () => sub?.remove();
  }, [windowId, folderId]);
  const tokens = { panel: theme.panel, panelBorder: theme.panelBorder, textPrimary: theme.textPrimary, textSecondary: theme.textSecondary, textTab: theme.textTab, tabHover: theme.tabHover, tabPressed: theme.tabPressed, pinnedSelectedFill: theme.pinnedSelectedFill };
  const json = folderId
    ? JSON.stringify({
        folderId,
        label,
        members: rows.filter(Boolean).map((r) => {
          const [tabId, title, active] = r.split("\u0001");
          return { tabId, title, active: active === "1" };
        }),
        dark: !!theme.dark,
        theme: tokens,
        panelShadowOpacity: theme.panelShadowOpacity,
      })
    : null;
  useEffect(() => {
    if (json) void nativePanel?.show(windowId, json);
    else void nativePanel?.hide(windowId);
  }, [json, windowId]);
  useEffect(() => () => void nativePanel?.hide(windowId), [windowId]);
  return null;
}
