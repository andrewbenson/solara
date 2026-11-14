import { useState } from "react";
import { Easing, type GestureResponderEvent } from "react-native";

export type ClickModifiers = { metaKey: boolean; altKey: boolean; shiftKey: boolean };
export function modifiersOf(e: GestureResponderEvent | undefined): ClickModifiers {
  const n = (e?.nativeEvent ?? {}) as Partial<ClickModifiers>;
  return { metaKey: !!n.metaKey, altKey: !!n.altKey, shiftKey: !!n.shiftKey };
}

export const POPOVER_MARGIN = 8;

const INSET = 16;
const ROW_INSET = 6;
const RADIUS = 12;
const ROW_HEIGHT = 32;
const ICON_SLOT = 20;
const ICON_GAP = 10;
export const PANEL = {
  radius: RADIUS,
  inset: INSET,
  rowInset: ROW_INSET,
  rowPadding: INSET - ROW_INSET,
  rowRadius: RADIUS - ROW_INSET,
  rowHeight: ROW_HEIGHT,
  iconSlot: ICON_SLOT,
  iconSize: 13,
  iconGap: ICON_GAP,
  textColumn: INSET + ICON_SLOT + ICON_GAP,
  listPadding: INSET - (ROW_HEIGHT - ICON_SLOT) / 2,
  headerGap: 8,
  separatorGap: 5,
  titleSize: 13,
  titleLine: 16,
  subtitleSize: 11,
  subtitleLine: 14,
  valueSize: 12,
} as const;

export const POPOVER_MOTION = {
  open: { duration: 150, easing: Easing.out(Easing.cubic) },
  close: { duration: 100, easing: Easing.in(Easing.quad) },
} as const;

export function usePopoverPresence(open: boolean) {
  const [shown, setShown] = useState(open);
  if (open && !shown) setShown(true);
  return { shown: open || shown, closing: !open, onClosed: () => setShown(false) };
}
