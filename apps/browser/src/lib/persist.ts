import { cancelDownload, endWebKitPrivateSession, leftDownloadStaging, removeLeftDownloadStaging, type Download } from "@solara/solaracore";
import { readDocumentResult, writeDocument, type DocumentRead } from "@solara/shell";
import { showNotice, showToast } from "../components/layout/toasts";
import { persistenceRefused, refusePersistence } from "./persistLatch";
import { useBrowser, type BrowserState, type HydrateData } from "../store/browser";
import { inPinnedContainer, isIncognitoProfile, newId, privateSession, snapshotTab } from "../store/model";
import { earlyLaunchTabOn, launchTab, linkProfile, type LaunchTab } from "../store/launchTab";
import { launchBackdrop, type LaunchBackdrop } from "./launchBackdrop";
import { restoreLaunchLook, saveLaunchLook } from "./launchLook";
import { parkWindowPins } from "../store/parkedPins";
import { isPeekTab } from "../store/peek";
import type { BrowserWindow, ClosedTab, Tab } from "../store/types";
import { downloadSession } from "../store/ui";
import { startFavicons } from "./favicons";
import { startBookmarks } from "./bookmarks";
import { startHistory } from "./history";
import { startProfileDataCleanup } from "./profileData";
import { flushNativeStore, flushProblem } from "@solara/store";
import {
  adoptRepairs,
  attachReplica,
  dataFolderHandedOff,
  hydrateFromNative,
  nativeOwnedSnapshot,
  nativeRefusedSession,
  nativeSafeMode,
  nativeSafeModeAfterFailedLaunches,
  nativeOwnsWorkspace,
  nativeStoreActive,
  nativeStoreRev,
  standDown,
  startNativeStore,
  withApplier,
} from "../store/nativeStore";
import type { StoreCommand } from "@solara/store";
import { journalAnchor, journalVersion, onJournalChange } from "../sync/journalHost";

const SAVE_DELAY_MS = 800;
const VERSION = 2;

type Doc = { name: string; sources: (s: BrowserState) => unknown[]; json: (s: BrowserState) => string };

const serialized =
  (serialize: (s: BrowserState) => unknown) =>
  (s: BrowserState): string =>
    JSON.stringify(serialize(s));

const persistedTab = ({ navigation: _n, adoptId: _a, wakeAdoptId, pageIn, ...tab }: Tab) => {
  const t = pageIn ? { ...tab, unloaded: true as const } : tab;
  return wakeAdoptId?.startsWith("restore:") && !isIncognitoProfile(t.profileId) ? { ...t, wakeAdoptId } : t;
};
const publicTab = (t: { profileId: string }) => !isIncognitoProfile(t.profileId);

const DOCS: Doc[] = [
  {
    name: "downloads.json",
    sources: (s) => [s.downloads],
    json: serialized((s) => ({
      version: VERSION,
      downloads: s.downloads
        .filter((d) => downloadSession(d) === null)
        .map((d) => (d.state === "downloading" ? { ...d, state: "failed" } : d)),
    })),
  },
  {
    name: "session.json",
    sources: (s) => [journalVersion(), s.profiles, s.profileOrder, s.orphanedProfileData, s.windows, s.windowOrder, s.tabs, s.groups, s.splits, s.closedTabs, s.closedWindows, s.parkedPins, s.pinChoices, s.pinSync, s.settings, s.ui.focusedWindowId, s.ui.lastProfileId, s.ui.appDark, s.closedGroups, s.deletedGroups, s.cleanedTabs],
    json: serialized((s) => {
      const document = sessionDocument(s);
      return nativeStoreActive() ? { ...document, nativeExport: { rev: nativeStoreRev(), at: Date.now(), scope: "settingsAndDownloads" } } : document;
    }),
  },
];

