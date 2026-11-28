import type * as Expo from "expo-modules-core";
import { solaraCoreNativeModules, solaraCoreOptionalNativeModules } from "./solaracore";
import { shellNativeModules, shellOptionalNativeModules } from "./shell";
import { nativeEvents } from "./events";

const settingsCommands: Record<string, string> = {
  deleteHistory: "ac_history_delete_urls",
  importHistory: "ac_history_import",
  addHistoryVisits: "ac_history_add",
  applyBookmarks: "ac_bookmarks_apply",
  storeFavicon: "ac_favicons_set",
};

const liveListeners = new Map<string, (value: unknown) => void>();

export const emitBookmarkProjection = () => liveListeners.get("onBookmarkProjectionChanged")?.({});

type TestBookmarkWriter = { flushBookmarkJournal?(): Promise<boolean>; cancelBookmarkQuit?(): void; projectionDelta?(token: string | null): unknown; binding?(profileId: string): unknown; submitCompact?(...args: unknown[]): Promise<unknown>; acknowledgeReceipt?(...args: unknown[]): unknown; projection?(): unknown; reload?(): Promise<void>; state(): unknown; snapshot(profileId: string): unknown; replace(...args: unknown[]): unknown; replaceWithRecords(...args: unknown[]): unknown; submit(...args: unknown[]): Promise<unknown>; ackBookmarkFacts(...args: unknown[]): unknown; observeBookmarkRecords(...args: unknown[]): unknown; clearBookmarkFacts(...args: unknown[]): unknown; setBookmarkSyncLinks(...args: unknown[]): unknown };
const testBookmarkWriter = (): TestBookmarkWriter => {
  const writer = (globalThis as { acTestBookmarkWriter?: TestBookmarkWriter }).acTestBookmarkWriter;
  if (!writer) throw new Error("native bookmarks are not owned by this launch");
  return writer;
};

const testPanePopovers: Record<string, string> = {};
const settingsModule = {
  panePopovers: () => ({ ...testPanePopovers }),
  setPanePopover: (tabId: string, value: string | null) => {
    if (value) testPanePopovers[tabId] = value;
    else delete testPanePopovers[tabId];
    const values = { ...testPanePopovers };
    liveListeners.get("onPanePopoversChanged")?.({ values });
    return values;
  },
  get presentStoreUnavailable() {
    return (globalThis as { acTestPresentStoreUnavailable?: (detail: string) => boolean }).acTestPresentStoreUnavailable;
  },
  bookmarkWriterAPIVersion: () => 5,
  flushBookmarkJournal: async () => ((globalThis as { acTestBookmarkWriter?: TestBookmarkWriter }).acTestBookmarkWriter?.flushBookmarkJournal?.() ?? true),
  cancelBookmarkQuit: () => (globalThis as { acTestBookmarkWriter?: TestBookmarkWriter }).acTestBookmarkWriter?.cancelBookmarkQuit?.(),
  bookmarkWriterState: () => ((globalThis as { acTestBookmarkWriter?: TestBookmarkWriter }).acTestBookmarkWriter?.state() ?? { state: "legacy" }),
  bookmarkWriterSnapshot: (profileId: string) => testBookmarkWriter().snapshot(profileId),
  bookmarkWriterBinding: (profileId: string) => { const writer = testBookmarkWriter(); return writer.binding ? writer.binding(profileId) : writer.snapshot(profileId); },
  bookmarkProjectionDelta: (token: string | null) => { const writer = testBookmarkWriter(); return JSON.stringify(writer.projectionDelta ? writer.projectionDelta(token) : { token: "test-full", full: true, projection: writer.projection?.() }); },
  bookmarkProjection: () => JSON.stringify(testBookmarkWriter().projection?.()),
  reloadBookmarkProjection: async () => testBookmarkWriter().reload?.(),
  acknowledgeBookmarkReceipt: (...args: unknown[]) => testBookmarkWriter().acknowledgeReceipt?.(...args) ?? false,
  ackBookmarkFacts: async (...args: unknown[]) => testBookmarkWriter().ackBookmarkFacts(...args),
  ackBookmarkFactsForLink: async (...args: unknown[]) => testBookmarkWriter().ackBookmarkFacts(...args),
  observeBookmarkRecordsForLink: async (...args: unknown[]) => testBookmarkWriter().observeBookmarkRecords(...args),
  replaceBookmarkDocumentWithRecords: async (...args: unknown[]) => testBookmarkWriter().replaceWithRecords(...args),
  observeBookmarkRecords: async (...args: unknown[]) => testBookmarkWriter().observeBookmarkRecords(...args),
  clearBookmarkFacts: async (...args: unknown[]) => testBookmarkWriter().clearBookmarkFacts(...args),
  setBookmarkSyncLinks: async (...args: unknown[]) => testBookmarkWriter().setBookmarkSyncLinks(...args),
  replaceBookmarkDocument: async (...args: unknown[]) => testBookmarkWriter().replace(...args),
  submitBookmarkMutations: async (...args: unknown[]) => testBookmarkWriter().submit(...args),
  submitBookmarkCommands: async (...args: unknown[]) => {
    const writer = testBookmarkWriter();
    if (writer.submitCompact) return writer.submitCompact(...args);
    const { document: _document, ...receipt } = await writer.submit(...args) as Record<string, unknown>;
    return receipt;
  },
  liveInitialReplica: () => ({ revision: 0, replicaJSON: "{}" }),
  addListener: (name: string, listener: (value: unknown) => void) => {
    liveListeners.set(name, listener);
    return { remove: () => { liveListeners.delete(name); } };
  },
  liveCommand: async () => JSON.stringify({ revision: 0 }),
  libraryCommand: async (kind: string, profile: string, payload: Record<string, unknown>) => {
    const name = settingsCommands[kind];
    if (!name) throw new Error(`unknown library command ${kind}`);
    const args = kind === "importHistory"
      ? { rows: (payload.rows as { url: string; title: string; visits: number; lastVisit: number }[]).map((r) => ({ u: r.url, t: r.title, n: r.visits, l: r.lastVisit })) }
      : kind === "addHistoryVisits"
        ? { pages: (payload.pages as { url: string; title: string; visitTimes: number[] }[]).map((p) => ({ u: p.url, t: p.title, v: p.visitTimes })), toleranceMs: payload.toleranceMs }
        : payload;
    const json = await solaraCoreNativeModules.SolaraCEF.engineCall(name, profile, JSON.stringify(args));
    const result = JSON.parse(json);
    if (result?.error) throw new Error(result.error);
    return kind === "addHistoryVisits" ? result.added : result;
  },
};

