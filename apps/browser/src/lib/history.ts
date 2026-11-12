import { nativeSafeMode } from "../store/nativeStore";
import { onHistoryChanged, queryHistory, watchHistory, type EngineHistoryEntry, type HistoryChange } from "@solara/solaracore";
import { readDocument, readDocumentResult, removeDocument, saveDocument } from "@solara/shell";
import { nativeAddHistoryVisits, startNativeHistoryCatalog } from "@solara/settings";
import { useBrowser, type BrowserState } from "../store/browser";
import { engineProfileLoaded, onLoadedProfilesChanged, refreshLoadedProfiles } from "./lazyProfiles";
import { afterFirstWindow } from "./afterFirstWindow";
import { MAX_HISTORY, MAX_VISIT_TIMES } from "../store/history";
import { engineProfile, isIncognitoProfile } from "../store/model";
import type { HistoryEntry } from "../store/types";
import { engineIdOf } from "../store/profiles";

const LEGACY_FILE = "history.json";
const LEGACY_TOLERANCE_MS = 60_000;
const CHROME_KEEPS_MS = 90 * 86_400_000;
const CHUNK = 500;
const LEGACY_KEPT_MS = 15_000;

const store = () => useBrowser.getState();

const shownInHistory = (url: string) => /^(https?|file):/i.test(url);

const toEntry = (e: EngineHistoryEntry): HistoryEntry => ({
  url: e.url,
  title: e.title,
  favicon: null,
  visits: e.visits,
  lastVisit: e.visitTimes.length ? e.visitTimes[e.visitTimes.length - 1]! : 0,
  visitTimes: e.visitTimes,
});

const engineProfiles = (s: Pick<BrowserState, "profiles">) =>
  [...new Set(Object.keys(s.profiles).filter((id) => !isIncognitoProfile(id)).map(engineProfile))];

const profilesUsing = (s: Pick<BrowserState, "profiles">, engine: string) =>
  Object.keys(s.profiles).filter((id) => !isIncognitoProfile(id) && engineProfile(id) === engine);

function viewOf(engine: string): HistoryEntry[] {
  const s = store();
  for (const id of profilesUsing(s, engine)) if (s.history[id]) return s.history[id]!;
  return [];
}

let legacyMoved = false;
const legacyMigratedEngines = new Set<string>();

function setView(engine: string, list: HistoryEntry[], floor?: number) {
  useBrowser.setState((s) => {
    const ids = profilesUsing(s, engine);
    const was = ids.map((id) => s.historyFloor[id] ?? -Infinity).reduce((a, b) => Math.max(a, b), -Infinity);
    const full = list.length >= MAX_HISTORY ? list[list.length - 1]!.lastVisit : -Infinity;
    const next = Math.max(floor ?? was, full);
    const ready = legacyMoved || legacyMigratedEngines.has(engine);
    const sameList = ids.every((id) => s.history[id] === list);
    const sameFloor = ids.every((id) => (s.historyFloor[id] ?? -Infinity) === next);
    const sameReady = !ready || ids.every((id) => s.historyReady[id]);
    if (sameList && sameFloor && sameReady) return {};
    return {
      ...(sameList ? {} : { history: { ...s.history, ...Object.fromEntries(ids.map((id) => [id, list])) } }),
      ...(sameFloor ? {} : { historyFloor: { ...s.historyFloor, ...Object.fromEntries(ids.map((id) => [id, next])) } }),
      ...(sameReady ? {} : { historyReady: { ...s.historyReady, ...Object.fromEntries(ids.map((id) => [id, true as const])) } }),
    };
  });
}

const byLastVisit = (a: HistoryEntry, b: HistoryEntry) => b.lastVisit - a.lastVisit;

