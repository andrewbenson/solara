import type { EventSubscription } from "expo-modules-core";
import type { BrowsingDataType, Download, PermissionRequest, PermissionResult } from "./module";
import type { SiteSettings, SiteSettingType, SiteSettingValue } from "./siteSettings";
import type { ExternalAppAllowance } from "./externalApps";
import { optionalNativeModule } from "./nativeModules";

export type PageEngine = "chromium" | "webkit";

export type PageCookie = {
  name: string;
  value: string;
  domain: string;
  path: string;
  expires: number;
  session: boolean;
  httpOnly: boolean;
  secure: boolean;
  sameSite?: "Strict" | "Lax" | "None";
  partitionKey?: unknown;
  partitionKeyOpaque?: boolean;
};

export type WebKitNative = {
  addListener(name: "onWebKitDownload", listener: (d: Download) => void): EventSubscription;
  addListener(name: "onWebKitPermission", listener: (p: PermissionRequest) => void): EventSubscription;
  addListener(name: "onWebKitPermissionDismissed", listener: (p: { id: string }) => void): EventSubscription;
  prepareTransfer(key: string): void;
  releaseTransfer(key: string): void;
  resolvePermission(id: string, result: PermissionResult, remember: boolean): Promise<void>;
  downloadCommand(action: "cancel" | "pause" | "resume", id: string): Promise<void>;
  externalAppAllowances(profile: string): Promise<ExternalAppAllowance[]>;
  removeExternalAppAllowance(profile: string, origin: string, scheme: string): Promise<void>;
  endPrivateSession(session: string): Promise<void>;
  removeDownloadStaging(path: string, uuid: string, folder: string): Promise<boolean>;
  sitePermissions(profile: string, origin: string): Promise<Partial<SiteSettings>>;
  setSitePermission(profile: string, origin: string, kind: string, value: string): Promise<void>;
  resolveExternalApp(id: string, open: boolean, remember: boolean): Promise<void>;
  clearBrowsingData(profile: string, types: BrowsingDataType[], since: number | null): Promise<void>;
  deleteProfileData(profile: string): Promise<boolean>;
  cookieStoreKey(profile: string): Promise<string>;
  importCookies(profile: string, storeKey: string, cookies: PageCookie[]): Promise<number>;
  info(): Promise<{ safariVersion: string; userAgentSuffix: string; passkeys: boolean }>;
  passkeyAccess(): Promise<PasskeyAccess>;
  requestPasskeyAccess(): Promise<PasskeyAccess>;
  prepareContentBlocker?(): Promise<void>;
};

export type PasskeyAccessStatus = "entitlementRequired" | "deviceNotConfigured" | "notDetermined" | "authorized" | "denied";
export type PasskeyAccess = { entitled: boolean; status: PasskeyAccessStatus };

const NO_PASSKEY_ACCESS: PasskeyAccess = { entitled: false, status: "entitlementRequired" };

export const WebKit = optionalNativeModule("SolaraWebKit");

const NO_SUBSCRIPTION: EventSubscription = { remove() {} };

export const isWebKitDownload = (id: string) => id.startsWith("wk-download-");
export const isWebKitPermission = (id: string) => id.startsWith("wk-permission-");
export const isWebKitExternalApp = (id: string) => id.startsWith("wk-external-");
export const WEBKIT_SITE_SETTINGS: readonly SiteSettingType[] = ["camera", "microphone"];

export const webKitListener = <T>(name: "onDownload" | "onPermission" | "onPermissionDismissed", listener: (value: T) => void): EventSubscription =>
  WebKit ? WebKit.addListener(`onWebKit${name.slice(2)}` as "onWebKitDownload", listener as (d: Download) => void) : NO_SUBSCRIPTION;

export function leftDownloadStaging(download: Download): { path: string; uuid: string; folder: string } | null {
  const uuid = download.stagingId ?? (download.id.startsWith("wk-download-") ? download.id.slice("wk-download-".length) : "");
  const destination = download.destination ?? "";
  const folder = destination.slice(0, destination.lastIndexOf("/"));
  return download.staging && uuid && folder && download.state !== "downloading" ? { path: download.staging, uuid, folder } : null;
}

export async function removeLeftDownloadStaging(download: Download): Promise<boolean> {
  const left = leftDownloadStaging(download);
  if (!left || !WebKit) return false;
  return WebKit.removeDownloadStaging(left.path, left.uuid, left.folder).catch(() => false);
}
export const endWebKitPrivateSession = (session: string) => WebKit?.endPrivateSession(session) ?? Promise.resolve();
export const getWebKitSiteSettings = async (profile: string, origin: string): Promise<SiteSettings> =>
  ((await WebKit?.sitePermissions(profile, origin)) ?? {}) as SiteSettings;
export const setWebKitSiteSetting = (profile: string, origin: string, type: SiteSettingType, value: SiteSettingValue) =>
  WebKit?.setSitePermission(profile, origin, type, value) ?? Promise.resolve();
export const webKitInfo = () => WebKit?.info() ?? Promise.resolve(null);
export const prepareWebKitContentBlocker = () => WebKit?.prepareContentBlocker?.() ?? Promise.resolve();
export const webKitCookieStoreKey = (profile: string) => WebKit?.cookieStoreKey(profile) ?? Promise.resolve(null);
export const importWebKitCookies = (profile: string, storeKey: string, cookies: PageCookie[]) =>
  WebKit?.importCookies(profile, storeKey, cookies) ?? Promise.resolve(0);
const askPasskeys = (call: (native: WebKitNative) => Promise<PasskeyAccess>): Promise<PasskeyAccess> =>
  WebKit && typeof WebKit.passkeyAccess === "function" ? call(WebKit).catch(() => NO_PASSKEY_ACCESS) : Promise.resolve(NO_PASSKEY_ACCESS);
export const getPasskeyAccess = () => askPasskeys((native) => native.passkeyAccess());
export const requestPasskeyAccess = () => askPasskeys((native) => native.requestPasskeyAccess());
