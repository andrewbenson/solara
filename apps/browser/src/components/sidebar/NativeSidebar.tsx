import { nativeOmniboxAvailable, publishSettingsTopic, sidebarAddressBarAvailable, SolaraHostedView } from "@solara/settings";
import { memo, useEffect, useMemo } from "react";
import { StyleSheet } from "react-native";
import { useNativeWindowPreferences } from "../layout/windowLayout";
import { useSync } from "../../sync/engine";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import { applyHoverProbe } from "./hover";
import { applyNativeRenameState, resetNativeRenames } from "./renameMirror";
import { setSidebarUi, sidebarUi } from "./state";
import { requestCreateProfile } from "../profiles/CreateProfile";
import { useTabDrag } from "../layout/tabDrag";
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
const nativeFeed = nativeLayoutFeed<{ state: string; dropOver: boolean }>("sidebar.nativeFeed");

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

function ShellColumnState({ windowId, state, dropOver, addressWidth }: { windowId: string; state: string; dropOver: boolean; addressWidth: number | null }) {
  useEffect(() => publishShellColumn(windowId, { state, dropOver }), [windowId, state, dropOver]);
  useEffect(() => () => publishShellColumn(windowId, null), [windowId]);
  return addressWidth === null ? null : <SidebarAddressBarState width={addressWidth} />;
}

function NativeSidebarFeed({ windowId, state, dropOver, addressBar }: { windowId: string; state: string; dropOver: boolean; addressBar: boolean }) {
  const width = useNativeWindowPreferences(windowId, (value) => value?.sidebarWidth ?? 0);
  const value = useMemo(() => ({ state, dropOver }), [state, dropOver]);
  useNativeLayoutFeed(nativeFeed, windowId, value);
  return addressBar ? <SidebarAddressBarState width={width} /> : null;
}


addNativeSettingsHandlers({
  "sidebar.action": (
    windowId: string,
    name: string,
    id: string,
    extra: { kind?: "tab" | "group"; seq?: number; windows?: Record<string, number> },
  ) => {
    if (__DEV__ && name === "renameState") return void applyNativeRenameState(windowId, extra.kind ?? null, id, Number(extra.seq ?? 0));
    if (__DEV__ && name === "renameReset") return resetNativeRenames(extra.windows ?? {});
    switch (name) {
      case "handled":
        return;
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
