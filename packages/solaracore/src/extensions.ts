import type { EventSubscription } from "expo-modules-core";
import { ChromeUI } from "./chromeUI";
import { engineCall, onEngineEvent } from "./engine";
import { nativeModule } from "./nativeModules";

export type SiteAccess = "ON_ALL_SITES" | "ON_SPECIFIC_SITES" | "ON_CLICK";

export type InstalledExtension = {
  id: string;
  name: string;
  version: string;
  description: string;
  enabled: boolean;
  state: "ENABLED" | "DISABLED" | "TERMINATED" | "BLOCKLISTED";
  icon: string;
  permissions: string[];
  siteAccess: SiteAccess | null;
  sites: string[];
  optionsUrl: string | null;
  pinned: boolean;
  incognito: boolean;
  incognitoSplit?: boolean;
  fileAccess: boolean;
  mayModify: boolean;
  blockedByPolicy?: boolean;
  errors: string[];
  location: string;
  path: string | null;
  fromWebStore: boolean;
  webStoreUrl: string | null;
  homepageUrl: string | null;
  hasAction?: boolean;
  popup?: string | null;
  actionTitle?: string | null;
  actionIcon?: string | null;
  sidePanel?: string | null;
};

export type ExtensionPackage = {
  id?: string;
  name: string;
  shortName?: string | null;
  version: string;
  description: string;
  manifestVersion: number;
  icon: string | null;
  permissions: string[];
  optionalPermissions: string[];
  hostPermissions: string[];
  hasAction: boolean;
  popup: string | null;
  optionsPage: string | null;
  sidePanel: string | null;
  path: string;
};

export type ActionState = {
  badgeText: string;
  badgeColor: string | null;
  badgeTextColor: string | null;
  title: string;
  popup: string;
  enabled: boolean;
  icon: string;
};

export type ExtensionsChange = {
  profile: string;
  id: string;
  event: "installed" | "uninstalled" | "enabled" | "disabled" | "configured" | "reloaded";
};

type Result<T> = T | { error: string };

export type NativeExtensions = {
  addListener(name: "onChanged", listener: (e: ExtensionsChange) => void): EventSubscription;
  list(profile: string): Promise<Result<{ extensions: InstalledExtension[] }>>;
  inspectUnpacked(path: string): Promise<Result<ExtensionPackage>>;
  install(path: string, profile: string): Promise<Result<{ id: string }>>;
  setEnabled(id: string, profile: string, enabled: boolean): Promise<Result<{ ok: true }>>;
  uninstall(id: string, profile: string): Promise<Result<{ ok: true }>>;
  reload(id: string, profile: string): Promise<Result<{ ok: true }>>;
  configure(id: string, profile: string, options: Record<string, unknown>): Promise<Result<{ ok: true }>>;
  searchEngineList(profile: string): Promise<Result<{ list: unknown }>>;
  chooseFolder(): Promise<string | null>;
};

const Native = nativeModule("SolaraExtensions");

if (__DEV__) (globalThis as { acExtensions?: unknown }).acExtensions = Native;

export class ExtensionError extends Error {}

function unwrap<T>(result: Result<T>): T {
  if (result && typeof result === "object" && "error" in result) throw new ExtensionError(result.error);
  return result as T;
}

export const isExtensionId = (s: string) => /^[a-p]{32}$/.test(s);

export function webStoreExtensionId(urlOrId: string): string | null {
  const s = urlOrId.trim();
  if (isExtensionId(s)) return s;
  try {
    const url = new URL(s);
    const store =
      url.hostname === "chromewebstore.google.com" ||
      (url.hostname === "chrome.google.com" && url.pathname.startsWith("/webstore/"));
    if (!store) return null;
    const id = url.pathname.split("/").find(isExtensionId);
    return id ?? null;
  } catch {
    return null;
  }
}

export async function searchEngineList(profile: string): Promise<unknown> {
  return unwrap(await Native.searchEngineList(profile)).list;
}

export async function listExtensions(profile: string): Promise<InstalledExtension[]> {
  return unwrap(await Native.list(profile)).extensions;
}

export async function inspectUnpackedExtension(path: string): Promise<ExtensionPackage> {
  return unwrap(await Native.inspectUnpacked(path));
}

export async function installExtension(pkg: Pick<ExtensionPackage, "path">, profile: string): Promise<string> {
  return unwrap(await Native.install(pkg.path, profile)).id;
}

export async function setExtensionEnabled(id: string, profile: string, enabled: boolean) {
  unwrap(await Native.setEnabled(id, profile, enabled));
}

export async function uninstallExtension(id: string, profile: string) {
  unwrap(await Native.uninstall(id, profile));
}

export async function configureExtension(
  id: string,
  profile: string,
  options: {
    pinned?: boolean;
    incognito?: boolean;
    fileAccess?: boolean;
    siteAccess?: "allSites" | "specificSites" | "onClick";
  },
) {
  unwrap(await Native.configure(id, profile, options));
}

export async function extensionActionStates(browserId: number, ids: string[]): Promise<Record<string, ActionState>> {
  if (!ids.length || !browserId) return {};
  return ChromeUI.actionStates(browserId, ids);
}

export const onExtensionsChanged = (listener: (e: ExtensionsChange) => void) => Native.addListener("onChanged", listener);

export const watchExtensionActions = (profile: string) =>
  engineCall("ac_extensions_watch_actions", profile).then(
    () => true,
    () => false,
  );

export type ExtensionActionChange = { profile: string; id: string; kind: "action" | "sidePanel" | "registry" };

export const extensionActionChange = (p: { profile: string } & Record<string, unknown>): ExtensionActionChange => ({
  profile: p.profile,
  id: String(p.id),
  kind: p.kind === "sidePanel" || p.kind === "registry" ? p.kind : "action",
});

export const onExtensionActionChanged = (listener: (e: ExtensionActionChange) => void) =>
  onEngineEvent("extensions.action", (p) => {
    if (typeof p.id === "string") listener(extensionActionChange(p));
  });

export const chooseExtensionFolder = () => Native.chooseFolder();
