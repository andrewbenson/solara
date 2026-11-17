import { requireNativeViewManager, requireOptionalNativeModule } from "expo-modules-core";
import { forwardRef, type ComponentType, type Ref } from "react";
import type { NativeSyntheticEvent, ViewProps } from "react-native";
import type { NativeNewTabHandle, NativeSuggestion, NewTabDisposition, NewTabJourneyMark } from "./newTab";

type Event<T> = NativeSyntheticEvent<T & { nativeActions?: boolean }>;

export type NativeOmniboxVariant = "panel" | "sidebar";

export type NativeOmniboxProps = ViewProps & {
  windowId: string;
  tabId: string;
  profileId: string;
  variant: NativeOmniboxVariant;
  floating?: boolean;
  opensTab?: boolean;
  initialText?: string;
  incognito: boolean;
  currentUrl: string;
  dark: boolean;
  theme: Record<string, string>;
  offline?: boolean;
  driven?: boolean;
  panel?: string;
  onOpen?(e: Event<{ url: string; disposition: NewTabDisposition }>): void;
  onSwitch?(e: Event<{ tabId: string; url: string; disposition: NewTabDisposition }>): void;
  onAction?(e: Event<{ id: string }>): void;
  onExtension?(e: Event<{ suggestion: NativeSuggestion }>): void;
  onRemoveHistory?(e: Event<{ url: string }>): void;
  onChosen?(e: Event<{ suggestion: NativeSuggestion | null }>): void;
  onOpenChip?(e: Event<Record<string, never>>): void;
  onDictate?(e: Event<Record<string, never>>): void;
  onContextMenu?(e: Event<{ hasSelection: boolean; hasValue: boolean }>): void;
  onJourney?(e: Event<{ mark: NewTabJourneyMark }>): void;
  onLatency?(e: Event<{ ms: number }>): void;
  onBarLayout?(e: Event<{ height: number }>): void;
  onDriverState?(e: Event<{ json: string }>): void;
  onDone?(e: Event<{ reason: "escape" | "closeKey" | null }>): void;
  onCancel?(e: Event<Record<string, never>>): void;
  onSiteControls?(e: Event<Record<string, never>>): void;
};

export type NativeOmniboxHandle = NativeNewTabHandle;

const native = requireOptionalNativeModule<{ available(): boolean; prefixWidth(prefix: string, text: string): number; showPanel(windowId: string, json: string): Promise<void> }>("SolaraOmniboxBar");

export function showNativePanel(windowId: string, json: string): void {
  native?.showPanel(windowId, json).catch(() => {});
}

export function nativeUrlPrefixWidth(prefix: string, text: string): number {
  try {
    return native?.prefixWidth(prefix, text) ?? 0;
  } catch {
    return 0;
  }
}

let availability: boolean | null = null;

export function nativeOmniboxAvailable(): boolean {
  if (availability !== null) return availability;
  try {
    availability = !!native?.available();
  } catch {
    availability = false;
  }
  return availability;
}

let View: ComponentType<NativeOmniboxProps & { ref?: Ref<NativeOmniboxHandle> }> | null = null;

export const NativeOmnibox = forwardRef<NativeOmniboxHandle, NativeOmniboxProps>(function NativeOmnibox(props, ref) {
  View ??= requireNativeViewManager<NativeOmniboxProps>("SolaraOmniboxBar") as unknown as ComponentType<NativeOmniboxProps & { ref?: Ref<NativeOmniboxHandle> }>;
  return <View ref={ref} {...props} />;
});
