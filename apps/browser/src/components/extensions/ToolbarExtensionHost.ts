import { nativeExtensionCommand } from "@solara/settings";
import { useRef } from "react";

type Anchor = { x: number; y: number; width: number; height: number };

export function useNativeToolbarExtensions(windowId: string, tabId: string) {
  const anchors = useRef(new Map<string, Anchor>()).current;
  const onAnchors = (next: Record<string, [number, number, number, number]>) => {
    anchors.clear();
    for (const [slot, [x, y, width, height]] of Object.entries(next)) anchors.set(slot, { x, y, width, height });
  };
  const onClick = (id: string, kind: "press" | "menu") => {
    const slot = id === "ext-overflow" ? "*" : id.slice(4);
    return nativeExtensionCommand({ command: id === "ext-overflow" ? "overflow" : kind === "menu" ? "menu" : "openExtension", windowId, tabId, id: slot, anchor: anchors.get(slot) ?? { x: 0, y: 0, width: 28, height: 28 } });
  };
  return { onAnchors, onClick };
}
