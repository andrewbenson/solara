import { requireOptionalNativeModule, type EventSubscription } from "expo-modules-core";

export type PooledPageProps = {
  pageColor?: string | null;
  contentsBackgroundColor?: string | null;
  autoPictureInPicture?: boolean;
  shownUrl?: string | null;
};

export type PooledPageEvent = { tabId: string; name: string; payload: Record<string, unknown> };

export type LivePooledPage = { tabId: string; engine: string; ready: Record<string, unknown> | null; navigation: Record<string, unknown> | null };

export type TabPool = {
  available(): boolean;
  pageCall(tabId: string, method: string, args: unknown[]): Promise<unknown>;
  claimFocusPage(generation: number, tabId: string): Promise<boolean>;
  setPageProps(tabId: string, props: PooledPageProps): Promise<void>;
  livePages?(): Promise<LivePooledPage[]>;
  addListener(name: "onPageEvent", listener: (event: PooledPageEvent) => void): EventSubscription;
  addListener(name: "onPlaced", listener: (event: { places: Record<string, string> }) => void): EventSubscription;
};

export const tabPool = requireOptionalNativeModule<TabPool>("SolaraTabPool");

export function tabPoolAvailable(): boolean {
  try {
    return tabPool?.available() ?? false;
  } catch {
    return false;
  }
}