export function applyHistoryChange(list: HistoryEntry[], change: Exclude<HistoryChange, { kind: "deleted"; all: true }>): HistoryEntry[] {
  switch (change.kind) {
    case "visit": {
      if (!shownInHistory(change.url)) return list;
      const oldAt = list.findIndex((h) => h.url === change.url);
      const old = oldAt < 0 ? undefined : list[oldAt];
      if (old?.visitTimes?.includes(change.at)) return list;
      const times = [...(old?.visitTimes ?? []), change.at].sort((a, b) => a - b).slice(-MAX_VISIT_TIMES);
      const entry: HistoryEntry = {
        url: change.url,
        title: change.title || old?.title || "",
        favicon: null,
        visits: Math.max(change.visits, 1),
        lastVisit: times[times.length - 1]!,
        visitTimes: times,
      };
      const next = list.slice();
      if (old) next.splice(oldAt, 1);
      const at = next.findIndex((h) => h.lastVisit <= entry.lastVisit);
      if (at < 0) next.push(entry);
      else next.splice(at, 0, entry);
      if (next.length > MAX_HISTORY) next.length = MAX_HISTORY;
      return next;
    }
    case "modified": {
      let next: HistoryEntry[] | null = null;
      for (const row of new Map(change.rows.map((r) => [r.url, r])).values()) {
        const at = list.findIndex((h) => h.url === row.url);
        const h = at < 0 ? undefined : list[at];
        if (!h || ((row.title === h.title || !row.title) && row.visits === h.visits)) continue;
        next ??= list.slice();
        next[at] = { ...h, title: row.title || h.title, visits: row.visits };
      }
      return next ?? list;
    }
    case "deleted": {
      const gone = new Set(change.urls);
      const next = list.filter((h) => !gone.has(h.url));
      return next.length === list.length ? list : next;
    }
  }
}

type Load = { running: Promise<void>; again: boolean; queued: HistoryChange[] };
const loads = new Map<string, Load>();
const loaded = new Set<string>();
const migrating = new Set<string>();

function load(engine: string): Promise<void> {
  const running = loads.get(engine);
  if (running) {
    running.again = true;
    return running.running;
  }
  const state: Load = { running: Promise.resolve(), again: false, queued: [] };
  loads.set(engine, state);
  state.running = (async () => {
    try {
      do {
        state.again = false;
        state.queued = [];
        await watchHistory(engine);
        const read = await queryHistory(engine, MAX_HISTORY, MAX_VISIT_TIMES);
        const floor = read.length >= MAX_HISTORY ? Math.min(...read.map((e) => e.visitTimes.at(-1) ?? 0)) : -Infinity;
        let list = read.filter((e) => shownInHistory(e.url)).map(toEntry).sort(byLastVisit);
        for (const change of state.queued) if (!(change.kind === "deleted" && change.all)) list = applyHistoryChange(list, change);
        if (state.queued.some((c) => c.kind === "deleted" && c.all)) state.again = true;
        setView(engine, list, floor);
        loaded.add(engine);
      } while (state.again);
    } catch (error) {
      console.warn(`[history] couldn't read ${engine || "the default profile"}'s history`, error);
    } finally {
      loads.delete(engine);
    }
  })();
  return state.running;
}

let pending: HistoryChange[] = [];

function changed(change: HistoryChange) {
  if (!pending.length) queueMicrotask(applyPending);
  pending.push(change);
}

function applyPending() {
  const changes = pending;
  pending = [];
  const views = new Map<string, HistoryEntry[]>();
  const show = () => {
    for (const [engine, list] of views) setView(engine, list);
    views.clear();
  };
  for (const change of changes) {
    const engine = change.profile;
    if (migrating.has(engine)) continue;
    const running = loads.get(engine);
    if (running) {
      running.queued.push(change);
      continue;
    }
    if (!loaded.has(engine)) continue;
    if (change.kind === "deleted" && change.all) {
      show();
      void load(engine);
      continue;
    }
    views.set(engine, applyHistoryChange(views.get(engine) ?? viewOf(engine), change));
  }
  show();
}

