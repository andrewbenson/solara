import { requireOptionalNativeModule, type EventSubscription } from "expo-modules-core";

type SettingsCall = { id: number; name: string; args: string };

type NativeSettingsModule = {
  available(): boolean;
  servicesActive?(): boolean;
  startAppStartup(optionsJSON: string): Promise<string>;
  completeAppStartup(): Promise<void>;
  cancelOnboardingReplay(requestId: string): Promise<void>;
  appIntegrationFirstWindow(onboardingActive: boolean): Promise<void>;
  appIntegrationNotification(action: string, tabId: string | null, windowId: string | null): Promise<void>;
  appIntegrationCommand(command: AppIntegrationCommand, windowId: string | null): Promise<void>;
  installCli?(reason: string): Promise<Record<string, unknown>>;
  navigate(pane: string | null, profileId: string | null, detail: string | null): Promise<void>;
  focusSearch(): Promise<void>;
  startHistoryCatalog?(profiles: string[]): Promise<void>;
  devHistorySnapshot?(profile: string): Promise<{ count: number; ready: boolean; floor: number | "-Infinity"; revision: number }>;
  devBookmarksSnapshot?(profile: string): Promise<{ count: number; ready: boolean; revision: number }>;
  devFaviconLookup?(page: string, engineProfile: string): Promise<{ bytes: number; source: string }>;
  liveInitialReplica(): LiveReplica;
  bookmarkWriterState?(): BookmarkWriterState;
  bookmarkWriterSnapshot?(profileId: string): BookmarkWriterSnapshot;
  replaceBookmarkDocument?(profileId: string, documentJSON: string, expectedRevision: string, engine: string, generation: string, requestId: string | null): { revision: string };
  liveCommand(name: string, payloadJSON: string): Promise<string>;
  liveStart(): Promise<void>;
  liveMeetingBrowser(snapshotJSON: string): Promise<void>;
  resolveLiveAuth(requestId: string, redirectURL: string | null, error: string | null): Promise<void>;
  devLiveSnapshot?(): Promise<LiveShadowSnapshot>;
  libraryCommand?(kind: string, engineProfile: string, payload: Record<string, unknown>): Promise<unknown>;
  reply(id: number, resultJSON: string | null, error: string | null): Promise<void>;
  publish(topic: string, json: string): Promise<void>;
  addListener(event: "onAppIntegrationPresentation", listener: (event: AppIntegrationPresentation) => void): EventSubscription;
  addListener(event: "onSettingsCall", listener: (call: SettingsCall) => void): EventSubscription;
  addListener(event: "onLiveReplica", listener: (replica: LiveReplica) => void): EventSubscription;
  addListener(event: "onLiveAuthRequest", listener: (request: LiveAuthRequest) => void): EventSubscription;
  addListener(event: "onLiveCloseGroup", listener: (value: { groupId: string }) => void): EventSubscription;
};

export type BookmarkWriterState = { state: "legacy" } | { state: "owned"; generation: string };
export type BookmarkWriterBinding = { engine: string; generation: string };
export type BookmarkWriterSnapshot = BookmarkWriterBinding & { revision: string; ready: boolean; document: string };

export type LiveReplica = { revision: number; replicaJSON: string; calendarJSON?: string; meetingAlertJSON?: string; error?: string };
export type LiveCommandResult = { revision: number; folderId?: string; deviceFlow?: { id: string; userCode: string; verificationUri: string; expiresAt: number }; boolean?: boolean };
export type LiveAuthRequest = { requestId: string; url: string; redirectPrefix: string } | { requestId: string; cancelled: "1" };

export type LiveShadowSnapshot = {
  folders: { id: string; items: number; hidden: number; completed: number; status: string | null }[];
  connectedSources: string[];
  calendar: {
    alertLead: string;
    alertCondition: string;
    showPreview: boolean;
    showTimeToNext: boolean;
    hiddenCalendarIds: string[];
    prompted: boolean;
  };
};

const native = requireOptionalNativeModule<NativeSettingsModule>("SolaraSettings");

export function nativeSettingsAvailable(): boolean {
  if (!native) return false;
  try {
    return native.available();
  } catch {
    return false;
  }
}

export function nativeServicesActive(): boolean {
  try {
    return native?.servicesActive?.() ?? false;
  } catch {
    return false;
  }
}

export const nativeInstallCli = (reason: string) =>
  native?.installCli ? native.installCli(reason) : Promise.reject(new Error("native services are off"));

