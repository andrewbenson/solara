import { requireOptionalNativeModule } from "expo-modules-core";
import type { Listing, Transport } from "./scope.ts";

export type FolderInfo = {
  path: string;
  defaultPath: string;
  iCloudAvailable: boolean;
  inICloud: boolean;
  exists: boolean;
  writable: boolean;
  hasSyncData: boolean;
};

export type CreationInspection = { id: string; folder: string; candidates: string[]; completeness: string };

export type PhraseResult =
  | { ok: true }
  | { error: "wordCount"; count: number }
  | { error: "unknownWord"; word: string }
  | { error: "checksum" }
  | { error: "noData" }
  | { error: "mismatch" }
  | { error: "keychain" }
  | { error: "interrupted" };

export type SavedLogin = { origin: string; url: string; username: string; password: string; created: number; modified?: number };
export type SealedLogin = { origin: string; username: string; s: string; created: number; modified?: number };
export type MarkedLogins = { logins: SealedLogin[]; mark: string | null };
export type LocalKind = "state" | "journal";
export type SealedValue = { o: string; u: string; s: string };

type SyncNative = {
  folderInfo(path: string | null): Promise<FolderInfo>;
  chooseFolder(current: string | null): Promise<string | null>;
  newDeviceId(): string;
  deviceName(): string;
  inspectCreation?(folder: string): Promise<CreationInspection>;
  createSync?(folder: string, inspectionID: string | null): Promise<string | null>;
  enterPhrase(account: string, text: string, folder: string): Promise<PhraseResult>;
  unlock(account: string): Promise<boolean>;
  forget(account: string): Promise<void>;
  chainStatus(folder: string): Promise<"ok" | "missing" | "unavailable">;
  write(folder: string, scope: string, payload: string): Promise<string>;
  read(folder: string, scope: string, known: string[]): Promise<Listing>;
  remove(folder: string, scope: string, ids: string[]): Promise<void>;
  deleteChain(folder: string): Promise<void>;
  sealLocal(text: string, kind?: LocalKind, part?: string): Promise<string>;
  openLocal(sealed: string, kind?: LocalKind, part?: string): Promise<string | null>;
  useSealedPasswords?(): void;
  checkSealed?(values: SealedValue[]): Promise<boolean[]>;
  saveSealedPassword?(engineProfile: string, origin: string, username: string, sealed: string, replacing: boolean): Promise<boolean>;
  migrateLedger?(ledger: string, scopes: Record<string, string>, state: string): Promise<string | null>;
  phraseUnavailable(): Promise<"noLoginPassword" | null>;
  recoveryWords(): Promise<string[] | null>;
  qrCode(): Promise<string | null>;
  recoveryKitPreview(width: number): Promise<string | null>;
  saveRecoveryKit(format: "pdf" | "text"): Promise<string | null>;
  copyRecoveryKit(): Promise<boolean | null>;
  shareRecoveryKit(): Promise<boolean | null>;
  copyRecoveryPhrase(): Promise<boolean | null>;
  revealFolder(path: string): Promise<void>;
  readPasswords(engineProfile: string): Promise<SavedLogin[] | null>;
  readPasswordsWithMark?(engineProfile: string): Promise<MarkedLogins | null>;
};

export const SyncNative = requireOptionalNativeModule<SyncNative>("SolaraSyncAdapter");

export const folderTransport = (native: SyncNative, folder: string): Transport => ({
  write: (scope, payload) => native.write(folder, scope, payload),
  read: (scope, known) => native.read(folder, scope, known),
  remove: (scope, ids) => native.remove(folder, scope, ids),
});