const newTabEvents = nativeEvents();
const newTabModule = {
  available: () => false,
  sourceStatus: async () => ({ mode: "js-feed", ready: true, epoch: 0 }),
  addListener: newTabEvents.addListener,
  setIdleTabs: async (_json: string, _epoch: number) => {},
  setTabs: async (_profileId: string, _json: string, _epoch: number) => {},
  setEngineProfile: async (_profileId: string, _engineProfile: string, _bookmarkEngineProfile: string, _epoch: number) => {},
  setBookmarkIcons: async (_profileId: string, _engineProfile: string, _json: string) => {},
  setActions: async (_windowId: string, _json: string) => {},
  setExtensions: async (_windowId: string, _json: string) => {},
  forgetWindow: async (_windowId: string) => {},
};

export const toolbarScroll = new Set<string>();
const autoHideModule = {
  scrolledDown: (tabId: string) => toolbarScroll.has(tabId),
  sidebarToggleVisible: () => true,
  addListener: () => ({ remove: () => {} }),
};

export const displayCaptureTestState = { sharing: false };
const mediaModule = { hasDisplayTabShare: () => displayCaptureTestState.sharing };

const nativeModules: Record<string, object> = { ...shellNativeModules, ...solaraCoreNativeModules, SolaraAutoHide: autoHideModule, SolaraMedia: mediaModule, SolaraSettings: settingsModule, SolaraNewTab: newTabModule };
const optionalNativeModules: Record<string, () => object | null> = { ...shellOptionalNativeModules, ...solaraCoreOptionalNativeModules };
const testModules = () => (globalThis as { acTestNativeModules?: Record<string, object> }).acTestNativeModules;

export const requireNativeModule: typeof Expo.requireNativeModule = <Module,>(name: string) => (nativeModules[name] ?? {}) as Module;

export const requireOptionalNativeModule: typeof Expo.requireOptionalNativeModule = <Module,>(name: string) =>
  (testModules()?.[name] ?? (name in optionalNativeModules ? optionalNativeModules[name]!() : (nativeModules[name] ?? null))) as Module | null;

export const requireNativeViewManager: typeof Expo.requireNativeViewManager = () => () => null;
