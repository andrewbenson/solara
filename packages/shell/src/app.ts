import type { EventSubscription } from "expo-modules-core";
import { nativeModule } from "./nativeModules";

export type UpdaterState =
  | { available: false }
  | {
      available: true;
      configured: boolean;
      automaticChecks: boolean;
      automaticDownloads: boolean;
      canCheck: boolean;
      sessionInProgress: boolean;
      feedURL: string | null;
      lastCheck: number | null;
      version: string;
      displayVersion?: string;
      channel?: UpdateChannel;
      buildChannel?: UpdateChannel;
      pendingUpdate?: PendingUpdate | null;
    };

export type PendingUpdate = { version: string; build: string };

export type UpdateChannel = "stable" | "nightly";

export type AppIcon = { id: string; name: string; preview: string | null };

export type NotificationPermission = "granted" | "denied" | "notDetermined" | "provisional" | "simulated";

export type NotificationOptions = {
  id?: string;
  title: string;
  body?: string;
  subtitle?: string;
  silent?: boolean;
  icon?: string;
  tabId?: string;
  windowId?: string;
  origin?: string;
  dismissible?: boolean;
  data?: Record<string, unknown>;
};

export type NotificationResponse = {
  id: string;
  action: "click" | "close";
  tabId: string | null;
  windowId: string | null;
  data: unknown;
};

export type SystemInfo = {
  appName: string;
  appVersion: string;
  appBuild: string;
  bundleId: string;
  configuration: "Debug" | "Release";
  osVersion: string;
  osBuild: string;
  arch: string;
  model: string;
  memoryGB: number;
  locale: string;
  updates: boolean;
  feedbackURL?: string | null;
  feedbackEmail?: string | null;
  videoTourURL?: string | null;
  releaseNotesURL?: string | null;
  updateFeedURL?: string | null;
  releaseRepo?: string | null;
  switchesURL?: string | null;
  isolatedInstance?: boolean;
  forceReleaseNotes?: boolean;
  processStart?: number | null;
  bootTime?: number | null;
  inApplicationsFolder?: boolean;
};

export type AppModule = {
  addListener(name: "onNotificationResponse", listener: (e: NotificationResponse) => void): EventSubscription;
  addListener(name: "onPendingUpdate", listener: (e: { update: PendingUpdate | null }) => void): EventSubscription;
  pendingUpdate?(): Promise<PendingUpdate | null>;
  installPendingUpdate?(): Promise<void>;
  devSimulatePendingUpdate?(version: string | null, onInstall: "count" | "quit"): Promise<number>;
  devSimulatedInstallRequests?(): Promise<number>;
  devRestartToUpdateShown?(): Promise<boolean | null>;
  updaterState(): Promise<UpdaterState>;
  checkForUpdates(): Promise<void>;
  setAutomaticUpdateChecks(on: boolean): Promise<void>;
  setAutomaticUpdateDownloads(on: boolean): Promise<void>;
  setUpdateChannel(channel: UpdateChannel): Promise<void>;
  share(url: string, title: string | null, windowId: string | null, anchor: ShareAnchor | null): Promise<void>;
  shareVia(service: string, url: string, title: string | null, windowId: string | null): Promise<void>;
  isInDock(): Promise<boolean>;
  addToDock(): Promise<boolean>;
  appIcons(size: number): Promise<AppIcon[]>;
  appIcon(): Promise<string>;
  setAppIcon(id: string): Promise<void>;
  notificationPermission(): Promise<NotificationPermission>;
  requestNotificationPermission(): Promise<boolean>;
  postNotification(options: NotificationOptions): Promise<string | null>;
  removeNotifications(ids: string[]): Promise<void>;
  openNotificationSettings(): Promise<void>;
  setScriptLoading(ids: string[]): Promise<void>;
  systemInfo(): SystemInfo;
  openExternalURL(url: string): Promise<boolean>;
  launchEnvironment(name: string): string | null;
  killSwitchEnvironment?(name: string): string | null;
  playIntroMusic(cues: IntroMusicCues, muted: boolean): Promise<void>;
  setIntroMusicMuted(muted: boolean): Promise<void>;
  stopIntroMusic(fade: number): Promise<void>;
  devRenderIntroMusic(cues: IntroMusicCues, path: string): Promise<number | null>;
  devRunAppleScript(source: string): Promise<{ ok: boolean; result?: unknown; error?: string; number?: number }>;
  devSnapshotWindow(windowId: string, path: string, transparent?: boolean): Promise<boolean>;
  devSetPointer(windowId: string, x: number, y: number, on: boolean): Promise<boolean>;
  devSetMouseButtons(pressed: number): Promise<boolean>;
  devLeftEdgePointer?(windowId: string, x: number, y: number, on: boolean): Promise<boolean>;
  devLeftEdgeAppActive?(active: boolean, on: boolean): Promise<boolean>;
  devLeftEdgeStats?(reset: boolean): Promise<LeftEdgeStats>;
  devHoverStats(reset: boolean): Promise<{ passes?: number; log?: [string, number, number][]; registered?: number }>;
  devMenuCommand(command: string, arg: string | null): Promise<void>;
  devTypeKeys(windowId: string, text: string, interval: number): Promise<KeyTiming[]>;
  devKeyEquivalent(windowId: string, press: KeyPress): Promise<KeyPressResult>;
  devClick(windowId: string, click: Click): Promise<ClickResult>;
};


