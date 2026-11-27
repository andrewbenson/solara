import { hostedSidebarShell, nativeOmniboxAvailable, publishSettingsTopic, sidebarAddressBarAvailable, SolaraHostedView } from "@solara/settings";
import { memo, useEffect, useMemo, useState } from "react";
import { StyleSheet } from "react-native";
import { useBrowser } from "../../store/browser";
import { sidebarWidthOf } from "../../store/sidebarRail";
import { openNewTabInSplit } from "../layout/splitActions";
import { toggleNewTabBar } from "../omnibox/newTabBar";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { openSettings } from "../settings/windows";
import { dismissHover, nativeRowHover } from "./hover";
import { openOverflowMenu, openSidebarMenu, openTabMenu, runGroupMenuChoice, runTabMenuChoice, runTabMenuSelectionChoice, showClearedToast, showUndoToast } from "./menus";
import { applyNativeRenameState, resetNativeRenames } from "./renameMirror";
import { setSidebarUi, sidebarUi, useSidebarUi } from "./state";
import { publishNativeLive, runNativeLive } from "./nativeLive";
import { showTidiedPinsToast } from "./tidyPinsUi";
import { openProfileMenu } from "../ProfileIndicator";
import { registerDownloadsAnchor } from "../Downloads";
import { useTabDrag } from "../layout/tabDrag";
import { followPeekHold } from "../layout/peekHold";
import { nativeLayoutFeed, useNativeLayoutFeed } from "../layout/nativeLayoutFeed";
import { SidebarAddressBarState } from "./AddressBar";
import { installNativeDragProbe } from "./nativeDrag";

const SHELL_TOPIC = "sidebar.shell";
const shellColumns: Record<string, object> = {};
const nativeFeed = nativeLayoutFeed<{ state: string; dropOver: boolean; held: boolean }>("sidebar.nativeFeed");

export { nativeSidebarShell } from "./sidebarShell";

export function shellColumnFitsAddressBar(addressBar: boolean): boolean {
  return !addressBar || (nativeOmniboxAvailable() && sidebarAddressBarAvailable());
}

function publishShellColumn(windowId: string, column: object | null) {
  if (column) shellColumns[windowId] = column;
  else if (shellColumns[windowId]) delete shellColumns[windowId];
  else return;
  publishSettingsTopic(SHELL_TOPIC, { windows: shellColumns });
}

type ShellEvent = { width?: number | null };

addNativeSettingsHandlers({
  [SHELL_TOPIC]: (windowId: string, event: string, extra: ShellEvent) => {
    switch (event) {
      case "profileMenu":
        return void openProfileMenu(windowId);
      case "manageProfiles":
        return void openSettings("profiles");
      case "liveWidth": {
        const { [windowId]: _, ...rest } = sidebarUi().dragWidth;
        return setSidebarUi({ dragWidth: typeof extra.width === "number" ? { ...rest, [windowId]: extra.width } : rest });
      }
    }
  },
});

function useNativeDownloadsAnchor(windowId: string) {
  useEffect(
    () => registerDownloadsAnchor(windowId, async () => {
      const rect = (JSON.parse(await hostedSidebarShell(windowId)) as { downloads?: number[] } | null)?.downloads;
      return rect ? { x: rect[0]!, y: rect[1]!, width: rect[2]!, height: rect[3]! } : null;
    }),
    [windowId],
  );
}

function ShellColumnState({ windowId, state, dropOver, addressWidth }: { windowId: string; state: string; dropOver: boolean; addressWidth: number | null }) {
  useEffect(() => publishShellColumn(windowId, { state, dropOver }), [windowId, state, dropOver]);
  useEffect(() => () => publishShellColumn(windowId, null), [windowId]);
  useNativeDownloadsAnchor(windowId);
  return addressWidth === null ? null : <SidebarAddressBarState width={addressWidth} />;
}

