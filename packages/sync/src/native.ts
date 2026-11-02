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
  addListener?(event: "pairingInstallationReady", listener: () => void): { remove(): void };
  invalidatePairing?(reason: "stop" | "folder" | "forget" | "rekey"): void;
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

export type PairingInstallationDTO = {
  transaction: string;
  folder: string;
  folderIdentity: string;
  cid: string;
  deviceId: string;
  account: string;
  generation: number;
  stopGeneration: number;
  phase: "prepared" | "key-saved";
  route: "settings" | "onboarding";
  priorState: string;
};
export type PairingRequestDTO = Pick<PairingInstallationDTO, "folder" | "folderIdentity" | "cid" | "generation" | "stopGeneration"> & { handle: string };
export type PairingOperationDTO = {
  operationId: string;
  transaction: string;
  generation: number;
  key: string;
  desired: unknown;
  before: unknown;
  localValue: unknown;
  disposition: "applied" | "local-choice" | "opt-out";
};
export type PairingReceiptDTO = Pick<PairingOperationDTO, "operationId" | "transaction" | "generation" | "key" | "disposition"> & { value: unknown };
export type PairingTransport = {
  consumeInstallation(handle: string, priorState: string): Promise<PairingInstallationDTO>;
  saveInstallation(installation: PairingInstallationDTO): Promise<void>;
  readInstallation(installation: PairingInstallationDTO): Promise<PairingInstallationDTO>;
  recoverInstallation(): Promise<PairingInstallationDTO | null>;
  stopInstallation(installation: PairingInstallationDTO | null, generation: number): Promise<void>;
  reconcileApplied(operation: PairingOperationDTO): Promise<PairingReceiptDTO | null>;
  checkpointApplied(operation: PairingOperationDTO): Promise<PairingReceiptDTO>;
  acknowledgePairingInitialization(transaction: string, generation: number): Promise<void>;
  acknowledgePairingReady(transaction: string, generation: number): Promise<void>;
  installationRequest(): Promise<PairingRequestDTO | null>;
};

type PairingModule = Required<Pick<SyncNative, "addListener" | "invalidatePairing">> & {
  consumePairingInstallation(handle: string, priorState: string): Promise<unknown>;
  savePairingInstallation(installation: PairingInstallationDTO): Promise<void>;
  readPairingInstallation(installation: PairingInstallationDTO): Promise<unknown>;
  recoverPairingInstallation(): Promise<unknown>;
  stopPairingInstallation(installation: PairingInstallationDTO | null, generation: number): Promise<void>;
  reconcilePairingApplied(operation: PairingOperationDTO): Promise<unknown>;
  checkpointPairingApplied(operation: PairingOperationDTO): Promise<unknown>;
  acknowledgePairingInitialization(transaction: string, generation: number): Promise<void>;
  acknowledgePairingReady(transaction: string, generation: number): Promise<void>;
  pairingInstallationRequest(): Promise<unknown>;
};

