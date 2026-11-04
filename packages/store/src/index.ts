import { requireOptionalNativeModule, type EventSubscription } from "expo-modules-core";

export { encodeArgs, encodeCommand, PATCH_COMMANDS } from "./encode";

type StoreStatus = ({ active: true; scope?: "settingsAndDownloads" | "everything" } | { active: false; reason: string; handedOff?: boolean; refusedSession?: string }) & { syncRedesign?: boolean; nativeTabSleep?: boolean; safeMode?: "option" | "failedLaunches" };

type NativeStoreModule = {
  status(): StoreStatus;
  snapshot(): string | null;
  dispatch(commandJSON: string, sinceRev: number): string | null;
  catchUp(sinceRev: number): string | null;
  flush(timeout: number): string | boolean;
  freeze?(): boolean;
  useSyncOrigins?(on: boolean): boolean;
  pageFacts(tabId: string): string | null;
  livePages(): string | null;
  updateRNPageContext(tabId: string, sessionGeneration: string, contextJSON: string): boolean;
  isRNPageCurrent(tabId: string, sessionGeneration: string): boolean;
  updatePageContext(tabId: string, sessionGeneration: string, registrationGeneration: number, contextJSON: string): boolean;
  isPageCurrent(tabId: string, sessionGeneration: string, registrationGeneration: number): boolean;
  finishRNPageIssue(tabId: string, guardJSON: string): Promise<{ accepted: boolean }>;
  syncAnchor?(): string | null;
  setSyncAnchor?(anchor: string): boolean;
  addListener(event: "onStoreCommit", listener: (payload: { event: string }) => void): EventSubscription;
};

export type StoreCommand = { name: string; args: unknown[] };

export type StorePatch = {
  rev: number;
  bridge?: boolean;
  sync?: boolean;
  settings?: { set?: Record<string, unknown>; remove?: string[] };
  downloads?: unknown[];
  [slice: string]: unknown;
};

export type StoreEffect = { type: string; [key: string]: unknown };

export type DispatchResponse = {
  rev: number;
  patches?: StorePatch[];
  snapshot?: Record<string, unknown>;
  result?: unknown;
  busy?: boolean;
  effects?: StoreEffect[];
  error?: string;
};

export type ForeignCommit = { rev: number; patch: StorePatch; effects?: StoreEffect[] };

const native = requireOptionalNativeModule<NativeStoreModule>("SolaraStoreAdapter");

export function nativeStoreModulePresent(): boolean {
  return native != null;
}

export function nativeStoreStatus(): StoreStatus {
  if (!native) return { active: false, reason: "the SolaraStoreAdapter module isn't in this build" };
  try {
    return native.status();
  } catch (error) {
    return { active: false, reason: String(error) };
  }
}

export function nativeSnapshot(): { rev: number; data: Record<string, unknown> } | null {
  const text = native?.snapshot();
  return text ? JSON.parse(text) : null;
}

export function nativeDispatch(commands: StoreCommand | StoreCommand[], sinceRev: number, { fromSync = false }: { fromSync?: boolean } = {}): DispatchResponse {
  const text = native?.dispatch(JSON.stringify(fromSync ? { fromSync: true, commands } : commands), sinceRev);
  if (!text) throw new Error("the native store isn't running");
  return JSON.parse(text);
}

export function nativeCatchUp(sinceRev: number): DispatchResponse | null {
  const text = native?.catchUp(sinceRev);
  return text ? JSON.parse(text) : null;
}

export function useNativeSyncOrigins(on: boolean): boolean {
  return native?.useSyncOrigins?.(on) ?? false;
}

export function nativeSyncAnchor(): string | null {
  return native?.syncAnchor?.() ?? null;
}

export function nativeSyncAnchorSupported(): boolean {
  return typeof native?.setSyncAnchor === "function";
}

export function setNativeSyncAnchor(anchor: string): boolean {
  return native?.setSyncAnchor?.(anchor) ?? false;
}

export function freezeNativeStore(): boolean {
  return native?.freeze?.() ?? false;
}

export function flushNativeStore(timeoutSeconds = 0.5): string {
  const result = native?.flush(timeoutSeconds);
  if (typeof result === "boolean") return result ? "saved" : "timedOut";
  return result ?? "failed: the native store is unavailable";
}

export function flushProblem(result: string): boolean {
  return result !== "saved" && !result.startsWith("skipped:");
}

export function onForeignCommit(listener: (commit: ForeignCommit) => void): () => void {
  if (!native) return () => {};
  const subscription = native.addListener("onStoreCommit", ({ event }) => listener(JSON.parse(event)));
  return () => subscription.remove();
}

