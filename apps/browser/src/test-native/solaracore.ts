import type {
  ActionState,
  SolaraCoreNativeModules,
  SolaraCoreOptionalNativeModules,
  BookmarkOp,
  CliControlStatus,
  EngineBookmark,
  HistoryChange,
  LinkRoute,
  TabStripCommand,
  TabStripTransaction,
} from "@solara/solaracore";
import type { EventSubscription } from "expo-modules-core";
import { nativeEvents, unfaked } from "./events";

type Modules = SolaraCoreNativeModules;
type OptionalModules = { [Name in keyof SolaraCoreOptionalNativeModules]: () => SolaraCoreOptionalNativeModules[Name] | null };

type TabStripHost = {
  listen(listener: (tx: TabStripTransaction) => void): EventSubscription;
  command(command: TabStripCommand, id: number): unknown;
  snapshot(): Promise<TabStripTransaction>;
};
type EngineArgs = Record<string, unknown> | undefined;

const testGlobals = globalThis as {
  acTestEngineCall?: (name: string, profile: string, args: EngineArgs) => unknown;
  acTestTabStrip?: TabStripHost;
  acTestCliControl?: (on: boolean | null) => Promise<CliControlStatus> | undefined;
  acTestCliActive?: (chromeTabId: number) => Promise<CliControlStatus> | undefined;
};

const cefEvents = nativeEvents();
export const engineEvent = (topic: string, payload: object) => cefEvents.emit("onEngineEvent", { topic, payload: JSON.stringify(payload) });
const laterEngineEvent = (topic: string, payload: object) => queueMicrotask(() => engineEvent(topic, payload));
export const emitDownload = (download: object) => cefEvents.emit("onDownload", download);
export const emitPermission = (request: object) => cefEvents.emit("onPermission", request);

export const current = { device: null as string | null };

type Login = { origin: string; url: string; username: string; password: string; created: number };
export const passwordStores = new Map<string | null, Map<string, Login>>();
const logins = () => passwordStores.get(current.device)!;
export const readLogins = async () => [...logins().values()];

type HistoryRow = { title: string; visits: number[] };
export const historyDbs = new Map<string | null, Map<string, Map<string, HistoryRow>>>();
export const chromeHistory = (profile = "", device = current.device) => {
  if (!historyDbs.has(device)) historyDbs.set(device, new Map());
  const dbs = historyDbs.get(device)!;
  if (!dbs.has(profile)) dbs.set(profile, new Map());
  return dbs.get(profile)!;
};
export const historyWatches: string[] = [];

export function chromeHistoryEvent(change: HistoryChange) {
  const { profile } = change;
  if (change.kind === "visit")
    laterEngineEvent("history.changed", { profile, kind: "visit", u: change.url, t: change.title, n: change.visits, at: change.at });
  else if (change.kind === "modified")
    laterEngineEvent("history.changed", { profile, kind: "modified", rows: change.rows.map((r) => ({ u: r.url, t: r.title, n: r.visits })) });
  else laterEngineEvent("history.changed", { profile, kind: "deleted", all: change.all, urls: change.urls });
}

function addVisit(profile: string, url: string, title: string, at: number) {
  const db = chromeHistory(profile);
  const row = db.get(url) ?? { title: "", visits: [] };
  row.visits = [...row.visits, at].sort((a, b) => a - b);
  if (title) row.title = title;
  db.set(url, row);
  chromeHistoryEvent({ kind: "visit", profile, url, title: row.title, visits: row.visits.length, at });
}
export const chromeVisit = (profile: string, url: string, title: string, at = Date.now()) => addVisit(profile, url, title, at);

function queryHistory(profile: string, { maxUrls = 5000, maxVisits = 50 }: { maxUrls?: number; maxVisits?: number }) {
  const entries = [...chromeHistory(profile)]
    .map(([u, r]) => ({ u, t: r.title, n: r.visits.length, v: r.visits.slice(-maxVisits) }))
    .sort((a, b) => (b.v.at(-1) ?? 0) - (a.v.at(-1) ?? 0))
    .slice(0, maxUrls);
  return { entries };
}

function addHistoryVisits(profile: string, { pages, toleranceMs = 1000 }: { pages: { u: string; t: string; v: number[] }[]; toleranceMs?: number }) {
  let added = 0;
  for (const page of pages) {
    const have = [...(chromeHistory(profile).get(page.u)?.visits ?? [])];
    for (const at of [...page.v].sort((a, b) => a - b)) {
      const match = have.findIndex((t) => Math.abs(t - at) <= toleranceMs);
      if (match >= 0) {
        have.splice(match, 1);
        continue;
      }
      addVisit(profile, page.u, chromeHistory(profile).get(page.u)?.title || page.t, at);
      added++;
    }
  }
  return { added };
}

