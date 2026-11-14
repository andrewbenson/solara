import { create } from "zustand";
import { useShallow } from "zustand/react/shallow";

export const useWidths = create<Record<string, number>>()(() => ({}));
const nativeKeys = new Set<string>();

export const useMeasuredWidth = (key: string): number | undefined => useWidths((w) => w[key]);
export const useMeasuredWidths = (keys: string[]): (number | undefined)[] => useWidths(useShallow((w) => keys.map((k) => w[k])));

export function setMeasuredWidth(key: string, width: number) {
  if (nativeKeys.has(key)) return;
  if (useWidths.getState()[key] !== width) useWidths.setState({ [key]: width });
}

export function setNativeMeasuredWidths(widths: Record<string, number>) {
  const changed: Record<string, number> = {};
  const current = useWidths.getState();
  for (const [key, width] of Object.entries(widths)) {
    nativeKeys.add(key);
    if (current[key] !== width) changed[key] = width;
  }
  if (Object.keys(changed).length) useWidths.setState(changed);
}

export function dropNativeMeasuredWidth(key: string) {
  nativeKeys.delete(key);
  useWidths.setState((state) => {
    const next = { ...state };
    delete next[key];
    return next;
  }, true);
}