const App = nativeModule("SolaraApp");

export const updaterState = () => App.updaterState();
export const checkForUpdates = () => App.checkForUpdates();
export const setAutomaticUpdateChecks = (on: boolean) => App.setAutomaticUpdateChecks(on);
export const setAutomaticUpdateDownloads = (on: boolean) => App.setAutomaticUpdateDownloads(on);
export const setUpdateChannel = (channel: UpdateChannel) => App.setUpdateChannel(channel);
export const pendingUpdate = async (): Promise<PendingUpdate | null> => (App.pendingUpdate ? App.pendingUpdate() : null);
export const installPendingUpdate = async () => App.installPendingUpdate?.();
export const onPendingUpdate = (listener: (update: PendingUpdate | null) => void): EventSubscription | null =>
  App.pendingUpdate ? App.addListener("onPendingUpdate", (e) => listener(e.update ?? null)) : null;
export const devSimulatePendingUpdate = async (version: string | null, onInstall: "count" | "quit" = "count") =>
  App.devSimulatePendingUpdate ? App.devSimulatePendingUpdate(version, onInstall) : -1;
export const devSimulatedInstallRequests = async () => (App.devSimulatedInstallRequests ? App.devSimulatedInstallRequests() : -1);

export type ShareAnchor = [number, number, number, number];

export const sharePage = (url: string, title?: string | null, windowId?: string | null, anchor?: ShareAnchor | null) =>
  App.share(url, title ?? null, windowId ?? null, anchor ?? null);

export const sharePageVia = (service: string, url: string, title?: string | null, windowId?: string | null) =>
  App.shareVia(service, url, title ?? null, windowId ?? null);

export const isInDock = () => App.isInDock();
export const addToDock = () => App.addToDock();

export const appIcons = (size = 64) => App.appIcons(size);
export const currentAppIcon = () => App.appIcon();
export const setAppIcon = (id: string) => App.setAppIcon(id);

export const notificationPermission = () => App.notificationPermission();

export const requestNotificationPermission = () => App.requestNotificationPermission();
export const postNotification = (options: NotificationOptions) => App.postNotification(options);
export const removeNotifications = (ids: string[]) => App.removeNotifications(ids);
export const openNotificationSettings = () => App.openNotificationSettings();
export const onNotificationResponse = (listener: (e: NotificationResponse) => void) => App.addListener("onNotificationResponse", listener);

export const setScriptLoading = (ids: string[]) => App.setScriptLoading(ids);