const pairingFailure = () => new Error("Pairing is unavailable.");
const pairingCheck = (condition: unknown): void => { if (!condition) throw pairingFailure(); };
const pairingInteger = (value: unknown, minimum = 0) => typeof value === "number" && Number.isSafeInteger(value) && value >= minimum;
const pairingText = (value: unknown, maximum = 4096) => typeof value === "string" && value.length > 0 && value.length <= maximum && !value.includes("\0");
const pairingHex = (value: unknown, length: number) => typeof value === "string" && new RegExp(`^[a-f0-9]{${length}}$`).test(value);
const pairingDevice = (value: unknown) => typeof value === "string" && /^[a-z2-7]{25}[aeimquy4]$/.test(value) && value !== "a".repeat(26);
const pairingPrior = (value: unknown) => typeof value === "string" && /^[0-9]{1,8}:[a-z0-9]{1,32}$/.test(value);
const pairingFields = (value: unknown, keys: string[]): Record<string, unknown> => {
  pairingCheck(value !== null && typeof value === "object" && !Array.isArray(value));
  const record = value as Record<string, unknown>;
  pairingCheck([Object.prototype, null].includes(Object.getPrototypeOf(record)) && Object.keys(record).length === keys.length && keys.every((key) => Object.hasOwn(record, key)));
  pairingCheck(Object.values(Object.getOwnPropertyDescriptors(record)).every((entry) => "value" in entry));
  return record;
};
const pairingInstallation = (value: unknown): PairingInstallationDTO => {
  const v = pairingFields(value, ["transaction", "folder", "folderIdentity", "cid", "deviceId", "account", "generation", "stopGeneration", "phase", "route", "priorState"]);
  pairingCheck(pairingHex(v.transaction, 64) && pairingText(v.folder) && pairingText(v.folderIdentity) && pairingHex(v.cid, 32) && pairingDevice(v.deviceId) && v.account === v.deviceId && pairingInteger(v.generation, 1) && pairingInteger(v.stopGeneration) && ["prepared", "key-saved"].includes(v.phase as string) && ["settings", "onboarding"].includes(v.route as string) && pairingPrior(v.priorState));
  return { ...v } as PairingInstallationDTO;
};
const pairingRequest = (value: unknown): PairingRequestDTO => {
  const v = pairingFields(value, ["handle", "folder", "folderIdentity", "cid", "generation", "stopGeneration"]);
  pairingCheck(pairingText(v.handle, 256) && pairingText(v.folder) && pairingText(v.folderIdentity) && pairingHex(v.cid, 32) && pairingInteger(v.generation, 1) && pairingInteger(v.stopGeneration));
  return { ...v } as PairingRequestDTO;
};
const pairingValue = (value: unknown, depth = 0, budget = { nodes: 4096 }): unknown => {
  pairingCheck(depth <= 16 && --budget.nodes >= 0);
  if (value === null || typeof value === "boolean") return value;
  if (typeof value === "string") { pairingCheck(value.length <= 16384); return value; }
  if (typeof value === "number") { pairingCheck(Number.isFinite(value)); return value; }
  if (Array.isArray(value)) return value.map((item) => pairingValue(item, depth + 1, budget));
  pairingCheck(typeof value === "object" && value !== null);
  const keys = Object.keys(value as object);
  pairingCheck(keys.length <= 256 && keys.every((key) => key !== "__proto__" && !/^(?:e|sas|code|salt|claimedname|privatekey|approval|root)$/i.test(key)));
  const record = pairingFields(value, keys);
  return Object.fromEntries(keys.map((key) => [key, pairingValue(record[key], depth + 1, budget)]));
};
const pairingOperation = (value: unknown): PairingOperationDTO => {
  const v = pairingFields(value, ["operationId", "transaction", "generation", "key", "desired", "before", "localValue", "disposition"]);
  pairingCheck(pairingText(v.operationId, 512) && pairingHex(v.transaction, 64) && pairingInteger(v.generation, 1) && typeof v.key === "string" && /^(?:set:[a-zA-Z][a-zA-Z0-9]*|(?:prof|pth|share):[a-zA-Z0-9_-]{1,128}(?::angle)?)$/.test(v.key) && ["applied", "local-choice", "opt-out"].includes(v.disposition as string));
  return { ...v, desired: pairingValue(v.desired), before: pairingValue(v.before), localValue: pairingValue(v.localValue) } as PairingOperationDTO;
};
const pairingReceipt = (value: unknown): PairingReceiptDTO => {
  const v = pairingFields(value, ["operationId", "transaction", "generation", "key", "disposition", "value"]);
  const { value: local, ...identity } = v;
  const operation = pairingOperation({ ...identity, desired: local, before: local, localValue: local });
  return { operationId: operation.operationId, transaction: operation.transaction, generation: operation.generation, key: operation.key, disposition: operation.disposition, value: pairingValue(v.value) };
};

export function pairingNativeTransport(value: unknown = SyncNative): PairingTransport | null {
  if (!value || typeof value !== "object") return null;
  const native = value as PairingModule;
  const names: (keyof PairingModule)[] = ["addListener", "invalidatePairing", "consumePairingInstallation", "savePairingInstallation", "readPairingInstallation", "recoverPairingInstallation", "stopPairingInstallation", "reconcilePairingApplied", "checkpointPairingApplied", "acknowledgePairingInitialization", "acknowledgePairingReady", "pairingInstallationRequest"];
  if (!names.every((name) => typeof native[name] === "function")) return null;
  const guarded = async <T>(work: () => Promise<T>): Promise<T> => { try { return await work(); } catch { throw pairingFailure(); } };
  const acknowledge = (name: "acknowledgePairingInitialization" | "acknowledgePairingReady", transaction: string, generation: number) => guarded(async () => { pairingCheck(pairingHex(transaction, 64) && pairingInteger(generation, 1)); await native[name](transaction, generation); });
  return {
    consumeInstallation: (handle, priorState) => guarded(async () => { pairingCheck(pairingText(handle, 256) && pairingPrior(priorState)); return pairingInstallation(await native.consumePairingInstallation(handle, priorState)); }),
    saveInstallation: (installation) => guarded(async () => { await native.savePairingInstallation(pairingInstallation(installation)); }),
    readInstallation: (installation) => guarded(async () => pairingInstallation(await native.readPairingInstallation(pairingInstallation(installation)))),
    recoverInstallation: () => guarded(async () => { const result = await native.recoverPairingInstallation(); return result === null ? null : pairingInstallation(result); }),
    stopInstallation: (installation, generation) => guarded(async () => { pairingCheck(pairingInteger(generation)); await native.stopPairingInstallation(installation === null ? null : pairingInstallation(installation), generation); }),
    reconcileApplied: (operation) => guarded(async () => { const result = await native.reconcilePairingApplied(pairingOperation(operation)); return result === null ? null : pairingReceipt(result); }),
    checkpointApplied: (operation) => guarded(async () => pairingReceipt(await native.checkpointPairingApplied(pairingOperation(operation)))),
    acknowledgePairingInitialization: (transaction, generation) => acknowledge("acknowledgePairingInitialization", transaction, generation),
    acknowledgePairingReady: (transaction, generation) => acknowledge("acknowledgePairingReady", transaction, generation),
    installationRequest: () => guarded(async () => { const result = await native.pairingInstallationRequest(); return result === null ? null : pairingRequest(result); }),
  };
}