export type AppIntegrationCommand = "sendFeedback" | "copyDiagnostics" | "recordPerformanceIssue" | "taskManager" | "showOnboarding" | "toolTour" | "videoTour" | "releaseNotes";

export type AppIntegrationPresentation = { action: "showOnboarding" | "toolTour" | "openURL"; windowId?: string | null; url?: string; requestId?: string };
export type AppStartupOptions = { development: boolean; persistenceRefused: boolean; safeMode: boolean; hostedOnboarding: boolean; releaseNotesVersions: string[] };
export type AppStartupResult = { pendingJSON: string | null; onboarding: "none" | "start" | "resume"; savedJSON: string | null };

export const onAppIntegrationPresentation = (listener: (event: AppIntegrationPresentation) => void): EventSubscription | null =>
  native?.addListener("onAppIntegrationPresentation", listener) ?? null;

export async function startNativeAppStartup(options: AppStartupOptions): Promise<AppStartupResult> {
  if (!native) throw new Error("native app startup unavailable");
  return JSON.parse(await native.startAppStartup(JSON.stringify(options))) as AppStartupResult;
}

export const completeNativeAppStartup = (): Promise<void> =>
  native?.completeAppStartup() ?? Promise.reject(new Error("native app startup unavailable"));

export const cancelNativeOnboardingReplay = (requestId: string): Promise<void> =>
  native?.cancelOnboardingReplay(requestId) ?? Promise.reject(new Error("native app startup unavailable"));

export const nativeAppIntegrationFirstWindow = (onboardingActive: boolean): Promise<void> =>
  native?.appIntegrationFirstWindow(onboardingActive) ?? Promise.reject(new Error("native app startup unavailable"));

export const nativeAppIntegrationNotification = (response: { action: string; tabId?: string | null; windowId?: string | null }): Promise<void> =>
  native?.appIntegrationNotification(response.action, response.tabId ?? null, response.windowId ?? null) ?? Promise.reject(new Error("native notification routing unavailable"));

export const nativeAppIntegrationCommand = (command: AppIntegrationCommand, windowId?: string | null): Promise<void> =>
  native?.appIntegrationCommand(command, windowId ?? null) ?? Promise.reject(new Error("native app integration unavailable"));

export const navigateNativeSettings = (pane: string | null, profileId: string | null, detail: string | null = null) =>
  native?.navigate(pane, profileId, detail).catch(() => {});

export const focusNativeSettingsSearch = () => native?.focusSearch().catch(() => {});

export const startNativeHistoryCatalog = (profiles: string[]) => native?.startHistoryCatalog?.(profiles).catch(() => {});

export const bookmarkWriterState = (): BookmarkWriterState => native?.bookmarkWriterState?.() ?? { state: "legacy" };

export function bookmarkWriterSnapshot(profileId: string): BookmarkWriterSnapshot {
  if (!native?.bookmarkWriterSnapshot) throw new Error("native bookmarks are not owned by this launch");
  return native.bookmarkWriterSnapshot(profileId);
}

export function replaceBookmarkDocument(profileId: string, document: unknown, expectedRevision: string, binding: BookmarkWriterBinding, requestId: string | null = null): string {
  if (!native?.replaceBookmarkDocument) throw new Error("native bookmarks are not owned by this launch");
  return native.replaceBookmarkDocument(profileId, JSON.stringify(document), expectedRevision, binding.engine, binding.generation, requestId).revision;
}

export const liveInitialReplica = (): LiveReplica => {
  if (!native) throw new Error("native Live Folders unavailable");
  return native.liveInitialReplica();
};

export const liveCommand = async (name: string, payload: Record<string, unknown> = {}): Promise<LiveCommandResult> => {
  if (!native) throw new Error("native Live Folders unavailable");
  return JSON.parse(await native.liveCommand(name, JSON.stringify(payload))) as LiveCommandResult;
};

export const liveStart = (): Promise<void> => native?.liveStart() ?? Promise.reject(new Error("native Live Folders unavailable"));
export const liveMeetingBrowser = (snapshot: unknown): Promise<void> =>
  native?.liveMeetingBrowser(JSON.stringify(snapshot)) ?? Promise.reject(new Error("native Live Folders unavailable"));
export const onLiveCloseGroup = (listener: (groupId: string) => void): EventSubscription | null =>
  native?.addListener?.("onLiveCloseGroup", ({ groupId }) => listener(groupId)) ?? null;