const sessionDocument = (s: BrowserState) => {
  const windows = Object.values(s.windows).filter((w) => !w.incognito && w.kind !== "small").map(({ chromeWindow: _c, ...w }) => w);
  const kept = new Set(windows.map((w) => w.id));
  const focusedWindowId = s.ui.focusOrder.find((id) => kept.has(id)) ?? null;
  return {
    version: VERSION,
    profiles: s.profiles,
    profileOrder: s.profileOrder,
    orphanedProfileData: s.orphanedProfileData,
    settings: s.settings,
    windows,
    windowOrder: s.windowOrder.filter((id) => kept.has(id)),
    focusedWindowId,
    lastProfileId: s.ui.lastProfileId,
    launchTab: earlyLaunchTabOn() ? launchTab(s, focusedWindowId) : null,
    launchBackdrop: earlyLaunchTabOn() ? launchBackdrop(s, focusedWindowId) : null,
    linkProfile: earlyLaunchTabOn() ? linkProfile(s) : null,
    tabs: Object.values(s.tabs).filter((t) => kept.has(t.windowId) && !isPeekTab(s, t.id)).map(persistedTab),
    groups: Object.values(s.groups).filter((g) => kept.has(g.windowId)),
    splits: Object.values(s.splits).filter((v) => kept.has(v.windowId)),
    closedTabs: s.closedTabs.filter((c) => publicTab(c.tab)),
    closedWindows: s.closedWindows.filter((c) => c.tabs.every(publicTab)),
    parkedPins: Object.fromEntries(Object.entries(s.parkedPins).filter(([profileId]) => publicTab({ profileId }))),
    pinChoices: Object.fromEntries(Object.entries(s.pinChoices).filter(([profileId]) => publicTab({ profileId }))),
    pinSync: Object.fromEntries(Object.entries(s.pinSync).filter(([profileId]) => publicTab({ profileId }))),
    closedGroups: s.closedGroups.filter((c) => c.tabs.every(publicTab)),
    deletedGroups: s.deletedGroups.filter((c) => c.tabs.every(publicTab)),
    cleanedTabs: s.cleanedTabs.filter((c) => publicTab(c.tab)),
    ...journalAnchor(),
  };
};

const unreadableDocs = new Set<string>();
const docsToWrite = () =>
  (nativeOwnsWorkspace() ? [] : nativeStoreActive() ? DOCS.filter((d) => d.name !== "downloads.json") : DOCS)
    .filter((d) => !unreadableDocs.has(d.name) && !(nativeSafeMode() && d.name === "session.json"));

function nativeCaches(s: BrowserState): StoreCommand[] {
  const playing = Object.keys(s.live).filter((id) => s.live[id]?.playingAudio);
  return [{ name: "setPlayingAudio", args: [playing] }];
}

function parsed<T>(name: string, read: DocumentRead | null): T | null {
  if (!read || !("contents" in read) || !read.contents) return null;
  try {
    return JSON.parse(read.contents) as T;
  } catch (error) {
    console.warn(`Couldn't read ${name}`, error);
    return null;
  }
}

function write(name: string, json: string) {
  try {
    writeDocument(name, json);
  } catch (error) {
    console.warn(`Couldn't save ${name}`, error);
  }
}

const byId = <T extends { id: string }>(list: T[] | undefined) => Object.fromEntries((list ?? []).map((x) => [x.id, x]));

type SessionV2 = {
  version: 2;
  profiles: HydrateData["profiles"];
  profileOrder: string[];
  orphanedProfileData?: string[];
  settings: HydrateData["settings"];
  windows: BrowserWindow[];
  windowOrder: string[];
  focusedWindowId: string | null;
  lastProfileId?: string | null;
  tabs: Tab[];
  groups: BrowserState["groups"][string][];
  splits: BrowserState["splits"][string][];
  closedTabs: ClosedTab[];
  closedWindows: BrowserState["closedWindows"];
  parkedPins?: BrowserState["parkedPins"];
  pinChoices?: BrowserState["pinChoices"];
  pinSync?: BrowserState["pinSync"];
  closedGroups?: BrowserState["closedGroups"];
  deletedGroups?: BrowserState["deletedGroups"];
  cleanedTabs?: BrowserState["cleanedTabs"];
  launchTab?: LaunchTab | null;
  launchBackdrop?: LaunchBackdrop | null;
  linkProfile?: string | null;
};

let droppedPrivateDownloads = false;

function forgetStaging(id: string) {
  const s = useBrowser.getState();
  const download = s.downloads.find((d) => d.id === id);
  if (!download) return;
  const { staging: _, stagingId: _id, destination: _to, ...kept } = download;
  s.upsertDownload(kept);
}

function cleanStaging(downloads: Download[]) {
  for (const d of downloads) if (d.stagingId) void removeLeftDownloadStaging(d).then((removed) => removed && forgetStaging(d.id));
}

