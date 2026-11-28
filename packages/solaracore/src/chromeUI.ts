import type { EventSubscription } from "expo-modules-core";
import { nativeModule } from "./nativeModules";

export type ActionPopupRequest = { browserId: number; extensionId: string };

export type NativeChromeUI = {
  addListener(name: "onActionPopup" | "onActionShortcut", listener: (e: ActionPopupRequest) => void): EventSubscription;
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

export const onExtensionActionPopup = (listener: (e: ActionPopupRequest) => void) => ChromeUI.addListener("onActionPopup", listener);
export const onExtensionActionShortcut = (listener: (e: ActionPopupRequest) => void) => ChromeUI.addListener("onActionShortcut", listener);

export const changeCaptureSource = (capturer: number, target: number) => ChromeUI.changeCaptureSource(capturer, target);
export const stopCapture = (capturer: number) => ChromeUI.stopCapture(capturer);

export const showAutofillSuggestions = (browserId: number, kind: "passwords" | "field") =>
  ChromeUI.showAutofillSuggestions(browserId, kind === "passwords");
