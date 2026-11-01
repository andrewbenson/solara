import type {
  AppEvent,
  BangListReply,
  CommandEvent,
  OpenWindowOptions,
  ShellNativeModules,
  ShellOptionalNativeModules,
  SystemInfo,
  WindowEvent,
} from "@solara/shell";
import { nativeEvents, unfaked } from "./events";

type Modules = ShellNativeModules;
type OptionalModules = { [Name in keyof ShellOptionalNativeModules]: () => ShellOptionalNativeModules[Name] | null };

export const docs = new Map<string, string>();
export const documentWrites: string[] = [];
export const unreadableDocs = new Map<string, string>();
export const heldSaves = { on: false, fail: false, only: null as string | null, queue: [] as (() => void)[] };
export const bangListServer: { reply: ((etag: string | null) => Promise<BangListReply>) | null } = { reply: null };
export const appInfo: Partial<SystemInfo> = { appVersion: "1.0", switchesURL: "https://stats.example.com/switches.json" };
export const environment = new Map<string, string>();

export type FakeWindow = OpenWindowOptions & { title?: string; trafficLightsCenter?: [number, number] | null };
const shellEvents = nativeEvents();
export const windows = {
  open: new Map<string, FakeWindow>(),
  closed: [] as string[],
  focused: null as string | null,
  emit: (event: WindowEvent) => shellEvents.emit("onWindowEvent", event),
};
export const emitAppEvent = (event: AppEvent) => shellEvents.emit("onAppEvent", event);
export const emitCommand = (event: CommandEvent) => shellEvents.emit("onCommand", event);
export const emitOpenURLs = (urls: string[], pointer?: [number, number]) => shellEvents.emit("onOpenURLs", { urls, pointer });

const shell: Modules["SolaraShell"] = {
  addListener: shellEvents.addListener,
  showMenu: () => Promise.resolve(null),
  copyText: () => {},
  setSwitcherCapture: () => Promise.resolve(),
  cancelFocusMove: () => Promise.resolve(),
  claimFocus: () => Promise.resolve(),
  startDictation: () => {},
  pickFiles: () => Promise.resolve([]),
  readDocument: (name) => docs.get(name) ?? null,
  readDocumentResult: (name) =>
    unreadableDocs.has(name) ? { path: `/data/${name}`, failure: unreadableDocs.get(name)! } : docs.has(name) ? { contents: docs.get(name)! } : {},
  writeDocument: (name, contents) => { documentWrites.push(name); docs.set(name, contents); },
  saveDocument: (name, contents) =>
    new Promise((resolve, reject) => {
      if (heldSaves.fail) return reject(new Error("disk full"));
      const land = () => (docs.set(name, contents), resolve());
      if (heldSaves.on && (!heldSaves.only || name.startsWith(heldSaves.only))) heldSaves.queue.push(land);
      else land();
    }),
  removeDocument: (name) => void docs.delete(name),
  listDocuments: (prefix) => [...docs.keys()].filter((name) => name.startsWith(prefix)).sort(),
  get fetchBangList() {
    return bangListServer.reply ?? undefined;
  },
  openWindow: (id, options) => {
    windows.open.set(id, { ...options });
    if (options.focus !== false) windows.focused = id;
    return Promise.resolve();
  },
  closeWindow: (id) => {
    windows.open.delete(id);
    windows.closed.push(id);
    if (windows.focused === id) windows.focused = null;
    return Promise.resolve();
  },
  focusWindow: (id) => {
    windows.focused = id;
    return Promise.resolve();
  },
  setTrafficLightsCenter: (id, center) => {
    const window = windows.open.get(id);
    if (window) window.trafficLightsCenter = center;
    return Promise.resolve();
  },
  setWindowTitle: (id, title) => {
    const window = windows.open.get(id);
    if (window) window.title = title;
    return Promise.resolve();
  },
  windowIds: () => Promise.resolve([...windows.open.keys()]),
  setAppearance: () => Promise.resolve(),
  isDarkAppearance: () => Promise.resolve(false),
  setMenuState: () => Promise.resolve(),
  setMenuBookmarks: () => Promise.resolve(),
  replyToTerminate: () => Promise.resolve(),
  confirm: () => Promise.resolve({ confirmed: false, suppressed: false }),
  prompt: () => Promise.resolve(null),
};