type LegacyFile = { history?: Record<string, HistoryEntry[]> };
type LegacyRetirement = { aliases: Set<string>; engines: Set<string> };
type LegacyRead = { file: LegacyFile; json: string; retired: LegacyRetirement };
let legacyWork: Promise<unknown> = Promise.resolve();
let legacyRewritePending = false;
let legacyRetry: ReturnType<typeof setTimeout> | null = null;

function queueLegacy<T>(work: () => Promise<T>): Promise<T> {
  const next = legacyWork.then(work, work);
  legacyWork = next.catch(() => {});
  return next;
}

function retryLegacyRedaction() {
  if (legacyRetry) return;
  legacyRetry = setTimeout(() => {
    legacyRetry = null;
    void redactLegacyHistoryFile();
  }, 2000);
}

function retiredLegacyIds(): LegacyRetirement {
  const read = readDocumentResult("profile-data-tombstones.json");
  if ("failure" in read) throw new Error(read.failure);
  if ("missing" in read) return { aliases: new Set(), engines: new Set() };
  const value: unknown = JSON.parse(read.contents);
  const ledger = value as { deleted?: unknown; aliases?: unknown };
  const deleted = Array.isArray(value) ? value : ledger.deleted ?? [];
  const aliases = Array.isArray(value) ? [] : ledger.aliases ?? [];
  if (!Array.isArray(deleted) || !Array.isArray(aliases) || ![...deleted, ...aliases].every((id) => typeof id === "string")) throw new Error("Profile deletion history is malformed.");
  return { aliases: new Set(aliases), engines: new Set(deleted) };
}

function redactedLegacyFile(file: LegacyFile, retired: LegacyRetirement): LegacyFile {
  const live = store().profiles;
  const retiredRow = (id: string) => retired.aliases.has(id) || (!live[id] && (retired.engines.has(id) || (id === "default" && retired.engines.has(""))));
  const history = Object.fromEntries(Object.entries(file.history ?? {}).filter(([id]) => !retiredRow(id)));
  return Object.keys(history).length === Object.keys(file.history ?? {}).length ? file : { ...file, history };
}

async function readRedactedLegacy(): Promise<LegacyRead | null> {
  const read = readDocumentResult(LEGACY_FILE);
  if ("failure" in read) throw new Error(read.failure);
  if ("missing" in read) return null;
  const file = JSON.parse(read.contents) as LegacyFile;
  const retired = retiredLegacyIds();
  const next = redactedLegacyFile(file, retired);
  const json = next !== file ? JSON.stringify(next) : read.contents;
  if (next !== file || legacyRewritePending) {
    legacyRewritePending = true;
    try {
      await saveDocument(LEGACY_FILE, json);
      legacyRewritePending = false;
      if (legacyRetry) clearTimeout(legacyRetry);
      legacyRetry = null;
    } catch (error) {
      retryLegacyRedaction();
      throw error;
    }
  }
  return { file: next, json, retired };
}

function redactLegacyHistoryFile(): Promise<void> {
  return queueLegacy(async () => {
    if (nativeSafeMode()) return;
    try {
      await readRedactedLegacy();
    } catch (error) {
      console.warn(`[history] redacting ${LEGACY_FILE} failed; keeping it queued`, error);
      retryLegacyRedaction();
    }
  });
}

const legacyDropsPending = new Map<string, string>();
const legacyImportedPass = new Set<string>();
const legacyRowsOf = (sources: { profileId: string; list: HistoryEntry[] }[]) => JSON.stringify(sources.map((source) => [source.profileId, source.list]));

async function dropImportedLegacyRows(imported: Map<string, string>) {
  const current = imported.size ? await readRedactedLegacy() : null;
  const history = current?.file.history;
  const unchanged = (id: string) => imported.has(id) && JSON.stringify(history?.[id]) === imported.get(id);
  if (!history || !Object.keys(history).some(unchanged)) return;
  await saveDocument(LEGACY_FILE, JSON.stringify({ ...current!.file, history: Object.fromEntries(Object.entries(history).filter(([id]) => !unchanged(id))) }));
}

