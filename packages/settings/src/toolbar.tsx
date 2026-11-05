import { requireNativeViewManager, requireOptionalNativeModule, type EventSubscription } from "expo-modules-core";
import type { ComponentType } from "react";
import type { NativeSyntheticEvent, ViewProps } from "react-native";

export type ToolbarClick = { id: string; kind: "press" | "menu" | "middle" | "submit" | "cancel" | "blur" | "focus"; meta: boolean; alt: boolean; shift: boolean; text: string | null };

export type NativeToolbarProps = ViewProps & {
  state: string;
  onToolbarClick?(e: NativeSyntheticEvent<ToolbarClick>): void;
  onToolbarAnchors?(e: NativeSyntheticEvent<{ anchors: Record<string, [number, number, number, number]> }>): void;
};

export type ExtensionPopupIntent = {
  extensionId: string;
  popupUrl: string;
  profile: string;
  tabId: string;
  windowId: string;
  anchor: { x: number; y: number; width: number; height: number };
  requiresActive: boolean;
};

export type ExtensionPopupChange = { windowId: string; extensionId: string | null; tabId?: string; reason?: "replacement" | "dismissal" };
export type ExtensionPopupOpenWindow = {
  windowId: string;
  profile: string;
  request: {
    url: string;
    disposition: "foreground" | "background" | "window" | "popup" | "incognito" | "current" | "split" | "peek";
    adoptId?: string;
    profile?: string;
    point?: { x: number; y: number };
  };
};

type NativeToolbarModule = {
  available(): boolean;
  showExtensionPopup(requestJSON: string): Promise<boolean>;
  closeExtensionPopup(windowId: string | null): Promise<void>;
  addListener(event: "onExtensionPopupChanged", listener: (event: ExtensionPopupChange) => void): EventSubscription;
  addListener(event: "onExtensionPopupOpenWindow", listener: (event: ExtensionPopupOpenWindow) => void): EventSubscription;
};

const native = requireOptionalNativeModule<NativeToolbarModule>("SolaraToolbar");

export const showNativeExtensionPopup = (intent: ExtensionPopupIntent): Promise<boolean> =>
  native?.showExtensionPopup?.(JSON.stringify(intent)) ?? Promise.resolve(false);

export const closeNativeExtensionPopup = (windowId: string | null = null): Promise<void> =>
  native?.closeExtensionPopup?.(windowId) ?? Promise.resolve();

export const onNativeExtensionPopupOpenWindow = (listener: (event: ExtensionPopupOpenWindow) => void): EventSubscription | null =>
  native?.addListener?.("onExtensionPopupOpenWindow", listener) ?? null;

export const onNativeExtensionPopupChanged = (listener: (event: ExtensionPopupChange) => void): EventSubscription | null =>
  native?.addListener?.("onExtensionPopupChanged", listener) ?? null;

let availability: boolean | null = null;

export function nativeToolbarAvailable(): boolean {
  if (availability !== null) return availability;
  try {
    availability = !!native?.available();
  } catch {
    availability = false;
  }
  return availability;
}

let View: ComponentType<NativeToolbarProps> | null = null;

export function NativeToolbarView(props: NativeToolbarProps) {
  View ??= requireNativeViewManager<NativeToolbarProps>("SolaraToolbar") as ComponentType<NativeToolbarProps>;
  return <View {...props} />;
}

type SidebarAddressBarModule = { available(): boolean; set(windowId: string, json: string | null): Promise<void>; sample(windowId: string): Promise<string | null> };

const sidebarAddressBar = requireOptionalNativeModule<SidebarAddressBarModule>("SolaraSidebarAddressBar");

let sidebarAddressAvailability: boolean | null = null;

export function sidebarAddressBarAvailable(): boolean {
  if (sidebarAddressAvailability !== null) return sidebarAddressAvailability;
  try {
    sidebarAddressAvailability = !!sidebarAddressBar?.available();
  } catch {
    sidebarAddressAvailability = false;
  }
  return sidebarAddressAvailability;
}

export function setSidebarAddressBar(windowId: string, json: string | null): void {
  void sidebarAddressBar?.set(windowId, json);
}

export async function sampleSidebarAddressBar(windowId: string): Promise<unknown> {
  const json = await sidebarAddressBar?.sample(windowId);
  return json ? JSON.parse(json) : null;
}

let SidebarAddressHost: ComponentType<ViewProps & { windowId: string }> | null = null;

export function NativeSidebarAddressBarView(props: ViewProps & { windowId: string }) {
  SidebarAddressHost ??= requireNativeViewManager<ViewProps & { windowId: string }>("SolaraSidebarAddressBar") as ComponentType<ViewProps & { windowId: string }>;
  return <SidebarAddressHost {...props} />;
}