const appEvents = nativeEvents();
const app: Modules["SolaraApp"] & { apiVersion: number } = {
  apiVersion: 21,
  addListener: appEvents.addListener,
  updaterState: () => Promise.resolve({ available: false }),
  checkForUpdates: () => Promise.resolve(),
  setAutomaticUpdateChecks: () => Promise.resolve(),
  setAutomaticUpdateDownloads: () => Promise.resolve(),
  setUpdateChannel: () => Promise.resolve(),
  share: () => Promise.resolve(),
  shareVia: () => Promise.resolve(),
  isInDock: () => Promise.resolve(false),
  addToDock: () => Promise.resolve(false),
  appIcons: () => Promise.resolve([]),
  appIcon: () => Promise.resolve("default"),
  setAppIcon: () => Promise.resolve(),
  notificationPermission: () => Promise.resolve("notDetermined"),
  requestNotificationPermission: () => Promise.resolve(false),
  postNotification: () => Promise.resolve(null),
  removeNotifications: () => Promise.resolve(),
  openNotificationSettings: () => Promise.resolve(),
  setScriptLoading: () => Promise.resolve(),
  systemInfo: () => ({ ...appInfo }) as SystemInfo,
  openExternalURL: () => Promise.resolve(false),
  launchEnvironment: (name) => environment.get(name) ?? null,
  killSwitchEnvironment: (name) => environment.get(name) ?? null,
  playIntroMusic: () => Promise.resolve(),
  setIntroMusicMuted: () => Promise.resolve(),
  stopIntroMusic: () => Promise.resolve(),
  devRenderIntroMusic: () => Promise.resolve(null),
  devRunAppleScript: () => Promise.resolve({ ok: false, error: "no AppleScript in tests" }),
  devSnapshotWindow: () => Promise.resolve(false),
  devSetPointer: () => Promise.resolve(false),
  devSetMouseButtons: () => Promise.resolve(false),
  devHoverStats: () => Promise.resolve({}),
  devMenuCommand: () => Promise.resolve(),
  devTypeKeys: () => Promise.resolve([]),
  devKeyEquivalent: () => Promise.resolve({ handledBy: "none" }),
  devClick: () => Promise.resolve({}),
};

const system: Modules["SolaraSystem"] = {
  isDefaultBrowser: () => Promise.resolve(false),
  setAsDefaultBrowser: () => Promise.resolve(false),
  launchAtLoginStatus: () => Promise.resolve("notRegistered"),
  setLaunchAtLogin: () => Promise.resolve(),
  fileExists: () => false,
  openFile: () => Promise.resolve(false),
  revealFile: () => Promise.resolve(false),
  moveToTrash: () => Promise.resolve(false),
  fileIcon: () => Promise.resolve(null),
  appIcon: () => Promise.resolve(null),
  hapticTick: () => {},
  menuShortcuts: () => Promise.resolve([]),
  recordShortcut: () => Promise.resolve(null),
  cancelRecording: () => Promise.resolve(),
};

const calendarEvents = nativeEvents();
const calendar: Modules["SolaraCalendar"] = {
  addListener: calendarEvents.addListener,
  authorizationStatus: () => "notDetermined",
  requestAccess: () => Promise.resolve(false),
  calendars: () => Promise.resolve([]),
  events: () => Promise.resolve([]),
};

const keychain: Modules["SolaraKeychain"] = {
  get: () => Promise.resolve(null),
  set: () => Promise.resolve(true),
  delete: () => Promise.resolve(true),
};

const translate: Modules["SolaraTranslate"] = {
  available: false,
  userLanguages: () => ["en"],
  languageName: (identifier) => identifier,
  detect: () => Promise.resolve(null),
  status: () => Promise.resolve("unsupported"),
  supportedLanguages: () => Promise.resolve([]),
  prepare: () => Promise.resolve(),
  translate: (_source, _target, texts) => Promise.resolve(texts),
  translateBlocks: (_source, _target, blocks) => Promise.resolve(blocks),
};

export const shellNativeModules: Modules = {
  SolaraShell: shell,
  SolaraApp: app,
  SolaraSystem: system,
  SolaraCalendar: calendar,
  SolaraKeychain: keychain,
  SolaraGlassEffect: { isLiquidGlass: () => false },
  SolaraDockSelection: { iconTheme: () => Promise.resolve(null) },
  SolaraInlineCompletion: { complete: () => Promise.resolve(0) },
  SolaraTranslate: translate,
};

const cliEvents = nativeEvents();
const cli: ShellOptionalNativeModules["SolaraCli"] = {
  installedVersion: () => null,
  install: () => Promise.resolve({ ok: false, appVersion: appInfo.appVersion ?? "", error: "no installs in tests", lines: [] }),
  addListener: cliEvents.addListener,
};

const popoverBubble: ShellOptionalNativeModules["SolaraPopoverBubble"] = { isAvailable: () => false };
const magnifyArea: ShellOptionalNativeModules["SolaraMagnifyArea"] = { devMagnify: () => unfaked("SolaraMagnifyArea", "devMagnify") };
const fileDrop: ShellOptionalNativeModules["SolaraFileDrop"] = {
  devDrag: () => unfaked("SolaraFileDrop", "devDrag"),
  devLastFileDrag: () => Promise.resolve([]),
};

export const shellOptionalNativeModules: OptionalModules = {
  SolaraPopoverBubble: () => popoverBubble,
  SolaraMagnifyArea: () => magnifyArea,
  SolaraFileDrop: () => fileDrop,
  SolaraCli: () => cli,
  SolaraHairline: () => null,
};
