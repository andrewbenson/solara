import type { LayoutChangeEvent } from "react-native";
import { useBrowser } from "../../store/browser";
import { type Point, type Rect } from "./hoverAim";
import { measureRow, setSidebarUi, sidebarUi, type Target } from "./state";

const SHOW_DELAY_MS = 500;
const HIDE_DELAY_MS = 160;
let showTimer: ReturnType<typeof setTimeout> | undefined;
let hideTimer: ReturnType<typeof setTimeout> | undefined;
let aimTimer: ReturnType<typeof setTimeout> | undefined;
let suppressed = false;
let ticket = 0;
let underPointer: string | null = null;
let owner: string | null = null;
let ownerWindow: string | null = null;

type Waiting = { windowId: string; target: Target | null; arrive: () => void };
const contentHeights = new Map<string, number>();
let cardFrame: Rect | null = null;
let onCard = false;
let exitPoint: Point | null = null;
let waiting: Waiting | null = null;
let held = false;

export const setHoverSpace = (windowId: string, height: number) => void contentHeights.set(windowId, height);

function hideCard() {
  held = false;
  onCard = false;
  exitPoint = null;
  waiting = null;
  clearTimeout(aimTimer);
  setSidebarUi({ hover: null });
}

function arrive(next: Waiting | null) {
  if (!next) return hoverLeave();
  next.arrive();
}

export const cardHoverProps = {
  onMouseEnter: () => {
    if (!sidebarUi().hover) return;
    onCard = true;
    clearTimeout(aimTimer);
    keepHover();
  },
  onMouseLeave: () => {
    onCard = false;
    const pending = waiting;
    waiting = null;
    arrive(pending);
  },
  onLayout: (e: LayoutChangeEvent) => {
    cardFrame = e.nativeEvent.layout;
  },
};

export const pointerOnRow = (id: string) => underPointer === id;
export const pointerOnCard = () => onCard;

const panelOpen = (windowId: string) => !!useBrowser.getState().windowUi[windowId]?.panel?.open;
export function suppressHover(value: boolean) {
  suppressed = value;
  if (value) dismissHover();
}

async function show(windowId: string, target: Target, mine: number) {
  const anchor = await measureRow(windowId, target.id);
  if (mine !== ticket || suppressed || !anchor || panelOpen(windowId) || sidebarUi().iconPicker || sidebarUi().renaming) return;
  if (onCard && sidebarUi().hover) return;
  exitPoint = null;
  setSidebarUi({ hover: { windowId, ...target, anchor } });
}

export function hoverEnter(windowId: string, target: Target) {
  if (suppressed || panelOpen(windowId)) return;
  clearTimeout(showTimer);
  clearTimeout(hideTimer);
  clearTimeout(aimTimer);
  waiting = null;
  const current = sidebarUi().hover;
  owner = target.id;
  ownerWindow = windowId;
  if (current?.id === target.id) return;
  const mine = ++ticket;
  if (current) void show(windowId, target, mine);
  else showTimer = setTimeout(() => void show(windowId, target, mine), SHOW_DELAY_MS);
}

export function hoverLeave(from?: unknown) {
  if (held || (typeof from === "string" && from !== owner)) return;
  owner = null;
  ticket++;
  clearTimeout(showTimer);
  clearTimeout(hideTimer);
  hideTimer = setTimeout(hideCard, HIDE_DELAY_MS);
}

export const keepHover = () => {
  clearTimeout(hideTimer);
  clearTimeout(aimTimer);
};

export function holdHover(on: boolean) {
  if (on === held) return;
  held = on;
  if (on) return keepHover();
  const hover = sidebarUi().hover;
  if (!hover || onCard) return;
  if (underPointer !== hover.id) return hoverLeave();
  owner = hover.id;
  ownerWindow = hover.windowId;
}

let nativeTarget: Target | null = null;

export function nativeRowHover(windowId: string, target: Target | null) {
  const previous = nativeTarget;
  nativeTarget = target;
  if (previous && previous.id !== target?.id) {
    if (underPointer === previous.id) underPointer = null;
    hoverLeave(previous.id);
  }
  if (target && target.id !== previous?.id) {
    underPointer = target.id;
    hoverEnter(windowId, target);
  }
}

export function dismissHover() {
  held = false;
  owner = null;
  ownerWindow = null;
  ticket++;
  clearTimeout(showTimer);
  clearTimeout(hideTimer);
  if (sidebarUi().hover) hideCard();
}

export function dismissHoverIn(windowId: string) {
  if (ownerWindow === windowId || sidebarUi().hover?.windowId === windowId) dismissHover();
}
