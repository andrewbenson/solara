import { requireOptionalNativeModule } from "expo-modules-core";

type WindowShellModule = {
  active(windowId: string): boolean;
  nativeLayout?(windowId: string): boolean;
  nativeLayoutGeneration?(windowId: string): number;
  layoutAnchorsAvailable?(windowId: string): boolean;
  layoutAnchors?(windowId: string): Promise<string>;
  observeLayoutAnchors?(windowId: string, enabled: boolean, generation: number | null, reader: string): Promise<string>;
  layoutPreferences?(windowId: string): string | null;
  pagesPool?(): boolean;
  paneRoots?(windowId: string): boolean;
  mainOnTop?(windowId: string): boolean;
  peekAction?(windowId: string, tabId: string, action: string): Promise<boolean>;
  setBackdrop(windowId: string, json: string): Promise<void>;
  setLayout?(windowId: string, layout: WindowShellLayout): Promise<void>;
  setModal?(windowId: string, owner: string, shown: boolean): Promise<void>;
  accessibilityReach?(windowId: string): Promise<Record<string, number> | null>;
  describe(windowId: string): Promise<string>;
};

const native = requireOptionalNativeModule<WindowShellModule>("SolaraWindowShell");

export function windowShellActive(windowId: string): boolean {
  try {
    return native?.active(windowId) ?? false;
  } catch {
    return false;
  }
}

export function windowNativeLayout(windowId: string): boolean {
  return native?.nativeLayout?.(windowId) ?? false;
}

export function windowNativeLayoutGeneration(windowId: string): number {
  return native?.nativeLayoutGeneration?.(windowId) ?? 0;
}

export type WindowPaneSplit = {
  id: string;
  windowId: string;
  tabIds: string[];
  orientation: "horizontal" | "vertical";
  sizes: number[];
  stack?: { index: number; sizes: [number, number] };
};

export type WindowLayoutPreferences = {
  generation: number;
  revision: number;
  topTabs: boolean;
  sidebarOpen: boolean;
  sidebarWidth: number;
  savedSidebarWidth: number;
  addressBar: boolean;
  activeTabId: string | null;
  paneTabIds: string[];
  split: WindowPaneSplit | null;
  peekTabId: string | null;
};

export function windowLayoutPreferences(windowId: string): WindowLayoutPreferences | null {
  const json = native?.layoutPreferences?.(windowId);
  return json ? JSON.parse(json) as WindowLayoutPreferences : null;
}

export function windowPagesPoolActive(): boolean {
  try {
    return native?.pagesPool?.() ?? false;
  } catch {
    return false;
  }
}

export function windowPaneRootsActive(windowId: string): boolean {
  try {
    return native?.paneRoots?.(windowId) ?? false;
  } catch {
    return false;
  }
}

export function windowMainOnTop(windowId: string): boolean {
  try {
    return native?.mainOnTop?.(windowId) ?? false;
  } catch {
    return false;
  }
}

export function windowPeekAction(windowId: string, tabId: string, action: "beginClose" | "dismiss" | "closed" | "expand" | "promote" | "split" | "closeFind"): Promise<boolean> {
  return native?.peekAction?.(windowId, tabId, action) ?? Promise.resolve(false);
}

export function setWindowShellBackdrop(windowId: string, json: string) {
  return native?.setBackdrop(windowId, json) ?? Promise.resolve();
}

export type WindowShellLayout = Partial<{
  dock: number;
  sidebarWidth: number;
  topTabs: boolean;
  fullscreen: boolean;
  addressBarInSidebar: boolean;
  away: boolean;
  peekRight: number;
}>;

export function setWindowShellLayout(windowId: string, layout: WindowShellLayout) {
  return native?.setLayout?.(windowId, layout) ?? Promise.resolve();
}

export function setWindowShellModal(windowId: string, owner: string, shown: boolean) {
  return native?.setModal?.(windowId, owner, shown) ?? Promise.resolve();
}

export function windowShellAccessibilityReach(windowId: string): Promise<Record<string, number> | null> {
  return native?.accessibilityReach?.(windowId) ?? Promise.resolve(null);
}

export async function describeWindowShell(windowId: string): Promise<Record<string, unknown> | null> {
  return native ? (JSON.parse(await native.describe(windowId)) as Record<string, unknown> | null) : null;
}

export type WindowLayoutAnchors = {
  windowId: string;
  windowGeneration: number;
  generation: number;
  storeRevision: number;
  anchors: Record<string, [number, number, number, number]>;
  sidebar: boolean;
  profileTitle: string;
  profileNameWidth: number;
  stripAvailableWidth: number;
};

export type WindowLayoutObservation = { windowGeneration: number; batch: WindowLayoutAnchors | null };
type AnchorEntry = { owner: object; ready: boolean; windowGeneration: number; batch?: WindowLayoutAnchors; pending?: WindowLayoutAnchors };
const newerAnchors = (next: WindowLayoutAnchors, prior?: WindowLayoutAnchors) => !prior || next.windowGeneration > prior.windowGeneration || (next.windowGeneration === prior.windowGeneration && (next.generation > prior.generation || (next.generation === prior.generation && next.storeRevision > prior.storeRevision)));

export class WindowLayoutAnchorFeed {
  private entries = new Map<string, AnchorEntry>();

  begin(windowId: string, owner: object) {
    this.entries.set(windowId, { owner, ready: false, windowGeneration: 0 });
  }

  initial(windowId: string, owner: object, observation: WindowLayoutObservation): WindowLayoutAnchors | undefined {
    const entry = this.entries.get(windowId);
    if (!entry || entry.owner !== owner) return;
    entry.ready = true;
    entry.windowGeneration = Math.max(entry.windowGeneration, observation.windowGeneration);
    let next = observation.batch;
    if (entry.pending && (!next || newerAnchors(entry.pending, next))) next = entry.pending;
    entry.pending = undefined;
    return next ? this.event(windowId, next) : undefined;
  }

  event(windowId: string, next: WindowLayoutAnchors): WindowLayoutAnchors | undefined {
    const entry = this.entries.get(windowId);
    if (!entry || next.windowId !== windowId || next.windowGeneration < entry.windowGeneration) return;
    if (!entry.ready) {
      if (newerAnchors(next, entry.pending)) entry.pending = next;
      return;
    }
    if (!newerAnchors(next, entry.batch)) return;
    entry.windowGeneration = next.windowGeneration;
    entry.batch = next;
    return next;
  }

  end(windowId: string, owner: object): number | null | undefined {
    const entry = this.entries.get(windowId);
    if (!entry || entry.owner !== owner) return;
    this.entries.delete(windowId);
    return entry.windowGeneration || null;
  }

  active(windowId: string): boolean { return this.entries.has(windowId); }

  current(windowId: string): WindowLayoutAnchors | undefined { return this.entries.get(windowId)?.batch; }
}

export function windowLayoutAnchorsAvailable(windowId: string): boolean {
  return native?.layoutAnchorsAvailable?.(windowId) ?? false;
}

export async function observeWindowLayoutAnchors(windowId: string, enabled: boolean, reader: string, windowGeneration: number | null = null): Promise<WindowLayoutObservation | null> {
  const json = await native?.observeLayoutAnchors?.(windowId, enabled, windowGeneration, reader);
  return json ? JSON.parse(json) as WindowLayoutObservation | null : null;
}

export async function readWindowLayoutAnchors(windowId: string): Promise<WindowLayoutAnchors | null> {
  const json = await native?.layoutAnchors?.(windowId);
  return json ? JSON.parse(json) as WindowLayoutAnchors | null : null;
}