export const systemInfo = () => App.systemInfo();
export const openExternalURL = (url: string) => App.openExternalURL(url);
export type IntroMusicCues = {
  icon: number;
  letters: number;
  letterStep: number;
  letterCount: number;
  tagline: number;
  exit: number;
  end: number;
};
export const playIntroMusic = (cues: IntroMusicCues, muted: boolean) => void App.playIntroMusic(cues, muted);
export const setIntroMusicMuted = (muted: boolean) => void App.setIntroMusicMuted(muted);
export const stopIntroMusic = (fade = 0.4) => void App.stopIntroMusic(fade);
export const devRenderIntroMusic = (cues: IntroMusicCues, path: string) => App.devRenderIntroMusic(cues, path);
export const launchEnvironment = (name: string) => App.launchEnvironment(name);
export const killSwitchEnvironment = (name: string) =>
  typeof App.killSwitchEnvironment === "function" ? App.killSwitchEnvironment(name) : App.launchEnvironment(name);
export const devRunAppleScript = (source: string) => App.devRunAppleScript(source);
export const devSnapshotWindow = (windowId: string, path: string, transparent = false) =>
  transparent ? App.devSnapshotWindow(windowId, path, true) : App.devSnapshotWindow(windowId, path);
export const devSetPointer = (windowId: string, point: { x: number; y: number } | null) => App.devSetPointer(windowId, point?.x ?? 0, point?.y ?? 0, !!point);
export const devSetMouseButtons = (pressed: boolean | null) => App.devSetMouseButtons(pressed === null ? -1 : pressed ? 1 : 0);
export const devHoverStats = (reset = true) => App.devHoverStats(reset);
export const devLeftEdgePointer = (windowId: string, point: { x: number; y: number } | null) =>
  App.devLeftEdgePointer?.(windowId, point?.x ?? 0, point?.y ?? 0, !!point) ?? Promise.resolve(false);
export const devLeftEdgeAppActive = (active: boolean | null) => App.devLeftEdgeAppActive?.(active ?? false, active !== null) ?? Promise.resolve(false);
export type LeftEdgeStats = { wakes?: { global: number; local: number }; global?: boolean; local?: boolean; watched?: number };
export const devLeftEdgeStats = (reset = false) => App.devLeftEdgeStats?.(reset) ?? Promise.resolve<LeftEdgeStats>({});
export type KeyTiming = { due: number; handled: number; drawn: number };
export const devTypeKeys = (windowId: string, text: string, interval: number) => App.devTypeKeys(windowId, text, interval);
export type KeyPress = {
  key: string;
  keyCode: number;
  modifiers?: ("command" | "shift" | "option" | "control" | "function")[];
  characters?: string;
  focus?: "window" | "page" | "devtools" | `label:${string}`;
  repeats?: number;
  repeatEvery?: number;
  asKey?: boolean;
  settle?: number;
  wait?: number;
  dry?: boolean;
  send?: boolean;
};
export type KeyPressResult = {
  handledBy?: "page" | "window" | "menu" | "none";
  firstResponder?: string;
  fired?: { title: string; action: string; command?: string; arg?: string; dry?: boolean }[];
  matched?: { title: string; action: string; command?: string; arg?: string; enabled: boolean }[];
  error?: string;
};
export const devKeyEquivalent = (windowId: string, press: KeyPress): Promise<KeyPressResult> =>
  App.devKeyEquivalent(windowId, press);
export type Click = { x: number; y: number; in?: "window" | "page"; label?: string; queued?: boolean; asKey?: boolean; wait?: number };
export type ClickResult = { hit?: string; at?: number; firstResponder?: string; firstResponderOnClick?: string; firstResponderAfter?: string; error?: string };
export const devClick = (windowId: string, click: Click): Promise<ClickResult> => App.devClick(windowId, click);
export const devMenuCommand = (command: string, arg: string | null = null) => App.devMenuCommand(command, arg);
