import { requireNativeViewManager, requireOptionalNativeModule } from "expo-modules-core";
import type { ComponentType } from "react";
import type { ViewProps } from "react-native";

export type HostedViewProps = ViewProps & { kind: string; windowId: string; active?: boolean; state?: string };

type HostedEvent = { kind: string; windowId: string; name: string; payload: Record<string, unknown> };

type HostedModule = {
  kinds(): string[];
  bookmarkNativeSourceVersion?(): number;
  focusPageIfUnclaimed?(windowId: string, tabId: string): Promise<boolean>;
  addListener?(name: "onHostedEvent", listener: (event: HostedEvent) => void): { remove(): void };
  takeSwitcherPress?(windowId: string): number;
  devHost(kind: string, windowId: string, on: boolean): Promise<Record<string, string>>;
  sidebarRowFrame(windowId: string, key: string): Promise<{ x: number; y: number; width: number; height: number } | null>;
  sidebarShell?(windowId: string): Promise<string>;
};

const native = requireOptionalNativeModule<HostedModule>("SolaraHosted");

export const nativeBookmarksBarSourceAvailable = () => native?.bookmarkNativeSourceVersion?.() === 1;

export function hostedKinds(): string[] {
  try {
    return native?.kinds() ?? [];
  } catch {
    return [];
  }
}

export function takeSwitcherPress(windowId: string): number | null {
  try {
    const index = native?.takeSwitcherPress?.(windowId) ?? -1;
    return index >= 0 ? index : null;
  } catch {
    return null;
  }
}

export function sidebarRowFrame(windowId: string, key: string) {
  return native?.sidebarRowFrame(windowId, key) ?? Promise.resolve(null);
}

export function onHostedEvent(
  kind: string,
  windowId: string | null,
  listener: (name: string, payload: Record<string, unknown>, windowId: string) => void,
): () => void {
  const subscription = native?.addListener?.("onHostedEvent", (event) => {
    if (event.kind === kind && (windowId === null || event.windowId === windowId)) listener(event.name, event.payload, event.windowId);
  });
  return () => subscription?.remove();
}

export function focusPageIfUnclaimed(windowId: string, tabId: string): Promise<boolean> {
  return native?.focusPageIfUnclaimed?.(windowId, tabId) ?? Promise.resolve(false);
}

export function hostedSidebarShell(windowId: string): Promise<string> {
  return native?.sidebarShell?.(windowId) ?? Promise.resolve("null");
}

let View: ComponentType<HostedViewProps> | null = null;

export function SolaraHostedView(props: HostedViewProps) {
  View ??= requireNativeViewManager<HostedViewProps>("SolaraHosted") as ComponentType<HostedViewProps>;
  return <View {...props} />;
}