async function scheduleLegacyDrop(perEngine: Map<string, { profileId: string; list: HistoryEntry[] }[]>, engines: string[], keepMs: number) {
  if (!engines.length) return;
  const imported = new Map(engines.flatMap((engine) => perEngine.get(engine)!.map((source) => [source.profileId, JSON.stringify(source.list)] as const)));
  if (!keepMs) return dropImportedLegacyRows(imported);
  const rows = new Map(engines.map((engine) => [engine, legacyRowsOf(perEngine.get(engine)!)]));
  for (const [engine, json] of rows) legacyDropsPending.set(engine, json);
  setTimeout(() => void queueLegacy(async () => {
    try {
      if (!nativeSafeMode()) await dropImportedLegacyRows(imported);
    } catch (error) {
      console.warn(`[history] keeping migrated rows in ${LEGACY_FILE} for now`, error);
    } finally {
      for (const [engine, json] of rows) if (legacyDropsPending.get(engine) === json) legacyDropsPending.delete(engine);
    }
  }), keepMs);
}

async function moveLegacyHistory(now: number, keepMs: number): Promise<"none" | "moved" | "kept"> {
  if (nativeSafeMode()) return "kept";
  let legacy: LegacyRead | null;
  try {
    legacy = await readRedactedLegacy();
  } catch (error) {
    console.warn(`[history] ${LEGACY_FILE} cannot be safely migrated; leaving it`, error);
    return "kept";
  }
  if (!legacy) return "none";
  const source = legacy;
  const s = store();
  const perEngine = new Map<string, { profileId: string; list: HistoryEntry[] }[]>();
  for (const [profileId, list] of Object.entries(legacy.file.history ?? {})) {
    const profile = s.profiles[profileId];
    if (!profile || isIncognitoProfile(profileId) || !Array.isArray(list)) continue;
    const engine = engineIdOf(profile);
    if (legacy.retired.aliases.has(profileId) || legacy.retired.engines.has(engine)) continue;
    perEngine.set(engine, [...(perEngine.get(engine) ?? []), { profileId, list }]);
  }
  for (const engine of engineProfiles(s)) if (!perEngine.has(engine)) legacyMigratedEngines.add(engine);
  const deferred = [...perEngine.keys()].some((engine) => !engineProfileLoaded(engine));
  const importing = [...perEngine.keys()].filter((engine) => engineProfileLoaded(engine) && legacyDropsPending.get(engine) !== legacyRowsOf(perEngine.get(engine)!));
  legacyImportedPass.clear();
  for (const engine of importing) migrating.add(engine);
  try {
    for (const [engine, sources] of perEngine) {
      if (!importing.includes(engine)) continue;
      for (const { profileId, list } of sources) {
        const admitted = () => {
          const retired = retiredLegacyIds();
          const profile = store().profiles[profileId];
          return profile && engineIdOf(profile) === engine && !retired.aliases.has(profileId) && !retired.engines.has(engine);
        };
        if (!admitted()) continue;
        const pages = list
          .filter((e) => e && typeof e.url === "string")
          .map((e) => ({
            url: e.url,
            title: e.title ?? "",
            visitTimes: (e.visitTimes?.length ? e.visitTimes : [e.lastVisit]).filter((t) => typeof t === "number" && t > now - CHROME_KEEPS_MS),
          }))
          .filter((p) => p.visitTimes.length);
        for (let i = 0; i < pages.length; i += CHUNK) {
          if (!admitted()) break;
          await nativeAddHistoryVisits(engine, pages.slice(i, i + CHUNK), LEGACY_TOLERANCE_MS);
        }
        if (admitted()) { legacyMigratedEngines.add(engine); legacyImportedPass.add(engine); break; }
      }
    }
    if (deferred) await scheduleLegacyDrop(perEngine, importing.filter((engine) => legacyImportedPass.has(engine)), keepMs);
    legacy = await readRedactedLegacy();
  } catch (error) {
    console.warn(`[history] moving ${LEGACY_FILE} into Chrome failed; trying again next launch`, error);
    return "kept";
  } finally {
    for (const engine of importing) migrating.delete(engine);
  }
  if (!legacy) return "none";
  if (deferred) return "kept";
  const completed = redactedLegacyFile(source.file, legacy.retired);
  const migrated = completed === source.file ? source.json : JSON.stringify(completed);
  if (legacy.json !== migrated) return "kept";
  const removeMoved = () => queueLegacy(async () => {
    if (nativeSafeMode()) return;
    try {
      const current = await readRedactedLegacy();
      if (current?.json === migrated && !legacyRewritePending) removeDocument(LEGACY_FILE);
    } catch (error) {
      console.warn(`[history] keeping ${LEGACY_FILE} after its migration`, error);
    }
  });
  if (keepMs) setTimeout(() => void removeMoved(), keepMs);
  else {
    if (readDocument(LEGACY_FILE) === migrated && !legacyRewritePending) removeDocument(LEGACY_FILE);
  }
  return "moved";
}

