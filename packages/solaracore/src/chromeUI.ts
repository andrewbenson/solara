import type { EventSubscription } from "expo-modules-core";
import { nativeModule } from "./nativeModules";

export type DeviceChooser = {
  id: number;
  browserId: number;
  open: boolean;
  title: string;
  okLabel: string;
  cancelLabel: string;
  noOptionsText: string;
  scanningText: string;
  refreshing: boolean;
  canRefresh: boolean;
  adapterOff: boolean;
  unauthorized: boolean;
  bothButtonsEnabled: boolean;
  showSignal: boolean;
  options: { optionId?: number; name: string; connected: boolean; paired: boolean; signal: number }[];
};

export type ActionPopupRequest = { browserId: number; extensionId: string };

export type NativeChromeUI = {
  addListener(name: "onDeviceChooser", listener: (e: DeviceChooser) => void): EventSubscription;
  addListener(name: "onActionPopup" | "onActionShortcut", listener: (e: ActionPopupRequest) => void): EventSubscription;
  selectDevice(id: number, index: number): Promise<void>;
  cancelDeviceChooser(id: number): Promise<void>;
  refreshDeviceChooser(id: number): Promise<void>;
  openBluetoothSettings(id: number): Promise<void>;
  actionStates(browserId: number, ids: string[]): Promise<Record<string, NativeActionState>>;
  changeCaptureSource(capturer: number, target: number): Promise<boolean>;
  stopCapture(capturer: number): Promise<boolean>;
  showAutofillSuggestions(browserId: number, passwords: boolean): Promise<boolean>;
};

type NativeActionState = {
  title: string;
  badgeText: string;
  badgeColor: string | null;
  badgeTextColor: string | null;
  popup: string;
  enabled: boolean;
  icon: string;
};

export const ChromeUI = nativeModule("SolaraChromeUI");

if (__DEV__) (globalThis as { acChromeUI?: unknown }).acChromeUI = ChromeUI;

export const onDeviceChooser = (listener: (e: DeviceChooser) => void) => ChromeUI.addListener("onDeviceChooser", listener);
export const selectDevice = (id: number, index: number) => ChromeUI.selectDevice(id, index);
export const cancelDeviceChooser = (id: number) => ChromeUI.cancelDeviceChooser(id);
export const refreshDeviceChooser = (id: number) => ChromeUI.refreshDeviceChooser(id);
export const openBluetoothSettings = (id: number) => ChromeUI.openBluetoothSettings(id);

export const onExtensionActionPopup = (listener: (e: ActionPopupRequest) => void) => ChromeUI.addListener("onActionPopup", listener);
export const onExtensionActionShortcut = (listener: (e: ActionPopupRequest) => void) => ChromeUI.addListener("onActionShortcut", listener);

export const changeCaptureSource = (capturer: number, target: number) => ChromeUI.changeCaptureSource(capturer, target);
export const stopCapture = (capturer: number) => ChromeUI.stopCapture(capturer);

export const showAutofillSuggestions = (browserId: number, kind: "passwords" | "field") =>
  ChromeUI.showAutofillSuggestions(browserId, kind === "passwords");