export function loadSession(
  sessionRead: DocumentRead = readDocumentResult("session.json"),
  downloadsRead: DocumentRead | null = readDocumentResult("downloads.json"),
): HydrateData | null {
  const session = parsed<SessionV2>("session.json", sessionRead);
  if (session?.version !== 2) return null;
  const downloads = parsed<{ downloads: Download[] }>("downloads.json", downloadsRead);
  droppedPrivateDownloads = (downloads?.downloads ?? []).some((d) => downloadSession(d) !== null);
  const data: HydrateData = {
    profiles: session.profiles,
    profileOrder: session.profileOrder,
    orphanedProfileData: session.orphanedProfileData ?? [],
    settings: session.settings,
    windows: byId(session.windows),
    windowOrder: session.windowOrder,
    focusedWindowId: session.focusedWindowId,
    lastProfileId: session.lastProfileId ?? null,
    tabs: byId(session.tabs),
    groups: byId(session.groups),
    splits: byId(session.splits),
    closedTabs: session.closedTabs,
    closedWindows: session.closedWindows,
    parkedPins: session.parkedPins ?? {},
    pinChoices: session.pinChoices ?? {},
    pinSync: session.pinSync ?? {},
    closedGroups: session.closedGroups ?? [],
    deletedGroups: session.deletedGroups ?? [],
    cleanedTabs: session.cleanedTabs ?? [],
    downloads: (downloads?.downloads ?? []).filter((d) => downloadSession(d) === null).map((d, i) => {
      const id = `saved-${i}`;
      const left = leftDownloadStaging(d);
      const { staging: _, stagingId: _id, destination: _to, ...kept } = d;
      if (!left) return { ...kept, id };
      void removeLeftDownloadStaging(d).then((removed) => removed && forgetStaging(id));
      return { ...d, id, stagingId: left.uuid };
    }),
  };
  if (session.settings && session.settings.restoreSession === false) {
    const now = Date.now();
    const pinSource = { tabs: data.tabs ?? {}, groups: data.groups ?? {}, splits: data.splits ?? {}, history: {} };
    for (const w of session.windows) data.parkedPins = parkWindowPins(data.parkedPins ?? {}, w, pinSource);
    data.closedWindows = [
      ...(data.closedWindows ?? []),
      ...session.windows.map((w) => ({
        kind: "window" as const,
        id: newId("cw"),
        window: { profileId: w.profileId, sidebarOpen: w.sidebarOpen, frame: w.frame },
        tabs: w.tabIds
          .map((id) => data.tabs?.[id])
          .filter((t): t is Tab => !!t && !inPinnedContainer(pinSource, t.id))
          .map((t) => ({ ...snapshotTab(t), active: Object.values(w.activeTabIds).includes(t.id) })),
        groups: [],
        closedAt: now,
      })).filter((c) => c.tabs.some((t) => t.url)),
    ].slice(-10);
    data.windows = {};
    data.windowOrder = [];
    data.tabs = {};
  }
  return data;
}

let flush: () => void = () => {};
let resume: () => void = () => {};
let frozen = false;

export function flushPersistence({ final = false } = {}) {
  flush();
  if (final || nativeOwnsWorkspace()) {
    const result = flushNativeStore();
    if (final && flushProblem(result)) console.warn("Native store quit flush:", result);
  }
  if (final && !frozen && !persistenceRefused() && !nativeSafeMode()) saveLaunchLook(useBrowser.getState());
  if (final) frozen = true;
}

export function resumePersistence() {
  if (persistenceRefused()) return;
  frozen = false;
  resume();
}

export function startPersistence() {
  const store = startNativeStore();
  if (dataFolderHandedOff()) {
    frozen = true;
    console.warn("Another instance is using this data folder; this one saves nothing.");
    return () => {};
  }
  const refused = nativeRefusedSession();
  if (refused && !nativeSafeMode()) return refuseToSave(refused, readDocumentResult("session.json"));
  if (!store.active && store.modulePresent) return failClosed(store.reason);
  if (nativeOwnsWorkspace()) {
    if (!hydrateFromNative(useBrowser)) return failClosed();
    attachReplica(useBrowser, nativeCaches);
    if (!nativeSafeMode()) restoreLaunchLook();
    cleanStaging(useBrowser.getState().downloads);
    tellSafeModeAfterFailedLaunches();
    return startDerivedServices({ forgetsIncognito: false });
  }
  const owned = nativeOwnedSnapshot();
  const sessionRead: DocumentRead = nativeSafeMode() ? { missing: true } : readDocumentResult("session.json");
  if ("failure" in sessionRead) return refuseToSave(sessionRead.path, sessionRead);
  const downloadsRead = owned ? null : readDocumentResult("downloads.json");
  if (downloadsRead && "failure" in downloadsRead) {
    unreadableDocs.add("downloads.json");
    console.error(`Couldn't read ${downloadsRead.path} (${downloadsRead.failure}), so this launch leaves it as it is.`);
  }
  const data = nativeSafeMode() ? {} : (loadSession(sessionRead, downloadsRead) ?? {});
  if (owned) {
    data.settings = owned.settings;
    data.downloads = owned.downloads;
    droppedPrivateDownloads = false;
  }
  withApplier(() => useBrowser.getState().hydrate(data));
  if (owned) {
    attachReplica(useBrowser);
    adoptRepairs(useBrowser.getState(), owned);
    cleanStaging(useBrowser.getState().downloads);
  }
  if (!nativeSafeMode()) restoreLaunchLook();
  tellSafeModeAfterFailedLaunches();

  const lastSources = new Map<string, unknown[]>();
  const lastJson = new Map<string, string>();
  const dirty = new Set<Doc>();
  let timer: ReturnType<typeof setTimeout> | undefined;

  const save = () => {
    clearTimeout(timer);
    timer = undefined;
    if (frozen) return;
    const s = useBrowser.getState();
    for (const doc of docsToWrite().filter((d) => dirty.has(d))) {
      const json = doc.json(s);
      if (lastJson.get(doc.name) !== json) {
        lastJson.set(doc.name, json);
        write(doc.name, json);
      }
    }
    dirty.clear();
  };
  flush = save;

  const check = (s: BrowserState, initial = false) => {
    if (frozen) return;
    for (const doc of DOCS) {
      const sources = doc.sources(s);
      const prev = lastSources.get(doc.name);
      if (prev && sources.every((v, i) => v === prev[i])) continue;
      lastSources.set(doc.name, sources);
      if (!initial) dirty.add(doc);
    }
    if (dirty.size && !timer) timer = setTimeout(save, SAVE_DELAY_MS);
  };
  check(useBrowser.getState(), true);
  if (droppedPrivateDownloads) {
    droppedPrivateDownloads = false;
    dirty.add(DOCS.find((d) => d.name === "downloads.json")!);
    timer ??= setTimeout(save, SAVE_DELAY_MS);
  }
  resume = () => {
    check(useBrowser.getState());
    save();
  };
  const stopServices = startDerivedServices({ forgetsIncognito: true });
  const stopSession = useBrowser.subscribe((s) => check(s));
  const stopJournal = onJournalChange(() => check(useBrowser.getState()));
  return () => {
    stopServices();
    stopSession();
    stopJournal();
  };
}

