import { requireNativeViewManager } from "expo-modules-core";
import type { ComponentType } from "react";
import { View, type ViewProps } from "react-native";

type NativeCardProps = ViewProps & { windowId: string; state: string };
type CardProps = ViewProps & { nativeSmall: boolean; windowId: string; tabId: string; paints: boolean; radius: number };

let NativeCard: ComponentType<NativeCardProps> | null = null;

export function SmallWindowCard({ nativeSmall, windowId, tabId, paints, radius, ...props }: CardProps) {
  if (!nativeSmall) return <View {...props} />;
  NativeCard ??= requireNativeViewManager<NativeCardProps>("SolaraMedia") as ComponentType<NativeCardProps>;
  return <NativeCard {...props} windowId={windowId} state={JSON.stringify({ tabId, paints, radius })} />;
}
