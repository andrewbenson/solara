import {
  cancelDeviceChooser,
  onDeviceChooser,
  openBluetoothSettings,
  refreshDeviceChooser,
  selectDevice,
  type DeviceChooser as Chooser,
} from "@solara/solaracore";
import { useEffect, useState } from "react";
import { StyleSheet, View } from "react-native";
import { NativeDeviceChooserView, type NativeDeviceChooserEvent } from "@solara/settings";
import { create } from "zustand";
import { useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { PromptPopover, usePromptPlacement } from "./NativePromptBody";
import { usePromptInputGuard } from "./promptGuard";
import { tabForBrowser } from "../layout/pageState";
import { PRODUCT } from "../../lib/productName";

const useChoosers = create<{ byTab: Record<string, Chooser> }>()(() => ({ byTab: {} }));
if (__DEV__) (globalThis as { acDeviceChoosers?: unknown }).acDeviceChoosers = { useChoosers, selectDevice, cancelDeviceChooser };

let started = false;
export function startDeviceChoosers() {
  if (started) return;
  started = true;
  onDeviceChooser((chooser) => {
    const tabId = tabForBrowser(chooser.browserId);
    if (!tabId) {
      if (chooser.open) void cancelDeviceChooser(chooser.id);
      return;
    }
    useChoosers.setState((s) => {
      const byTab = { ...s.byTab };
      if (chooser.open) byTab[tabId] = chooser;
      else if (byTab[tabId]?.id === chooser.id) delete byTab[tabId];
      return { byTab };
    });
  });
  useBrowser.subscribe((s, prev) => {
    if (s.tabs === prev.tabs) return;
    const { byTab } = useChoosers.getState();
    const gone = Object.keys(byTab).filter((id) => !s.tabs[id]);
    if (!gone.length) return;
    const next = { ...byTab };
    for (const id of gone) delete next[id];
    useChoosers.setState({ byTab: next });
  });
}

export function DeviceChooser({ tabId, left, top }: { tabId: string; left: number; top: number }) {
  const theme = useTheme();
  const chooser = useChoosers((s) => s.byTab[tabId]);
  const [selected, setSelected] = useState<number | null>(null);
  useEffect(() => setSelected(null), [chooser?.id]);
  const guard = usePromptInputGuard(chooser?.id);
  if (!chooser) return null;
  const scanning = chooser.bothButtonsEnabled;
  const selectedIndex = chooser.options.findIndex((option, index) => (option.optionId ?? index) === selected);
  const valid = scanning || selectedIndex >= 0;
  const choose = guard((index: number | null = selected) => {
    if (scanning) return void selectDevice(chooser.id, -1);
    if (index !== null) void selectDevice(chooser.id, index);
  });
  const cancel = () => void cancelDeviceChooser(chooser.id);

  return (
    <PromptPopover key={chooser.id} width={340} top={top} left={left} modal={false}>
      <NativeChooserBody
        state={JSON.stringify({
          id: chooser.id,
          title: chooser.title,
          icon: chooser.showSignal || scanning ? "dot.radiowaves.left.and.right" : "cable.connector",
          options: chooser.options.map((o, index) => ({ optionId: o.optionId ?? index, name: o.name, detail: o.connected ? "Connected" : o.paired ? "Paired" : null, signal: chooser.showSignal ? o.signal : -1 })),
          selected,
          scanning,
          refreshing: chooser.refreshing,
          canRefresh: chooser.canRefresh,
          scanningText: chooser.scanningText,
          noOptionsText: chooser.noOptionsText,
          unauthorized: chooser.unauthorized,
          adapterOff: chooser.adapterOff,
          notice: chooser.unauthorized ? `${PRODUCT} needs access to Bluetooth to find devices.` : chooser.adapterOff ? "Bluetooth is turned off. Turn it on to find devices." : null,
          noticeIcon: chooser.unauthorized ? "lock" : chooser.adapterOff ? "antenna.radiowaves.left.and.right.slash" : null,
          noticeLink: chooser.unauthorized ? "Open Bluetooth Settings" : null,
          cancelLabel: chooser.cancelLabel || "Cancel",
          okLabel: chooser.okLabel || "Connect",
          valid,
          dark: !!theme.dark,
          theme: { textPrimary: theme.textPrimary, textSecondary: theme.textSecondary, toolbarHover: theme.toolbarHover, rowHover: theme.rowHover, icon: theme.icon, accent: theme.accent },
          goButton: theme.goButton,
          goButtonText: theme.goButtonText,
        })}
        onEvent={(e) => {
          if (e.kind === "select") setSelected(e.index);
          else if (e.kind === "choose") choose(e.index < 0 ? selected : e.index);
          else if (e.kind === "cancel") cancel();
          else if (e.kind === "refresh") void refreshDeviceChooser(chooser.id);
          else void openBluetoothSettings(chooser.id);
        }}
      />
    </PromptPopover>
  );
}

function NativeChooserBody({ state, onEvent }: { state: string; onEvent: (e: NativeDeviceChooserEvent) => void }) {
  const [height, setHeight] = useState<number | null>(null);
  const frame = usePromptPlacement();
  if (frame) {
    const framed = JSON.stringify({ ...(JSON.parse(state) as object), popover: frame.placement });
    return <NativeDeviceChooserView style={StyleSheet.absoluteFill} state={framed} onChooserEvent={(e) => ((e.nativeEvent as { kind: string }).kind === "dismiss" ? frame.onDismiss?.() : onEvent(e.nativeEvent))} />;
  }
  return (
    <View style={{ height: height ?? undefined, minHeight: 1 }}>
      <NativeDeviceChooserView style={StyleSheet.absoluteFill} state={state} onChooserEvent={(e) => onEvent(e.nativeEvent)} onChooserHeight={(e) => setHeight(e.nativeEvent.height)} />
    </View>
  );
}