function importHistoryRows(profile: string, { rows }: { rows: { u: string; t: string; l: number }[] }) {
  for (const r of rows) if (!chromeHistory(profile).has(r.u)) chromeHistory(profile).set(r.u, { title: r.t, visits: [r.l] });
  return {};
}

function deleteHistoryUrls(profile: string, { urls }: { urls: string[] }) {
  for (const url of urls) chromeHistory(profile).delete(url);
  chromeHistoryEvent({ kind: "deleted", profile, all: false, urls });
  return {};
}

export const chromeFavicons = new Map<string, string>();
const PNG_URI = "data:image/png;base64,";
function faviconsFor(profile: string, { pages }: { pages: string[] }) {
  const known = pages.filter((p) => chromeFavicons.has(`${profile}|${p}`));
  const png = (p: string) => chromeFavicons.get(`${profile}|${p}`)!.replace(PNG_URI, "");
  return { pages: Object.fromEntries(known.map((p) => [p, { png: png(p), icon: "" }])), icons: {} };
}

type BookmarkNode = { id: string; k: "u" | "f"; t: string; u?: string; a: number; key?: string; parent: string | null; children: string[] };
export const bookmarkDbs = new Map<string | null, Map<string, Map<string, BookmarkNode>>>();
export const chromeBookmarks = (profile = "", device = current.device) => {
  if (!bookmarkDbs.has(device)) bookmarkDbs.set(device, new Map());
  const dbs = bookmarkDbs.get(device)!;
  if (!dbs.has(profile)) {
    const folder = (id: string, t: string): BookmarkNode => ({ id, k: "f", t, a: 0, parent: null, children: [] });
    dbs.set(profile, new Map([["bar", folder("bar", "Bookmarks Bar")], ["other", folder("other", "Other Bookmarks")]]));
  }
  return dbs.get(profile)!;
};

function treeOf(db: Map<string, BookmarkNode>, id: string): EngineBookmark {
  const n = db.get(id)!;
  const key = n.key ? { key: n.key } : {};
  return n.k === "u"
    ? { id: n.id, k: "u", t: n.t, u: n.u, a: n.a, ...key }
    : { id: n.id, k: "f", t: n.t, a: n.a, ...key, c: n.children.map((c) => treeOf(db, c)) };
}

function isAncestor(db: Map<string, BookmarkNode>, node: string, of: string) {
  for (let at: string | null | undefined = of; at; at = db.get(at)?.parent) if (at === node) return true;
  return false;
}

