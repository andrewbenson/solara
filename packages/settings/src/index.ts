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
  bookmarkWriterAPIVersion?(): number;
  bookmarkWriterState?(): BookmarkWriterState;
  bookmarkProjection?(): string;
  bookmarkProjectionDelta?(token: string | null): string;
  bookmarkWriterBinding?(profileId: string): BookmarkWriterBinding;
  submitBookmarkCommands?(profileId: string, mutationsJSON: string, engine: string, generation: string, requestId: string | null): Promise<{ engine: string; revision: string; results: string }>;
  reloadBookmarkProjection?(): Promise<void>;
  bookmarkWriterSnapshot?(profileId: string): Omit<BookmarkWriterSnapshot, "facts" | "wireBaselineKeys"> & { facts?: string; wireBaselineKeys?: string };
  acknowledgeBookmarkReceipt?(profileId: string, engine: string, generation: string, requestId: string): boolean;
  ackBookmarkFacts?(profileId: string, engine: string, recordsJSON: string, generation: string): Promise<boolean>;
  ackBookmarkFactsForLink?(profileId: string, engine: string, recordsJSON: string, link: string, generation: string): Promise<boolean>;
  observeBookmarkRecordsForLink?(profileId: string, engine: string, recordsJSON: string, link: string, generation: string): Promise<boolean>;
  replaceBookmarkDocumentWithRecords?(profileId: string, documentJSON: string, expectedRevision: string, engine: string, generation: string, requestId: string | null, recordsJSON: string, link: string): Promise<{ revision: string }>;
  observeBookmarkRecords?(profileId: string, engine: string, recordsJSON: string, generation: string): Promise<boolean>;
  clearBookmarkFacts?(profileId: string, engine: string, recordsJSON: string, generation: string): Promise<boolean>;
  setBookmarkSyncLinks?(linksJSON: string): Promise<boolean>;
  submitBookmarkMutations?(profileId: string, mutationsJSON: string, engine: string, generation: string, requestId: string | null): Promise<{ engine: string; revision: string; results: string; document: string }>;
  replaceBookmarkDocument?(profileId: string, documentJSON: string, expectedRevision: string, engine: string, generation: string, requestId: string | null): Promise<{ revision: string }>;
  flushBookmarkJournal?(): Promise<boolean>;
  cancelBookmarkQuit?(): void;
  liveCommand(name: string, payloadJSON: string): Promise<string>;
  liveStart(): Promise<void>;
  liveMeetingBrowser(snapshotJSON: string): Promise<void>;
  resolveLiveAuth(requestId: string, redirectURL: string | null, error: string | null): Promise<void>;
  devLiveSnapshot?(): Promise<LiveShadowSnapshot>;
  libraryCommand?(kind: string, engineProfile: string, payload: Record<string, unknown>): Promise<unknown>;
  reply(id: number, resultJSON: string | null, error: string | null): Promise<void>;
  publish(topic: string, json: string): Promise<void>;
  addListener(event: "onAppIntegrationPresentation", listener: (event: AppIntegrationPresentation) => void): EventSubscription;
  addListener(event: "onBookmarkProjectionChanged", listener: (event: Record<string, never>) => void): EventSubscription;
  addListener(event: "onBookmarkWriterState", listener: (state: BookmarkWriterState) => void): EventSubscription;
  addListener(event: "onSettingsCall", listener: (call: SettingsCall) => void): EventSubscription;
  addListener(event: "onLiveReplica", listener: (replica: LiveReplica) => void): EventSubscription;
  addListener(event: "onLiveAuthRequest", listener: (request: LiveAuthRequest) => void): EventSubscription;
  addListener(event: "onLiveCloseGroup", listener: (value: { groupId: string }) => void): EventSubscription;
};

export type BookmarkWriterState =
  | { state: "legacy" }
  | { state: "starting" | "stopped" | "read-only-unavailable"; reason?: string }
  | { state: "owned"; generation: string };
export type BookmarkWriterBinding = { engine: string; generation: string };
export type BookmarkEditFact = { at: number; seq: string; after: string | null; link: string };
export type BookmarkFactAck = { key: string; seq: string; mintedHLC: string };
export type BookmarkRecordObservation = { key: string; hlc: string };
export type BookmarkFactClear = { key: string; seq: string };
export type BookmarkWriterSnapshot = BookmarkWriterBinding & { revision: string; hasView?: boolean; readyForSync?: boolean; ready: boolean; document: string; wireDocument?: string; wireBaselineKeys?: string[]; facts: Record<string, BookmarkEditFact> };

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

const unavailableBookmarks = (reason: string): BookmarkWriterState => ({ state: "read-only-unavailable", reason });