export type PageSessionGeneration = string;
export type PageNavigation = { url: string; seq: number; userInitiated?: boolean };
export type PageContext = { navigationSeq: number | null; contextRevision: number; wasNewTab: boolean; newTabShownUrl: string | null };
export type PageIdentity = { tabId: string; registrationGeneration: number; sessionGeneration: string };
export type PageIssueGuard = { sessionGeneration: string; navigation: PageNavigation | null; contextRevision: number; modelSerial: number; startedEarly: boolean; sameProfileMove: boolean };
export type PageIssueAction = { type: "clearNewTabShown" } | { type: "load"; url: string; userInitiated: boolean };
export type PageIssuePreview = { actions: PageIssueAction[]; guard: PageIssueGuard | null };
export type KeepAliveKeep = { capturing: boolean; newTabShown: boolean; pip: boolean; displayRequest: boolean; media: "none" | "present" | "playing" };
export type KeepAliveReveal = { fullscreen: boolean; crashed: boolean; unresponsive: boolean; scrolledDown: boolean; sharing: boolean };
export type KeepAliveFacts = { epoch: number; seq: number; handled: number; keep: KeepAliveKeep; reveal: KeepAliveReveal };
export type PageReadyFacts = { browserId: number; tabId: number | null };
export type PageFacts = { generation: string; protectionKnown: boolean; ready: PageReadyFacts | null; keepAlive: KeepAliveFacts | null; latchedThrough: number; newestEventSeq: number };
export type PageReport =
  | ({ type: "created"; generation: string; engine: "chromium" | "webkit"; handoffSeq?: number | null; reestablished?: boolean } & PageContext)
  | ({ type: "context"; generation: string } & PageContext)
  | ({ type: "issued"; generation: string; navigation: PageNavigation | null; startedEarly: boolean; sameProfileMove?: boolean } & PageContext)
  | { type: "navigation"; generation: string; url: string; title: string; isLoading: boolean; canGoBack: boolean; canGoForward: boolean; themeColor?: string | null; initialDocumentAccessed?: boolean; committedInitial?: boolean; committedUrl?: string; eventSeq?: number }
  | { type: "media"; generation: string; playing: boolean; muted?: boolean; eventSeq?: number }
  | { type: "ready"; generation: string; browserId: number; tabId?: number; eventSeq?: number }
  | { type: "download"; generation: string; committedUrl?: string | null; skipped?: boolean; eventSeq?: number }
  | { type: "discarded"; generation: string; url: string; eventSeq?: number }
  | { type: "failed" | "loadError" | "advance" | "gone"; generation: string; eventSeq?: number }
  | { type: "moved"; generation: string; sameProfile: boolean }
  | { type: "restore"; themes: { tab: string; page: string; color: string }[] }
  | { type: "keepAlive"; generation: string; epoch: number; seq: number; handled: number; keep: KeepAliveKeep; reveal: KeepAliveReveal }
  | { type: "latch"; generation: string; eventSeq: number };

let pageReportWriter: ((command: StoreCommand) => DispatchResponse | null) | undefined;

export function installPageReportWriter(writer: (command: StoreCommand) => DispatchResponse | null) {
  pageReportWriter = writer;
}

export function pageReport(tabId: string, report: PageReport): DispatchResponse | null {
  return pageReportWriter?.({ name: "pageReport", args: [tabId, report] }) ?? null;
}

export function registerKeepAliveRuntime(): number {
  const response = pageReportWriter?.({ name: "registerKeepAliveRuntime", args: [] });
  if (!response || response.error || !Number.isSafeInteger(response.result) || Number(response.result) <= 0) throw new Error(response?.error ?? "keepalive runtime registration failed");
  return response.result as number;
}

export function nativePageFacts(tabId: string): PageFacts | null {
  const value = native?.pageFacts(tabId);
  return value ? JSON.parse(value) : null;
}

export function nativeLivePages(): Record<string, PageFacts> {
  const value = native?.livePages();
  return value ? JSON.parse(value) : {};
}

export const isRNPageCurrent = (tabId: string, sessionGeneration: string): boolean => native?.isRNPageCurrent(tabId, sessionGeneration) ?? false;
export const isPageCurrent = ({ tabId, sessionGeneration, registrationGeneration }: PageIdentity): boolean => native?.isPageCurrent(tabId, sessionGeneration, registrationGeneration) ?? false;
export const updateRNPageContext = (tabId: string, sessionGeneration: string, context: PageContext): boolean => native?.updateRNPageContext(tabId, sessionGeneration, JSON.stringify(context)) ?? false;
export const updatePageContext = ({ tabId, sessionGeneration, registrationGeneration }: PageIdentity, context: PageContext): boolean => native?.updatePageContext(tabId, sessionGeneration, registrationGeneration, JSON.stringify(context)) ?? false;
export const finishRNPageIssue = (tabId: string, guard: PageIssueGuard): Promise<{ accepted: boolean }> => native?.finishRNPageIssue(tabId, JSON.stringify(guard)) ?? Promise.resolve({ accepted: false });