function tellSafeModeAfterFailedLaunches() {
  if (!nativeSafeModeAfterFailedLaunches()) return;
  const tell = (s: BrowserState) => {
    const publicWindow = (id: string) => s.windows[id] && !s.windows[id].incognito && s.windows[id].kind !== "small";
    const windowId = s.ui.focusOrder.find(publicWindow) ?? s.windowOrder.find(publicWindow);
    if (!windowId) return false;
    showToast(windowId, "Solara started in safe mode", "Your tabs are kept and come back the next time it opens normally.", {
      icon: "shield", sticky: true, key: "safe-mode", action: { title: "OK", run: () => {} },
    });
    return true;
  };
  if (tell(useBrowser.getState())) return;
  const stop = useBrowser.subscribe((s) => {
    if (tell(s)) stop();
  });
}

function refuseToSave(sessionPath: string, sessionRead: DocumentRead) {
  refusePersistence(sessionPath);
  frozen = true;
  withApplier(() => useBrowser.getState().hydrate(nativeSafeMode() ? {} : (loadSession(sessionRead, null) ?? {})));
  const title = "Solara couldn't read its saved session";
  const message = `Changes in this window won't be saved. The saved session is at ${sessionPath}.`;
  console.error(`${title}. ${message}`);
  const told = new Set<string>();
  const tell = (s: BrowserState) => {
    for (const windowId of s.windowOrder) {
      if (told.has(windowId)) continue;
      told.add(windowId);
      showNotice(windowId, title, message, "exclamationmark.triangle");
    }
  };
  tell(useBrowser.getState());
  return useBrowser.subscribe(tell);
}

function failClosed(reason?: string) {
  frozen = true;
  standDown();
  const message = reason
    ? `The native store could not open (${reason}), so this window saves nothing. Quit and relaunch; your data is unchanged.`
    : "The native store opened but returned no workspace, so this window saves nothing. Quit and relaunch; your data is unchanged.";
  console.error(message);
  try {
    (require("react-native") as typeof import("react-native")).Alert?.alert?.("Your tabs couldn't load", message);
  } catch {}
  return () => {};
}

function startDerivedServices({ forgetsIncognito }: { forgetsIncognito: boolean }) {
  const stopFavicons = startFavicons();
  const stopHistory = startHistory();
  const stopBookmarks = startBookmarks();
  const stopProfileData = startProfileDataCleanup();
  const stopIncognito = forgetsIncognito
    ? useBrowser.subscribe((s, prev) => {
        if (s.windows !== prev.windows) forgetClosedIncognito(s, prev);
      })
    : () => {};
  return () => {
    stopFavicons();
    stopHistory();
    stopBookmarks();
    stopProfileData();
    stopIncognito();
  };
}

function forgetClosedIncognito(s: BrowserState, prev: BrowserState) {
  for (const w of Object.values(prev.windows)) {
    if (!w.incognito || s.windows[w.id]) continue;
    const session = privateSession(w.profileId);
    if (Object.values(s.windows).some((o) => o.incognito && privateSession(o.profileId) === session)) continue;
    for (const d of s.downloads) if (downloadSession(d) === session && d.state === "downloading") void cancelDownload(d.id);
    s.forgetDownloads(w.profileId);
    if (session !== null) void endWebKitPrivateSession(session);
  }
}
