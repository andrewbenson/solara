import type * as Expo from "expo-modules-core";
import { solaraCoreNativeModules, solaraCoreOptionalNativeModules } from "./solaracore";
import { shellNativeModules, shellOptionalNativeModules } from "./shell";
import { nativeEvents } from "./events";
import type { LiveFolder } from "../live/types";

const settingsCommands: Record<string, string> = {
  deleteHistory: "ac_history_delete_urls",
  importHistory: "ac_history_import",
  addHistoryVisits: "ac_history_add",
  applyBookmarks: "ac_bookmarks_apply",
  storeFavicon: "ac_favicons_set",
};

const testLive = { folders: {} as Record<string, LiveFolder>, folderOrder: [] as string[] };
const liveListeners = new Map<string, (value: unknown) => void>();
let liveRevision = 0;
let liveCounter = 0;
const publishLive = () => liveListeners.get("onLiveReplica")?.({ revision: ++liveRevision, replicaJSON: JSON.stringify(testLive) });

export const emitBookmarkProjection = () => liveListeners.get("onBookmarkProjectionChanged")?.({});

type TestBookmarkWriter = { projection?(): unknown; reload?(): Promise<void>; state(): unknown; snapshot(profileId: string): unknown; replace(...args: unknown[]): unknown; replaceWithRecords(...args: unknown[]): unknown; submit(...args: unknown[]): Promise<unknown>; ackBookmarkFacts(...args: unknown[]): unknown; observeBookmarkRecords(...args: unknown[]): unknown; clearBookmarkFacts(...args: unknown[]): unknown; setBookmarkSyncLinks(...args: unknown[]): unknown };
const testBookmarkWriter = (): TestBookmarkWriter => {
  const writer = (globalThis as { acTestBookmarkWriter?: TestBookmarkWriter }).acTestBookmarkWriter;
  if (!writer) throw new Error("native bookmarks are not owned by this launch");
  return writer;
};

const settingsModule = {
  bookmarkWriterAPIVersion: () => 3,
  bookmarkWriterState: () => ((globalThis as { acTestBookmarkWriter?: TestBookmarkWriter }).acTestBookmarkWriter?.state() ?? { state: "legacy" }),
  bookmarkWriterSnapshot: (profileId: string) => testBookmarkWriter().snapshot(profileId),
  bookmarkProjection: () => JSON.stringify(testBookmarkWriter().projection?.()),
  reloadBookmarkProjection: async () => testBookmarkWriter().reload?.(),
  ackBookmarkFacts: (...args: unknown[]) => testBookmarkWriter().ackBookmarkFacts(...args),
  ackBookmarkFactsForLink: (...args: unknown[]) => testBookmarkWriter().ackBookmarkFacts(...args),
  observeBookmarkRecordsForLink: (...args: unknown[]) => testBookmarkWriter().observeBookmarkRecords(...args),
  replaceBookmarkDocumentWithRecords: (...args: unknown[]) => testBookmarkWriter().replaceWithRecords(...args),
  observeBookmarkRecords: (...args: unknown[]) => testBookmarkWriter().observeBookmarkRecords(...args),
  clearBookmarkFacts: (...args: unknown[]) => testBookmarkWriter().clearBookmarkFacts(...args),
  setBookmarkSyncLinks: (...args: unknown[]) => testBookmarkWriter().setBookmarkSyncLinks(...args),
  replaceBookmarkDocument: (...args: unknown[]) => testBookmarkWriter().replace(...args),
  submitBookmarkMutations: async (...args: unknown[]) => testBookmarkWriter().submit(...args),
  liveInitialReplica: () => ({ revision: liveRevision, replicaJSON: JSON.stringify(testLive) }),
  addListener: (name: string, listener: (value: unknown) => void) => {
    liveListeners.set(name, listener);
    return { remove: () => { liveListeners.delete(name); } };
  },
  liveStart: async () => {},
  resolveLiveAuth: async () => {},
  liveCommand: async (name: string, payloadJSON: string) => {
    const payload = JSON.parse(payloadJSON) as Record<string, any>;
    let folderId: string | undefined;
    if (name === "createFolder" || name === "newProfileLiveFolder" || name === "importFolder") {
      folderId = `lf-test-${++liveCounter}`;
      testLive.folders[folderId] = {
        id: folderId, profileId: payload.profileId, kind: payload.kind, name: payload.kind === "pullRequests" ? "Pull Requests" : "Documents",
        icon: null, collapsed: false, sources: payload.sources ?? ["github"], filters: { authored: true, reviewRequests: true },
        groupStacks: true, showCompleted: true, createdAt: Date.now(),
      };
      testLive.folderOrder.push(folderId);
    } else if (name === "updateFolder") {
      const folder = testLive.folders[payload.folderId];
      if (folder) testLive.folders[payload.folderId] = { ...folder, ...payload.patch };
    } else if (name === "removeFolder") {
      delete testLive.folders[payload.folderId];
      testLive.folderOrder = testLive.folderOrder.filter((id) => id !== payload.folderId);
    } else if (name === "arrangeFolders") {
      const placed = payload.placed as { id: string; after: string | null }[];
      const ids = placed.map((entry) => entry.id).filter((id) => testLive.folders[id]);
      for (const entry of placed) {
        const folder = testLive.folders[entry.id];
        if (folder) testLive.folders[entry.id] = { ...folder, after: entry.after };
      }
      const slots = testLive.folderOrder.flatMap((id, index) => ids.includes(id) ? [index] : []);
      for (const [index, slot] of slots.entries()) testLive.folderOrder[slot] = ids[index]!;
    }
    publishLive();
    return JSON.stringify({ revision: liveRevision, folderId });
  },
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

const nativeModules: Record<string, object> = { ...shellNativeModules, ...solaraCoreNativeModules, SolaraSettings: settingsModule, SolaraNewTab: newTabModule };
const optionalNativeModules: Record<string, () => object | null> = { ...shellOptionalNativeModules, ...solaraCoreOptionalNativeModules };
const testModules = () => (globalThis as { acTestNativeModules?: Record<string, object> }).acTestNativeModules;

export const requireNativeModule: typeof Expo.requireNativeModule = <Module,>(name: string) => (nativeModules[name] ?? {}) as Module;

export const requireOptionalNativeModule: typeof Expo.requireOptionalNativeModule = <Module,>(name: string) =>
  (testModules()?.[name] ?? (name in optionalNativeModules ? optionalNativeModules[name]!() : (nativeModules[name] ?? null))) as Module | null;

export const requireNativeViewManager: typeof Expo.requireNativeViewManager = () => () => null;
