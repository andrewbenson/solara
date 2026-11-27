import { NativePromptView, type NativePromptEvent } from "@solara/settings";
import { createContext, useContext, type ReactNode } from "react";
import { StyleSheet } from "react-native";
import { useTheme } from "../../lib/theme";
import { useFormColors } from "../settings/controls";

export type PromptPlacement = { width: number; top: number; left: number | null; right: number | null; modal: boolean };

const Placement = createContext<{ placement: PromptPlacement; onDismiss?: () => void } | null>(null);

export const usePromptPlacement = () => useContext(Placement);

export function PromptPopover(props: {
  width: number;
  top: number;
  left?: number;
  right?: number;
  modal?: boolean;
  onDismiss?: () => void;
  children: ReactNode;
}) {
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
};

export function NativePromptBody({
  spec,
  onButton,
  onChoice,
  onToggle,
  onClose,
}: {
  spec: PromptSpec;
  onButton(id: string): void;
  onChoice?(id: string): void;
  onToggle?(value: boolean): void;
  onClose?(): void;
}) {
  const theme = useTheme();
  const colors = useFormColors();
  const frame = usePromptPlacement();
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
    else onClose?.();
  };
  return <NativePromptView style={StyleSheet.absoluteFill} state={state} onPromptEvent={(e) => onEvent(e.nativeEvent)} />;
}
