import { requireNativeViewManager, requireOptionalNativeModule, type EventSubscription } from "expo-modules-core";
import { useEffect, useState, type ComponentType } from "react";
import type { NativeSyntheticEvent, ViewProps } from "react-native";

export type ToolbarClick = { id: string; kind: "press" | "menu" | "middle" | "submit" | "cancel" | "blur" | "focus"; meta: boolean; alt: boolean; shift: boolean; text: string | null; nativeActions?: boolean; tabId?: string };

export type NativeToolbarProps = ViewProps & {
  input: string;
  onToolbarClick?(e: NativeSyntheticEvent<ToolbarClick>): void;
  onToolbarAnchors?(e: NativeSyntheticEvent<{ anchors: Record<string, [number, number, number, number]> }>): void;
};

export type ExtensionPopupChange = { windowId: string; extensionId: string | null; tabId?: string; reason?: "replacement" | "dismissal" };
type NativeToolbarModule = {
  available(): boolean;
  extensionPopupWindow(): string | null;
  extensionCommand(json: string): Promise<void>;
  refreshExtensionCatalog(profile: string, afterChange: boolean): Promise<string>;
  closeExtensionPopup(windowId: string | null): Promise<void>;
  addListener(event: "onExtensionPopupChanged", listener: (event: ExtensionPopupChange) => void): EventSubscription;
};

const native = requireOptionalNativeModule<NativeToolbarModule>("SolaraToolbar");

export const closeNativeExtensionPopup = (windowId: string | null = null): Promise<void> =>
  native?.closeExtensionPopup?.(windowId) ?? Promise.resolve();

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

export const refreshNativeExtensionCatalog = (profile: string, afterChange = false) => native?.refreshExtensionCatalog(profile, afterChange) ?? Promise.resolve("[]");


export const nativeExtensionCommand = (input: unknown) => native?.extensionCommand(JSON.stringify(input)) ?? Promise.resolve();


export function useNativeExtensionPopupShown(windowId: string): boolean {
  const read = () => native?.extensionPopupWindow?.() === windowId;
  const [shown, setShown] = useState(read);
  useEffect(() => {
    const subscription = onNativeExtensionPopupChanged(() => setShown(read()));
    setShown(read());
    return () => subscription?.remove();
  }, [windowId]);
  return shown;
}