export const onLiveReplica = (listener: (replica: LiveReplica) => void): EventSubscription | null => native?.addListener?.("onLiveReplica", listener) ?? null;
export const onLiveAuthRequest = (listener: (request: LiveAuthRequest) => void): EventSubscription | null => native?.addListener?.("onLiveAuthRequest", listener) ?? null;
export const resolveLiveAuth = (requestId: string, redirectURL: string | null, error: string | null): Promise<void> =>
  native?.resolveLiveAuth(requestId, redirectURL, error) ?? Promise.reject(new Error("native Live Folders unavailable"));

export const devLiveSnapshot = () => native?.devLiveSnapshot?.();

export const devNativeHistorySnapshot = (profile: string) => native?.devHistorySnapshot?.(profile);

export const devNativeBookmarksSnapshot = (profile: string) => native?.devBookmarksSnapshot?.(profile);

export const devFaviconLookup = (page: string, engineProfile: string) => native?.devFaviconLookup?.(page, engineProfile);

const libraryCommand = <T>(kind: string, engineProfile: string, payload: Record<string, unknown>): Promise<T> =>
  native?.libraryCommand ? native.libraryCommand(kind, engineProfile, payload) as Promise<T> : Promise.reject(new Error("native library commands unavailable"));

export const nativeDeleteHistoryUrls = (engineProfile: string, urls: string[]): Promise<void> =>
  urls.length ? libraryCommand("deleteHistory", engineProfile, { urls }) : Promise.resolve();

export const nativeImportHistoryRows = (engineProfile: string, rows: { url: string; title: string; visits: number; lastVisit: number }[]): Promise<void> =>
  rows.length ? libraryCommand("importHistory", engineProfile, { rows }) : Promise.resolve();

const addingHistory = new Map<string, Promise<unknown>>();

export function nativeAddHistoryVisits(engineProfile: string, pages: { url: string; title: string; visitTimes: number[] }[], toleranceMs = 1000): Promise<number> {
  if (!pages.length) return Promise.resolve(0);
  const run = (addingHistory.get(engineProfile) ?? Promise.resolve())
    .catch(() => {})
    .then(() => libraryCommand<number>("addHistoryVisits", engineProfile, { pages, toleranceMs }));
  addingHistory.set(engineProfile, run);
  return run;
}

export type LibraryBookmarkOp =
  | { op: "add"; id: string; k: "u" | "f"; t: string; u?: string; a: number; key?: string; parent: string; index?: number; ifAbsent?: boolean }
  | { op: "move"; id: string; parent: string; index: number }
  | { op: "update"; id: string; t?: string; u?: string }
  | { op: "remove"; id: string };

export const nativeApplyBookmarkOps = (engineProfile: string, ops: LibraryBookmarkOp[]): Promise<{ applied: number; skipped: number; invalid: string[] }> =>
  libraryCommand("applyBookmarks", engineProfile, { ops });

export const nativeStoreFavicon = (engineProfile: string, page: string, icon: string, png: string): Promise<void> =>
  libraryCommand("storeFavicon", engineProfile, { page, icon, png });

export const publishSettingsTopic = (topic: string, value: unknown) =>
  native?.publish(topic, JSON.stringify(value ?? null)).catch(() => {});

export type SettingsHandler = (...args: never[]) => unknown;

export function serveNativeSettings(handlers: Record<string, SettingsHandler>): EventSubscription | null {
  if (!native) return null;
  return native.addListener("onSettingsCall", ({ id, name, args }) => {
    const handler = handlers[name];
    if (!handler) return void native.reply(id, null, `no Settings handler for ${name}`).catch(() => {});
    let parsed: never[];
    try {
      parsed = JSON.parse(args) as never[];
    } catch {
      return void native.reply(id, null, `bad arguments for ${name}`).catch(() => {});
    }
    Promise.resolve()
      .then(() => handler(...parsed))
      .then(
        (result) => native.reply(id, result === undefined ? null : JSON.stringify(result), null),
        (error: unknown) => native.reply(id, null, error instanceof Error ? error.message : String(error)),
      )
      .catch(() => {});
  });
}
export * from "./newTab";
export * from "./hosted";
export * from "./omnibox";
export * from "./toolbar";
export * from "./findBar";
export * from "./downloads";
export * from "./prompt";
export * from "./sitePanel";
export * from "./windowShell";
export * from "./tabPool";
export * from "./profilePager";
export * from "./littleSolara";
export * from "./cliIndicator";
export * from "./topStrip";
export * from "./pages";