function checkedBookmarkState(value: unknown): BookmarkWriterState {
  if (!value || typeof value !== "object" || !("state" in value)) return unavailableBookmarks("Invalid native bookmark ownership state");
  const state = value as BookmarkWriterState;
  if (state.state === "legacy") return unavailableBookmarks("Native bookmark ownership is required");
  if (!["starting", "owned", "read-only-unavailable", "stopped"].includes(state.state)) return unavailableBookmarks("Unknown native bookmark ownership state");
  const methods = [
    "bookmarkWriterSnapshot", "submitBookmarkMutations", "replaceBookmarkDocument", "replaceBookmarkDocumentWithRecords", "acknowledgeBookmarkReceipt",
    "ackBookmarkFacts", "ackBookmarkFactsForLink", "observeBookmarkRecords", "observeBookmarkRecordsForLink",
    "clearBookmarkFacts", "setBookmarkSyncLinks", "flushBookmarkJournal", "cancelBookmarkQuit", "bookmarkProjection", "reloadBookmarkProjection", "addListener",
  ] as const;
  if (native?.bookmarkWriterAPIVersion?.() !== 5 || !methods.every((method) => typeof native?.[method] === "function")) return unavailableBookmarks("Native bookmark API mismatch");
  if (state.state === "owned" && (typeof state.generation !== "string" || !/^[0-9]+$/.test(state.generation))) return unavailableBookmarks("Invalid native bookmark generation");
  return state;
}

export function bookmarkWriterState(): BookmarkWriterState {
  try {
    if (!native?.bookmarkWriterState) return unavailableBookmarks("Native bookmark ownership is unavailable");
    return checkedBookmarkState(native.bookmarkWriterState());
  } catch {
    return unavailableBookmarks("Native bookmark ownership is unavailable");
  }
}

export function onBookmarkWriterState(listener: (state: BookmarkWriterState) => void): EventSubscription | null {
  return native?.addListener("onBookmarkWriterState", (value) => {
    let state: BookmarkWriterState;
    try { state = checkedBookmarkState(value); }
    catch { state = unavailableBookmarks("Native bookmark ownership is unavailable"); }
    listener(state);
  }) ?? null;
}

function requireBookmarkAuthority(): void {
  if (bookmarkWriterState().state !== "owned") throw new Error("native bookmark ownership is not ready");
}

export type BookmarkProjection = {
  owner: string;
  generation: string;
  profiles: Record<string, BookmarkWriterBinding>;
  views: Record<string, { revision: string; hasView: boolean; readyForSync: boolean; document: { nodes: Record<string, { kind?: string }>; roots: Record<string, { bar: string; other: string }> } }>;
};

function requireBookmarkDisplay(): void {
  const state = bookmarkWriterState().state;
  if (state !== "owned" && state !== "read-only-unavailable") throw new Error("native bookmark display is not ready");
}

let projectionCursor: string | null = null;
let projectionCache: BookmarkProjection | null = null;

type BookmarkProjectionPatch = Omit<BookmarkProjection, "views"> & {
  views: Record<string, Omit<BookmarkProjection["views"][string], "document"> & { document?: BookmarkProjection["views"][string]["document"] & { removed?: string[] } }>;
};

export function bookmarkProjection(): BookmarkProjection {
  requireBookmarkDisplay();
  if (!native?.bookmarkProjectionDelta) {
    if (!native?.bookmarkProjection) throw new Error("native bookmark projection unavailable");
    return JSON.parse(native.bookmarkProjection()) as BookmarkProjection;
  }
  const reply = JSON.parse(native.bookmarkProjectionDelta(projectionCursor)) as { token: string; full: boolean; projection: BookmarkProjectionPatch };
  const patch = reply.projection;
  if (!patch || !reply.token) { projectionCursor = null; throw new Error("native bookmark projection is unavailable"); }
  if (reply.full) projectionCache = patch as BookmarkProjection;
  else {
    if (!projectionCache || projectionCache.owner !== patch.owner || projectionCache.generation !== patch.generation) {
      projectionCursor = null;
      throw new Error("native bookmark projection delta has no matching base");
    }
    const views: BookmarkProjection["views"] = Object.create(null);
    for (const [engine, view] of Object.entries(patch.views)) {
      const before = projectionCache.views[engine];
      if (!view.document) {
        if (!before) { projectionCursor = null; throw new Error("native bookmark projection delta is missing a document"); }
        views[engine] = { ...view, document: before.document };
      } else if (before && view.document.removed) {
        const nodes = { ...before.document.nodes, ...view.document.nodes };
        for (const id of view.document.removed) delete nodes[id];
        views[engine] = { ...view, document: { nodes, roots: view.document.roots } };
      } else views[engine] = view as BookmarkProjection["views"][string];
    }
    projectionCache = { ...patch, views };
  }
  projectionCursor = reply.token;
  return projectionCache;
}

