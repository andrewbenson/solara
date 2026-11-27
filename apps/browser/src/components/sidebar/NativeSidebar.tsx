import { hostedSidebarShell, nativeOmniboxAvailable, publishSettingsTopic, sidebarAddressBarAvailable, SolaraHostedView } from "@solara/settings";
import { memo, useEffect, useMemo, useState } from "react";
import { StyleSheet } from "react-native";
import { useBrowser } from "../../store/browser";
import { useSync } from "../../sync/engine";
import { sidebarWidthOf } from "../../store/sidebarRail";
import { openNewTabInSplit } from "../layout/splitActions";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { applyHoverProbe } from "./hover";
import { applyNativeRenameState, resetNativeRenames } from "./renameMirror";
import { setSidebarUi, sidebarUi } from "./state";
import { showTidiedPinsToast } from "./tidyPinsUi";
import { requestCreateProfile } from "../profiles/CreateProfile";
import { registerDownloadsAnchor } from "../Downloads";
import { useTabDrag } from "../layout/tabDrag";
import { followPeekHold } from "../layout/peekHold";
import { nativeLayoutFeed, useNativeLayoutFeed } from "../layout/nativeLayoutFeed";
import { SidebarAddressBarState } from "./AddressBar";
import { installNativeDragProbe } from "./nativeDrag";

if (__DEV__) addNativeSettingsHandlers({ "sidebar.hoverProbe": applyHoverProbe });

let publishedDevices = false;

function publishSyncedDevices() {
  if (publishedDevices) return;
  publishedDevices = true;
  const publish = (devices: ReturnType<typeof useSync.getState>["remoteTabs"]) => publishSettingsTopic("sidebar.syncedDevices", devices);
  publish(useSync.getState().remoteTabs);
  useSync.subscribe((next, previous) => {
    if (next.remoteTabs !== previous.remoteTabs) publish(next.remoteTabs);
  });
}

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
  "sidebar.profileForm": (windowId: string) => requestCreateProfile(windowId),
  [SHELL_TOPIC]: (windowId: string, event: string, extra: ShellEvent) => {
    switch (event) {
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
    extra: { kind?: "tab" | "group"; split?: boolean; result?: string; seq?: number; windows?: Record<string, number> },
  ) => {
    if (__DEV__ && name === "renameState") return void applyNativeRenameState(windowId, extra.kind ?? null, id, Number(extra.seq ?? 0));
    if (__DEV__ && name === "renameReset") return resetNativeRenames(extra.windows ?? {});
    switch (name) {
      case "handled":
        return;
      case "newTab":
        if (extra.split) return openNewTabInSplit(windowId);
        return;
      case "tidied":
        return extra.result ? showTidiedPinsToast(windowId, JSON.parse(extra.result)) : undefined;
    }
  },
});

export const NativeSidebar = memo(function NativeSidebar({ windowId, addressBar, width, headless = false }: { windowId: string; addressBar: boolean; width?: number; headless?: boolean }) {
  useEffect(publishSyncedDevices, []);
  useEffect(() => installNativeDragProbe(windowId), [windowId]);
  const dropOver = useTabDrag((d) => d.overWindow === windowId);
  const state = useMemo(() => JSON.stringify({ addressBar }), [addressBar]);
  if (headless) return <NativeSidebarFeed windowId={windowId} state={state} dropOver={dropOver} addressBar={addressBar} />;
  if (width !== undefined) return <ShellColumnState windowId={windowId} state={state} dropOver={dropOver} addressWidth={addressBar && width ? width : null} />;
  return <SolaraHostedView kind="sidebar" windowId={windowId} state={state} style={StyleSheet.absoluteFill} />;
});