function moveTo(db: Map<string, BookmarkNode>, id: string, parent: string, index?: number) {
  const node = db.get(id)!;
  const old = node.parent ? db.get(node.parent) : undefined;
  if (old) old.children.splice(old.children.indexOf(id), 1);
  const kids = db.get(parent)!.children;
  kids.splice(Math.max(0, Math.min(index ?? kids.length, kids.length)), 0, id);
  node.parent = parent;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
function applyOp(db: Map<string, BookmarkNode>, op: BookmarkOp): boolean | "invalid" {
  const node = db.get(op.id);
  const permanent = op.id === "bar" || op.id === "other";
  if (op.op === "remove") {
    if (!node || permanent) return false;
    const drop = (id: string) => {
      db.get(id)!.children.forEach(drop);
      db.delete(id);
    };
    const parent = db.get(node.parent!)!;
    parent.children = parent.children.filter((c) => c !== op.id);
    drop(op.id);
    return true;
  }
  if (op.op === "update") {
    if (!node || permanent) return false;
    if (op.t !== undefined) node.t = op.t;
    if (op.u && node.k === "u") node.u = op.u;
    return true;
  }
  const parent = db.get(op.parent);
  if (!parent || parent.k !== "f") return false;
  if (op.op === "move") {
    if (!node || permanent || isAncestor(db, op.id, op.parent)) return false;
    moveTo(db, op.id, op.parent, op.index);
    return true;
  }
  if (node && op.ifAbsent) return true;
  if (node) {
    if (permanent || isAncestor(db, op.id, op.parent)) return false;
    moveTo(db, op.id, op.parent, op.index);
    node.t = op.t;
    if (op.u && node.k === "u") node.u = op.u;
    return true;
  }
  if (!UUID.test(op.id)) return false;
  if (op.k === "u" && !/^[a-z][a-z0-9+.-]*:/i.test(op.u ?? "")) return "invalid";
  db.set(op.id, { id: op.id, k: op.k, t: op.t, ...(op.k === "u" ? { u: op.u } : {}), children: [], a: op.a, ...(op.key ? { key: op.key } : {}), parent: null });
  moveTo(db, op.id, op.parent, op.index);
  return true;
}

export const bookmarkOpsSent: BookmarkOp[] = [];
function applyBookmarkOps(profile: string, { ops }: { ops: BookmarkOp[] }) {
  bookmarkOpsSent.push(...ops);
  const db = chromeBookmarks(profile);
  let applied = 0;
  const invalid: string[] = [];
  for (const op of ops) {
    const result = applyOp(db, op);
    if (result === "invalid") invalid.push(op.id);
    else if (result) applied++;
    else break;
  }
  return { applied, skipped: ops.length - applied - invalid.length, invalid };
}

export function chromeBookmarkEdit(profile: string, ops: BookmarkOp[]) {
  const db = chromeBookmarks(profile);
  for (const op of ops) applyOp(db, op);
  laterEngineEvent("bookmarks.changed", { profile });
}

function cliControl(args: EngineArgs) {
  if (args && "active" in args) return testGlobals.acTestCliActive?.(args.active as number) ?? {};
  const on = args && "on" in args ? (args.on as boolean) : null;
  return testGlobals.acTestCliControl?.(on) ?? { state: on ? "on" : "off" };
}

const engineCalls: Record<string, (profile: string, args: never) => unknown> = {
  ac_history_query: queryHistory,
  ac_history_add: addHistoryVisits,
  ac_history_import: importHistoryRows,
  ac_history_delete_urls: deleteHistoryUrls,
  ac_history_watch: (profile: string) => (historyWatches.push(profile), { ok: true }),
  ac_favicons_get: faviconsFor,
  ac_favicons_set: (profile: string, args: { page: string; png: string }) => (chromeFavicons.set(`${profile}|${args.page}`, `${PNG_URI}${args.png}`), { stored: true }),
  ac_bookmarks_tree: (profile: string) => ({ bar: treeOf(chromeBookmarks(profile), "bar"), other: treeOf(chromeBookmarks(profile), "other") }),
  ac_bookmarks_apply: applyBookmarkOps,
  ac_bookmarks_watch: () => ({ ok: true }),
  ac_cli_control: (_profile: string, args: EngineArgs) => cliControl(args),
  ac_battery_saver: () => null,
};

function engineCall(name: string, profile: string, json: string | null): Promise<string> {
  const args = json === null ? undefined : (JSON.parse(json) as EngineArgs);
  const handler = engineCalls[name] as ((profile: string, args: EngineArgs) => unknown) | undefined;
  const answer = handler ? handler(profile, args) : (testGlobals.acTestEngineCall?.(name, profile, args) ?? {});
  return Promise.resolve(answer).then((value) => JSON.stringify(value ?? null));
}

export const cancelledDownloads: string[] = [];
export const endedWebKitSessions: string[] = [];
export const removedStagings: string[] = [];
export const stagingRemovals = { ok: true };
export const deletedProfileData: string[] = [];
export const profileDataLeft = new Map<string, string[]>();
export const revealedTabs: string[] = [];
export const linkRoute: { next: LinkRoute } = { next: {} };
export const extensionAnswers = {
  actionStates: async (_browserId: number, _ids: string[]): Promise<Record<string, ActionState>> => ({}),
  sidePanelUrl: async (_browserId: number, _extensionId: string): Promise<string | null> => null,
};

const tabStripHost = () => testGlobals.acTestTabStrip!;
let autofillIds = 0;

const cef: Modules["SolaraCEF"] = {
  addListener: (name: string, listener: (payload: never) => void) =>
    name === "onTabStrip" ? tabStripHost().listen(listener as (tx: TabStripTransaction) => void) : cefEvents.addListener(name, listener),
  notificationWatch: async () => unfaked("SolaraCEF", "notificationWatch"),
  notificationConsume: async () => unfaked("SolaraCEF", "notificationConsume"),
  notificationControl: async () => unfaked("SolaraCEF", "notificationControl"),
  notificationDebugSnapshot: async () => unfaked("SolaraCEF", "notificationDebugSnapshot"),
  notificationDebugDisplayed: async () => unfaked("SolaraCEF", "notificationDebugDisplayed"),
  engineInfo: () => unfaked("SolaraCEF", "engineInfo"),
  chromeWindows: () => Promise.resolve([]),
  prepareTransfer: () => {},
  releaseTransfer: () => {},
  claimLaunchTab: () => {},
  revealTab: (key) => void revealedTabs.push(key),
  dropTabReveals: (key) => void revealedTabs.push(`drop over ${key}`),
  revealOffered: (adoptId, key) => void revealedTabs.push(`${adoptId} over ${key}`),
  routeLinkTabs: () => Promise.resolve(linkRoute.next),
  tabStripCommand: (id, command) => (tabStripHost().command(command, id), Promise.resolve()),
  tabStrips: () => tabStripHost().snapshot(),
  devWindow: () => Promise.resolve(""),
  components: () => Promise.resolve([]),
  beginTracing: () => Promise.resolve(false),
  endTracing: () => Promise.resolve(null),
  isTracing: () => Promise.resolve(false),
  setDisplayMediaPicker: () => Promise.resolve(),
  setSearchEngineName: () => Promise.resolve(),
  displayMediaSources: () => Promise.resolve([]),
  listTasks: () => Promise.resolve([]),
  systemState: () => Promise.resolve({ onBattery: false, batteryLevel: null, lowPowerMode: false, memoryPressure: "normal", physicalMemory: 16 * 2 ** 30 }),
  cancelDownload: (id) => (cancelledDownloads.push(id), Promise.resolve()),
  pauseDownload: () => Promise.resolve(),
  resumeDownload: () => Promise.resolve(),
  keepDownload: () => Promise.resolve(),
  resolvePermission: () => Promise.resolve(),
  resolveExternalApp: () => Promise.resolve(),
  getExternalAppAllowances: () => Promise.resolve([]),
  removeExternalAppAllowance: () => Promise.resolve(),
  clearBrowsingData: () => Promise.resolve(),
  fetchFavicon: () => Promise.resolve(null),
  engineCall,
  releaseProfile: () => Promise.resolve(),
  deleteProfileData: (profile) => (deletedProfileData.push(profile), Promise.resolve({ remaining: profileDataLeft.get(profile) ?? [] })),
  getWebKitContentBlocker: () => unfaked("SolaraCEF", "getWebKitContentBlocker"),
  getContentBlocker: () => unfaked("SolaraCEF", "getContentBlocker"),
  setContentBlockerEnabled: () => Promise.resolve(),
  setFilterListEnabled: () => Promise.resolve(),
  isContentBlockerAllowed: () => Promise.resolve(false),
  setContentBlockerAllowed: () => Promise.resolve(),
  setSiteSetting: () => Promise.resolve(),
  getSiteSettings: () => unfaked("SolaraCEF", "getSiteSettings"),
  getSiteSettingsOrigins: () => Promise.resolve([]),
  resetSiteSettings: () => Promise.resolve(),
  clearSiteData: () => Promise.resolve({ cookies: 0, storage: true }),
  setZoom: () => Promise.resolve(),
  getZoomLevels: () => Promise.resolve({}),
  listPasswords: async () => ({
    passwords: [...(passwordStores.get(current.device)?.values() ?? [])].map((l) => ({ origin: l.origin, username: l.username, created: l.created, modified: l.created })),
  }),
  unlockPasswords: () => Promise.resolve({ unlocked: true }),
  getPassword: async (_profile, origin, username) => ({ password: passwordStores.get(current.device)?.get(`${origin}\n${username}`)?.password ?? null }),
  savePassword: async (_profile, origin, username, password) => {
    logins().set(`${origin}\n${username}`, { origin: `${origin}/`, url: origin, username, password, created: Date.now() });
    return { ok: true };
  },
  updatePassword: () => unfaked("SolaraCEF", "updatePassword"),
  deletePassword: async (_profile, origin, username) => {
    logins().delete(`${origin}\n${username}`);
    return { ok: true };
  },
  getNeverSavePasswordOrigins: () => Promise.resolve({ origins: [] }),
  allowSavingPasswords: () => Promise.resolve({ ok: true }),
  exportPasswords: () => Promise.resolve({ status: "cancelled" }),
  getPasswordAutofill: () => Promise.resolve(true),
  setPasswordAutofill: () => Promise.resolve(),
  getAutofillSettings: () => Promise.resolve({ addresses: true, cards: true }),
  setAutofillSettings: () => Promise.resolve(),
  listAddresses: () => Promise.resolve({ addresses: [] }),
  saveAddress: () => Promise.resolve({ id: `address-${++autofillIds}` }),
  listCards: () => Promise.resolve({ cards: [] }),
  saveCard: () => Promise.resolve({ id: `card-${++autofillIds}` }),
  deleteAutofillEntry: () => Promise.resolve({ ok: true }),
  revealCardNumber: () => Promise.resolve({ number: null }),
};

const extensionEvents = nativeEvents();
const extensions: Modules["SolaraExtensions"] = {
  addListener: extensionEvents.addListener,
  resolveInstallPrompt: () => Promise.resolve(),
  list: async () => ({ extensions: [] }),
  inspectUnpacked: () => unfaked("SolaraExtensions", "inspectUnpacked"),
  install: () => Promise.resolve({ error: "no extension engine in this test" }),
  setEnabled: () => Promise.resolve({ ok: true }),
  uninstall: () => Promise.resolve({ ok: true }),
  reload: () => Promise.resolve({ ok: true }),
  configure: () => Promise.resolve({ ok: true }),
  searchEngineList: () => Promise.resolve({ list: [] }),
  chooseFolder: () => Promise.resolve(null),
};

const chromeUIEvents = nativeEvents();
const chromeUI: Modules["SolaraChromeUI"] = {
  addListener: chromeUIEvents.addListener,
  selectDevice: () => Promise.resolve(),
  cancelDeviceChooser: () => Promise.resolve(),
  refreshDeviceChooser: () => Promise.resolve(),
  openBluetoothSettings: () => Promise.resolve(),
  showCastDialog: () => Promise.resolve(false),
  startCasting: () => Promise.resolve(),
  stopCasting: () => Promise.resolve(),
  closeCastDialog: () => Promise.resolve(),
  watchCastRoutes: () => Promise.resolve(),
  terminateCastRoute: () => Promise.resolve(),
  actionStates: (browserId, ids) => extensionAnswers.actionStates(browserId, ids),
  sidePanelURL: (browserId, extensionId) => extensionAnswers.sidePanelUrl(browserId, extensionId),
  changeCaptureSource: () => Promise.resolve(false),
  stopCapture: () => Promise.resolve(false),
  showAutofillSuggestions: () => Promise.resolve(false),
};

const swipe: Modules["SolaraSwipe"] = {
  haptic: () => {},
  switchPager: () => Promise.resolve(false),
  stepPager: () => Promise.resolve(false),
  selectPager: () => Promise.resolve(false),
  pagerState: () => null,
  devPagerState: () => Promise.resolve(null),
  devSimulate: () => unfaked("SolaraSwipe", "devSimulate"),
};

export const solaraCoreNativeModules: Modules = {
  SolaraCEF: cef,
  SolaraExtensions: extensions,
  SolaraChromeUI: chromeUI,
  SolaraSwipe: swipe,
};

const webKitEvents = nativeEvents();
const webKit: SolaraCoreOptionalNativeModules["SolaraWebKit"] = {
  addListener: webKitEvents.addListener,
  prepareTransfer: () => {},
  releaseTransfer: () => {},
  resolvePermission: () => Promise.resolve(),
  downloadCommand: (action, id) => (action === "cancel" && cancelledDownloads.push(id), Promise.resolve()),
  externalAppAllowances: () => Promise.resolve([]),
  removeExternalAppAllowance: () => Promise.resolve(),
  endPrivateSession: (session) => (endedWebKitSessions.push(session), Promise.resolve()),
  removeDownloadStaging: (path) => (removedStagings.push(path), Promise.resolve(stagingRemovals.ok)),
  sitePermissions: () => Promise.resolve({}),
  setSitePermission: () => Promise.resolve(),
  resolveExternalApp: () => Promise.resolve(),
  clearBrowsingData: () => Promise.resolve(),
  deleteProfileData: () => Promise.resolve(true),
  cookieStoreKey: (profile) => Promise.resolve(profile),
  importCookies: (_profile, _storeKey, cookies) => Promise.resolve(cookies.length),
  info: () => Promise.resolve({ safariVersion: "26.0", userAgentSuffix: "", passkeys: false }),
  passkeyAccess: () => Promise.resolve({ entitled: false, status: "entitlementRequired" }),
  requestPasskeyAccess: () => Promise.resolve({ entitled: false, status: "entitlementRequired" }),
};

export const solaraCoreOptionalNativeModules: OptionalModules = {
  SolaraWebKit: () => webKit,
};
