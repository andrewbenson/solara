import { Cef } from "./native";

export type FilterListCategory = "ads" | "trackers" | "cookies" | "regional" | "annoyances" | "security";

export type FilterList = {
  id: string;
  title: string;
  category: FilterListCategory;
  enabled: boolean;
  defaultOn: boolean;
  filters: number;
};

export type ContentBlockerStats = {
  ready: boolean;
  enabled: boolean;
  networkFilters?: number;
  cosmeticFilters?: number;
  unsupportedFilters?: number;
  parseMs: number;
  lookups: number;
  averageLookupMicros: number;
  maxLookupMicros: number;
};

export type ContentBlockerState = {
  enabled: boolean;
  version: string;
  lists: FilterList[];
  allowedHosts: string[];
  stats: ContentBlockerStats;
};

export type WebKitContentBlockerState = {
  enabled: boolean;
  allowed: boolean;
  ready: boolean;
  preparing: boolean;
  error: string | null;
  appliedGroups: string[];
  unsupportedLists: string[];
};

export const getWebKitContentBlocker = (host: string) => Cef.getWebKitContentBlocker(host);
export const getContentBlocker = () => Cef.getContentBlocker();
export const setContentBlockerEnabled = (enabled: boolean) => Cef.setContentBlockerEnabled(enabled);
export const setFilterListEnabled = (id: string, enabled: boolean) => Cef.setFilterListEnabled(id, enabled);
export const isContentBlockerAllowed = (host: string) => Cef.isContentBlockerAllowed(host);
export const setContentBlockerAllowed = (host: string, allowed: boolean) => Cef.setContentBlockerAllowed(host, allowed);
export const onContentBlockerChange = (listener: (stats: ContentBlockerStats) => void) =>
  Cef.addListener("onContentBlocker", listener);