export const onBookmarkProjectionChanged = (listener: () => void): EventSubscription =>
  native?.addListener("onBookmarkProjectionChanged", listener) ?? { remove() {} };

export const reloadBookmarkProjection = (): Promise<void> => {
  return native?.reloadBookmarkProjection?.() ?? Promise.reject(new Error("native bookmark reload unavailable"));
};

export function bookmarkWriterBinding(profileId: string): BookmarkWriterBinding {
  requireBookmarkAuthority();
  if (native?.bookmarkWriterBinding) return native.bookmarkWriterBinding(profileId);
  const snapshot = bookmarkWriterSnapshot(profileId);
  return { engine: snapshot.engine, generation: snapshot.generation };
}

export function bookmarkWriterSnapshot(profileId: string): BookmarkWriterSnapshot {
  requireBookmarkAuthority();
  if (!native?.bookmarkWriterSnapshot) throw new Error("native bookmarks are not owned by this launch");
  const snapshot = native.bookmarkWriterSnapshot(profileId);
  return { ...snapshot, facts: JSON.parse(snapshot.facts ?? "{}") as Record<string, BookmarkEditFact>, wireBaselineKeys: JSON.parse(snapshot.wireBaselineKeys ?? "[]") as string[] };
}

export async function ackBookmarkFacts(profileId: string, binding: BookmarkWriterBinding, records: BookmarkFactAck[], link?: string): Promise<boolean> {
  requireBookmarkAuthority();
  if (link !== undefined) {
    if (!native?.ackBookmarkFactsForLink) throw new Error("native bookmark link acknowledgements are unavailable");
    return native.ackBookmarkFactsForLink(profileId, binding.engine, JSON.stringify(records), link, binding.generation);
  }
  if (!native?.ackBookmarkFacts) throw new Error("native bookmarks are not owned by this launch");
  return native.ackBookmarkFacts(profileId, binding.engine, JSON.stringify(records), binding.generation);
}

export async function observeBookmarkRecords(profileId: string, binding: BookmarkWriterBinding, records: BookmarkRecordObservation[], link?: string): Promise<boolean> {
  requireBookmarkAuthority();
  if (link !== undefined) {
    if (!native?.observeBookmarkRecordsForLink) throw new Error("native bookmark link observations are unavailable");
    return native.observeBookmarkRecordsForLink(profileId, binding.engine, JSON.stringify(records), link, binding.generation);
  }
  if (!native?.observeBookmarkRecords) throw new Error("native bookmarks are not owned by this launch");
  return native.observeBookmarkRecords(profileId, binding.engine, JSON.stringify(records), binding.generation);
}

export async function clearBookmarkFacts(profileId: string, binding: BookmarkWriterBinding, records: BookmarkFactClear[]): Promise<boolean> {
  requireBookmarkAuthority();
  if (!native?.clearBookmarkFacts) throw new Error("native bookmarks are not owned by this launch");
  return native.clearBookmarkFacts(profileId, binding.engine, JSON.stringify(records), binding.generation);
}

export async function setBookmarkSyncLinks(links: Record<string, string>): Promise<boolean> {
  requireBookmarkAuthority();
  if (!native?.setBookmarkSyncLinks) throw new Error("native bookmarks are not owned by this launch");
  return native.setBookmarkSyncLinks(JSON.stringify(links));
}

export async function flushBookmarkJournal(): Promise<boolean> {
  if (!native?.bookmarkWriterState) return true;
  if (native.flushBookmarkJournal) return await native.flushBookmarkJournal();
  const state = native.bookmarkWriterState();
  return state.state === "legacy" || state.state === "stopped";
}

export function cancelBookmarkQuit(): void {
  native?.cancelBookmarkQuit?.();
}

export type BookmarkWriterReceipt = { engine: string; revision: string; results: unknown[]; document: string };

export async function submitBookmarkMutations(profileId: string, mutations: { method: string; args: unknown[] }[], binding: BookmarkWriterBinding, requestId: string | null): Promise<BookmarkWriterReceipt> {
  requireBookmarkAuthority();
  if (!native?.submitBookmarkMutations) throw new Error("native bookmarks are not owned by this launch");
  const reply = await native.submitBookmarkMutations(profileId, JSON.stringify(mutations), binding.engine, binding.generation, requestId);
  const results: unknown = JSON.parse(reply.results);
  const revision = bookmarkReceiptRevision(reply);
  if (!Array.isArray(results) || typeof reply.engine !== "string" || typeof reply.document !== "string") throw new Error("Invalid native bookmark receipt");
  acknowledgeReceivedBookmarkReceipt(profileId, binding, requestId);
  return { engine: reply.engine, revision, results, document: reply.document };
}