function NativeSidebarFeed({ windowId, state, dropOver, addressBar }: { windowId: string; state: string; dropOver: boolean; addressBar: boolean }) {
  const floating = useBrowser((s) => s.windows[windowId]?.sidebarOpen === false);
  const width = useBrowser((s) => sidebarWidthOf(s.windows[windowId], s.settings, true));
  const [held, setHeld] = useState(false);
  useEffect(() => followPeekHold(windowId, floating, setHeld, true), [windowId, floating]);
  const value = useMemo(() => ({ state, dropOver, held }), [state, dropOver, held]);
  useNativeLayoutFeed(nativeFeed, windowId, value);
  useNativeDownloadsAnchor(windowId);
  return addressBar ? <SidebarAddressBarState width={width} /> : null;
}


addNativeSettingsHandlers({
  "sidebar.action": (
    windowId: string,
    name: string,
    id: string,
    extra: { meta?: boolean; kind?: "tab" | "group" | "folder" | "live"; split?: boolean; action?: string; item?: string | null; cleared?: string; result?: string; seq?: number; windows?: Record<string, number>; ids?: string[]; choice?: string },
  ) => {
    const s = useBrowser.getState();
    if (name === "hover") return nativeRowHover(windowId, extra.kind && id ? { kind: extra.kind, id } : null);
    if (name === "renameState") return void applyNativeRenameState(windowId, extra.kind ?? null, id, Number(extra.seq ?? 0));
    if (name === "renameReset") return resetNativeRenames(extra.windows ?? {});
    dismissHover();
    switch (name) {
      case "handled":
        return;
      case "clicked":
        if (s.selectionAnchors[windowId] !== id) s.setSelectionAnchor(windowId, id);
        if (s.selection[windowId]?.length) s.setSelection(windowId, []);
        return;
      case "removedPin":
        return extra.cleared ? showUndoToast(JSON.parse(extra.cleared), "Removed Pinned Tab", "pin.slash") : undefined;
      case "tabMenuSelectionChoice":
        return runTabMenuSelectionChoice(windowId, extra.ids ?? [], extra.choice ?? "");
      case "tabMenu": {
        const tab = s.tabs[id];
        return tab ? void openTabMenu(windowId, tab) : undefined;
      }
      case "tabMenuChoice":
        return runTabMenuChoice(windowId, id, extra.choice ?? "");
      case "groupMenuChoice":
        return runGroupMenuChoice(windowId, id, extra.choice ?? "");
      case "sidebarMenu":
        return void openSidebarMenu(windowId);
      case "overflowMenu":
        return void openOverflowMenu(windowId);
      case "newTab":
        if (extra.split) return openNewTabInSplit(windowId);
        return void (toggleNewTabBar(windowId) || s.newTab(windowId, { newTabCommand: true }));
      case "tidied":
        return extra.result ? showTidiedPinsToast(windowId, JSON.parse(extra.result)) : undefined;
      case "cleared":
        return extra.cleared ? showClearedToast(JSON.parse(extra.cleared)) : undefined;
      case "live":
        return runNativeLive(windowId, id, extra.action ?? "", extra.item ?? null, !!extra.meta);
    }
  },
});

export const NativeSidebar = memo(function NativeSidebar({ windowId, addressBar, width, headless = false }: { windowId: string; addressBar: boolean; width?: number; headless?: boolean }) {
  useEffect(publishNativeLive, []);
  useEffect(() => installNativeDragProbe(windowId), [windowId]);
  const dropOver = useTabDrag((d) => d.overWindow === windowId);
  const renaming = useSidebarUi((u) => (u.renaming?.windowId === windowId && (u.renaming.kind === "tab" || u.renaming.kind === "group") ? `${u.renaming.kind}:${u.renaming.id}` : null));
  const state = useMemo(() => JSON.stringify({ addressBar, renaming }), [addressBar, renaming]);
  if (headless) return <NativeSidebarFeed windowId={windowId} state={state} dropOver={dropOver} addressBar={addressBar} />;
  if (width !== undefined) return <ShellColumnState windowId={windowId} state={state} dropOver={dropOver} addressWidth={addressBar && width ? width : null} />;
  return <SolaraHostedView kind="sidebar" windowId={windowId} state={state} style={StyleSheet.absoluteFill} />;
});
