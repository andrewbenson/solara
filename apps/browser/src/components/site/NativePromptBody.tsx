import { nativePagesAvailable, nativeToolbarAvailable, NativePromptView, type NativePromptEvent } from "@solara/settings";
import { createContext, useContext, useState, type ComponentProps, type ReactNode } from "react";
import { StyleSheet, View } from "react-native";
import { useTheme } from "../../lib/theme";
import { Popover } from "../layout/controls";
import { useFormColors } from "../settings/controls";

export type PromptPlacement = { width: number; top: number; left: number | null; right: number | null; modal: boolean };

const Placement = createContext<{ placement: PromptPlacement; onDismiss?: () => void } | null>(null);

export const usePromptPlacement = () => useContext(Placement);

export const nativePromptFrames = () => nativeToolbarAvailable() && nativePagesAvailable();

export function PromptPopover(props: ComponentProps<typeof Popover> & { children: ReactNode }) {
  if (!nativePromptFrames()) return <Popover {...props} />;
  const placement = { width: props.width, top: props.top, left: props.left ?? null, right: props.right ?? null, modal: props.modal ?? true };
  return <Placement.Provider value={{ placement, onDismiss: props.onDismiss }}>{props.children}</Placement.Provider>;
}

export type PromptLine = { text: string; strong?: boolean; tone?: "primary" | "secondary"; size?: number; kern?: number; maxLines?: number };
export type PromptDetail =
  | { kind: "well"; sections: { label?: string; lines: PromptLine[] }[] }
  | { kind: "choices"; choices: { id: string; title: string; selected: boolean }[] }
  | { kind: "checkbox"; label: string; value: boolean }
  | { kind: "note"; text: string };
export type PromptSpec = {
  icons: string[];
  inputProtectionKey?: string;
  image?: string | null;
  title: string;
  message?: string | null;
  details?: PromptDetail[];
  buttons: { id: string; title: string; primary?: boolean }[];
  close?: boolean;
  rows?: { id: string; icon: string; title: string }[];
  rowsMore?: string | null;
};

export function NativePromptBody({
  spec,
  onButton,
  onChoice,
  onToggle,
  onClose,
  onRow,
}: {
  spec: PromptSpec;
  onButton(id: string): void;
  onChoice?(id: string): void;
  onToggle?(value: boolean): void;
  onClose?(): void;
  onRow?(id: string): void;
}) {
  const theme = useTheme();
  const colors = useFormColors();
  const frame = usePromptPlacement();
  const [height, setHeight] = useState<number | null>(null);
  const state = JSON.stringify({
    popover: frame?.placement ?? null,
    icons: spec.icons,
    inputProtectionKey: spec.inputProtectionKey,
    image: spec.image ?? null,
    title: spec.title,
    message: spec.message ?? null,
    details: spec.details ?? [],
    buttons: spec.buttons,
    close: spec.close ?? true,
    rows: spec.rows ?? null,
    rowsMore: spec.rowsMore ?? null,
    dark: !!theme.dark,
    theme: { textPrimary: theme.textPrimary, textSecondary: theme.textSecondary, toolbarHover: theme.toolbarHover, rowHover: theme.rowHover, icon: theme.icon, accent: colors.accent },
    control: colors.control,
    controlBorder: colors.controlBorder,
    goButton: theme.goButton,
    goButtonText: theme.goButtonText,
  });
  const onEvent = (e: NativePromptEvent) => {
    if (e.kind === "button") onButton(e.id);
    else if (e.kind === "choice") onChoice?.(e.id);
    else if (e.kind === "toggle") onToggle?.(e.value);
    else if ((e as { kind: string }).kind === "dismiss") frame?.onDismiss?.();
    else if ((e as { kind: string }).kind === "row") onRow?.((e as unknown as { id: string }).id);
    else onClose?.();
  };
  if (frame) return <NativePromptView style={StyleSheet.absoluteFill} state={state} onPromptEvent={(e) => onEvent(e.nativeEvent)} />;
  return (
    <View style={{ height: height ?? undefined, minHeight: 1 }}>
      <NativePromptView style={StyleSheet.absoluteFill} state={state} onPromptEvent={(e) => onEvent(e.nativeEvent)} onPromptHeight={(e) => setHeight(e.nativeEvent.height)} />
    </View>
  );
}
