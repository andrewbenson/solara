import { requireOptionalNativeModule, type EventSubscription } from "expo-modules-core";

export { encodeArgs, encodeCommand, PATCH_COMMANDS } from "./encode";

type StoreStatus = ({ active: true; scope?: "settingsAndDownloads" | "everything" } | { active: false; reason: string; handedOff?: boolean; refusedSession?: string }) & { syncRedesign?: boolean; safeMode?: "option" | "failedLaunches" };

type NativeStoreModule = {
  status(): StoreStatus;
  snapshot(): string | null;
  dispatch(commandJSON: string, sinceRev: number): string | null;
  catchUp(sinceRev: number): string | null;
  flush(timeout: number): string | boolean;
  freeze?(): boolean;
  useSyncOrigins?(on: boolean): boolean;
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
