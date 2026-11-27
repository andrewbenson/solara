import { requireNativeViewManager } from "expo-modules-core";
import type { ComponentType } from "react";
import type { ViewProps } from "react-native";

export type NativeSitePanelProps = ViewProps & {
  request: string;
  onSitePanelClosed?(): void;
};

let View: ComponentType<NativeSitePanelProps> | null = null;

export function NativeSitePanelView(props: NativeSitePanelProps) {
  View ??= requireNativeViewManager<NativeSitePanelProps>("SolaraSitePanel") as ComponentType<NativeSitePanelProps>;
  return <View {...props} />;
}
