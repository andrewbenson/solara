import { requireNativeViewManager } from "expo-modules-core";
import type { ComponentType } from "react";
import type { NativeSyntheticEvent, ViewProps } from "react-native";

export type NativePromptEvent = { kind: "button" | "choice"; id: string } | { kind: "toggle"; value: boolean } | { kind: "close" };

export type NativePromptProps = ViewProps & {
  state: string;
  onPromptEvent?(e: NativeSyntheticEvent<NativePromptEvent>): void;
  onPromptHeight?(e: NativeSyntheticEvent<{ height: number }>): void;
};

let View: ComponentType<NativePromptProps> | null = null;

export function NativePromptView(props: NativePromptProps) {
  View ??= requireNativeViewManager<NativePromptProps>("SolaraPrompt") as ComponentType<NativePromptProps>;
  return <View {...props} />;
}

export type NativePanelEvent = { kind: "step"; step: number } | { kind: string; [key: string]: unknown };

export type NativePanelProps = ViewProps & {
  kind: string;
  state: string;
  onPanelEvent?(e: NativeSyntheticEvent<NativePanelEvent>): void;
  onPanelHeight?(e: NativeSyntheticEvent<{ height: number }>): void;
};

let PanelView: ComponentType<NativePanelProps> | null = null;

export function NativePanelView(props: NativePanelProps) {
  PanelView ??= requireNativeViewManager<NativePanelProps>("SolaraPanel") as ComponentType<NativePanelProps>;
  return <PanelView {...props} />;
}