export type BookmarkCommandReceipt = Omit<BookmarkWriterReceipt, "document">;

export async function submitBookmarkCommands(profileId: string, mutations: { method: string; args: unknown[] }[], binding: BookmarkWriterBinding, requestId: string | null): Promise<BookmarkCommandReceipt> {
  requireBookmarkAuthority();
  const submit = native?.submitBookmarkCommands ?? native?.submitBookmarkMutations;
  if (!submit) throw new Error("native bookmarks are not owned by this launch");
  const reply = await submit.call(native, profileId, JSON.stringify(mutations), binding.engine, binding.generation, requestId);
  const results: unknown = JSON.parse(reply.results);
  const revision = bookmarkReceiptRevision(reply);
  if (!Array.isArray(results) || typeof reply.engine !== "string") throw new Error("Invalid native bookmark receipt");
  acknowledgeReceivedBookmarkReceipt(profileId, binding, requestId);
  return { engine: reply.engine, revision, results };
}

const bookmarkRequestSession = Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2);
let bookmarkRequests = 0;

export const newBookmarkRequestID = (prefix: string): string => `${prefix}-${bookmarkRequestSession}-${Date.now()}-${++bookmarkRequests}`;

function bookmarkReceiptRevision(reply: unknown): string {
  if (!reply || typeof reply !== "object" || !("revision" in reply) || typeof reply.revision !== "string" || !/^[0-9]+$/.test(reply.revision)) throw new Error("Invalid native bookmark receipt");
  return reply.revision;
}

function acknowledgeReceivedBookmarkReceipt(profileId: string, binding: BookmarkWriterBinding, requestId: string | null): void {
  if (requestId === null) return;
  try { native?.acknowledgeBookmarkReceipt?.(profileId, binding.engine, binding.generation, requestId); } catch {}
}

export const BOOKMARK_REMAP_RETRY_MS = 10_000;

export const bookmarkWriterErrorCode = (error: unknown): string | undefined =>
  error && typeof error === "object" && "code" in error && typeof error.code === "string" ? error.code : undefined;

export async function whileBookmarkEngineHolds<T>(profileId: string, binding: BookmarkWriterBinding, attempt: (binding: BookmarkWriterBinding) => T | Promise<T>, now: () => number = Date.now): Promise<T> {
  const started = now();
  for (let tries = 0; ; tries += 1) {
    try {
      return await attempt(binding);
    } catch (error) {
      if (bookmarkWriterErrorCode(error) !== "staleBinding" || now() - started >= BOOKMARK_REMAP_RETRY_MS) throw error;
      await new Promise<void>((resolve) => setTimeout(resolve, Math.min(400, 25 * 2 ** tries)));
      const current = bookmarkWriterBinding(profileId);
      if (current.engine !== binding.engine || current.generation !== binding.generation) throw error;
      binding = current;
    }
  }
}

export async function replaceBookmarkDocument(profileId: string, document: unknown, expectedRevision: string, binding: BookmarkWriterBinding, requestId: string | null = newBookmarkRequestID("bookmark-replace")): Promise<string> {
  requireBookmarkAuthority();
  const replace = native?.replaceBookmarkDocument;
  if (!replace) throw new Error("native bookmarks are not owned by this launch");
  const documentJSON = JSON.stringify(document);
  return whileBookmarkEngineHolds(profileId, binding, async (current) => {
    const revision = bookmarkReceiptRevision(await replace.call(native, profileId, documentJSON, expectedRevision, current.engine, current.generation, requestId));
    acknowledgeReceivedBookmarkReceipt(profileId, current, requestId);
    return revision;
  });
}

export async function replaceBookmarkDocumentWithRecords(profileId: string, document: unknown, expectedRevision: string, binding: BookmarkWriterBinding, records: BookmarkRecordObservation[], link: string, requestId: string | null = newBookmarkRequestID("bookmark-replace")): Promise<string> {
  requireBookmarkAuthority();
  const replace = native?.replaceBookmarkDocumentWithRecords;
  if (!replace) throw new Error("atomic native bookmark replacement is unavailable");
  const documentJSON = JSON.stringify(document);
  const recordsJSON = JSON.stringify(records);
  return whileBookmarkEngineHolds(profileId, binding, async (current) => {
    const revision = bookmarkReceiptRevision(await replace.call(native, profileId, documentJSON, expectedRevision, current.engine, current.generation, requestId, recordsJSON, link));
    acknowledgeReceivedBookmarkReceipt(profileId, current, requestId);
    return revision;
  });
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

export const nativeApplyBookmarkOps = (_engineProfile: string, _ops: LibraryBookmarkOp[]): Promise<{ applied: number; skipped: number; invalid: string[] }> =>
  Promise.reject(new Error("Raw bookmark writes are retired; use the native bookmark writer"));

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