export function migrateHistoryFile(now = Date.now(), { keepMs = LEGACY_KEPT_MS } = {}): Promise<"none" | "moved" | "kept"> {
  return queueLegacy(() => moveLegacyHistory(now, keepMs));
}

export function startHistory() {
  const events = onHistoryChanged(changed);
  const loadAll = (s: Pick<BrowserState, "profiles">) => {
    void startNativeHistoryCatalog(engineProfiles(s));
    for (const engine of engineProfiles(s).filter(engineProfileLoaded)) if (!loaded.has(engine) && !loads.has(engine)) void load(engine);
  };
  let moving = readDocument(LEGACY_FILE) !== null;
  let stopped = false;
  let migrationEnabled = !moving;
  let legacySettled = false;
  if (!moving) {
    loadAll(store());
    void refreshLoadedProfiles().then(() => { if (!stopped) loadAll(store()); });
  }
  const migrate = () => {
    if (stopped) return;
    migrationEnabled = true;
    void migrateHistoryFile().then((result) => {
      if (stopped) return;
      legacyMoved = result !== "kept";
      legacySettled = legacyMoved;
      if (moving) {
        moving = false;
        loadAll(store());
      } else if (result === "moved") void reloadHistory();
      else {
        loadAll(store());
        for (const engine of loaded) {
          if (legacyImportedPass.has(engine)) void load(engine);
          else setView(engine, viewOf(engine));
        }
      }
    });
  };
  if (moving) afterFirstWindow(() => { void refreshLoadedProfiles().then(migrate); });
  else migrate();
  const stopLoads = onLoadedProfilesChanged(() => {
    if (legacySettled) loadAll(store());
    else if (migrationEnabled) migrate();
  });
  const stop = useBrowser.subscribe((s, prev) => {
    if (s.profiles === prev.profiles) return;
    void redactLegacyHistoryFile();
    if (!moving) loadAll(s);
    for (const id of Object.keys(s.profiles)) {
      if (prev.profiles[id] || isIncognitoProfile(id) || s.history[id]) continue;
      const list = viewOf(engineProfile(id));
      if (list.length) setView(engineProfile(id), list);
    }
  });
  return () => {
    stopped = true;
    events.remove();
    stop();
    stopLoads();
    pending = [];
    loaded.clear();
    legacyMoved = false;
    legacyMigratedEngines.clear();
    legacyDropsPending.clear();
    legacyImportedPass.clear();
    if (legacyRetry) clearTimeout(legacyRetry);
    legacyRetry = null;
  };
}

export const reloadHistory = async () => {
  await refreshLoadedProfiles();
  return Promise.all(engineProfiles(store()).filter(engineProfileLoaded).map(load));
};
