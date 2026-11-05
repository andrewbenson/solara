import { requireOptionalNativeModule } from "expo-modules-core";

type WindowShellModule = {
  active(windowId: string): boolean;
  pagesPool?(): boolean;
  paneRoots?(windowId: string): boolean;
  mainOnTop?(windowId: string): boolean;
  peekNative?(windowId: string): boolean;
  peekClose?(windowId: string): Promise<boolean>;
  peekExpand?(windowId: string): Promise<boolean>;
  setBackdrop(windowId: string, json: string): Promise<void>;
  setLayout?(windowId: string, layout: WindowShellLayout): Promise<void>;
  setSidePanel?(windowId: string, json: string | null): Promise<void>;
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

export function windowPeekNative(windowId: string): boolean {
  try {
    return native?.peekNative?.(windowId) ?? false;
  } catch {
    return false;
  }
}

export function closeWindowPeek(windowId: string): Promise<boolean> {
  return native?.peekClose?.(windowId) ?? Promise.resolve(false);
}

export function expandWindowPeek(windowId: string): Promise<boolean> {
  return native?.peekExpand?.(windowId) ?? Promise.resolve(false);
}

export function setWindowShellBackdrop(windowId: string, json: string) {
  return native?.setBackdrop(windowId, json) ?? Promise.resolve();
}

export type WindowShellLayout = Partial<{
  dock: number;
  sidebarWidth: number;
  sidePanel: number;
  topTabs: boolean;
  fullscreen: boolean;
  addressBarInSidebar: boolean;
  away: boolean;
  peekRight: number;
}>;

export function setWindowShellLayout(windowId: string, layout: WindowShellLayout) {
  return native?.setLayout?.(windowId, layout) ?? Promise.resolve();
}

export type WindowSidePanelState = {
  key: string;
  pageProfile: string;
  url: string;
  title: string;
  icon: string | null;
  width: number;
  room: number;
  look: {
    card: string;
    text: string;
    icon: string;
    hover: string;
    pressed: string;
    hairline: string;
    radius: number;
  };
};

export function setWindowSidePanel(windowId: string, state: WindowSidePanelState | null) {
  return native?.setSidePanel?.(windowId, state ? JSON.stringify(state) : null) ?? Promise.resolve();
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
