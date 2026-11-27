import { dismissNativeSidebarHover } from "@solara/settings";
import { setSidebarUi, sidebarUi, type Anchor, type Target } from "./state";

const watchers = new Set<() => void>();
let onCard = false;

function updatePointer(inside: boolean) {
  if (onCard === inside) return;
  onCard = inside;
  for (const watcher of watchers) watcher();
}

export const cardHoverProps = {
  onMouseEnter: () => updatePointer(!!sidebarUi().hover),
  onMouseLeave: () => updatePointer(false),
};

export const pointerOnRow = (id: string) => sidebarUi().hover?.id === id;
export const pointerOnCard = () => onCard;

export function watchPointerOnCard(watcher: () => void) {
  watchers.add(watcher);
  return () => void watchers.delete(watcher);
}

export function dismissHover() {
  dismissNativeSidebarHover(null);
  updatePointer(false);
  if (sidebarUi().hover) setSidebarUi({ hover: null });
}

export function dismissHoverIn(windowId: string) {
  dismissNativeSidebarHover(windowId);
}

export function applyHoverProbe(windowId: string, target: { kind?: Target["kind"] | null; id?: string | null; anchor?: Anchor | null; pointer?: boolean }) {
  if (target.pointer !== undefined) return updatePointer(target.pointer);
  if (target.kind && target.id && target.anchor) setSidebarUi({ hover: { windowId, kind: target.kind, id: target.id, anchor: target.anchor } });
  else if (sidebarUi().hover?.windowId === windowId) setSidebarUi({ hover: null });
}
