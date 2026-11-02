import { canonical, type ScopeState, type SyncRecord } from "@solara/sync";
import { isObject, readableScope } from "./readable";
import { digest } from "./notes";

export type PairingInstallation = {
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

export type PairingRequest = Pick<PairingInstallation, "folder" | "folderIdentity" | "cid" | "generation" | "stopGeneration"> & { handle: string };
export type PairingDisposition = "applied" | "local-choice" | "opt-out";
export type PairingOperation = {
  operationId: string;
  transaction: string;
  generation: number;
  key: string;
  desired: unknown;
  before: unknown;
  localValue: unknown;
  disposition: PairingDisposition;
};
export type PairingReceipt = Pick<PairingOperation, "operationId" | "transaction" | "generation" | "key" | "disposition"> & { value: unknown };
export interface PairingNative {
  acknowledgePairingInitialization(transaction: string, generation: number): Promise<void>;
  acknowledgePairingReady(transaction: string, generation: number): Promise<void>;
  consumeInstallation(handle: string, priorState: string): Promise<PairingInstallation>;
  saveInstallation(installation: PairingInstallation): Promise<void>;
  readInstallation(installation: PairingInstallation): Promise<PairingInstallation>;
  recoverInstallation(): Promise<PairingInstallation | null>;
  stopInstallation(installation: PairingInstallation | null, stopGeneration: number): Promise<void>;
  reconcileApplied(operation: PairingOperation): Promise<PairingReceipt | null>;
  checkpointApplied(operation: PairingOperation): Promise<PairingReceipt>;
}

export type BootstrapPhase = "awaiting-profile" | "binding-persisted" | "applying" | "ready" | "onboarding-completed" | "stopped";
export type Bootstrap = {
  phase: BootstrapPhase;
  transaction: string | null;
  generation: number;
  checkpoint?: { name: string; digest: string };
};
export type BootstrapLink = { syncId: string; enabled: boolean; retire?: boolean; themeAdopting?: true };
export type BindingEvidence = { record: SyncRecord; digest: string; files: { id: string; meta: ScopeState["files"][string] }[] };
export type BindingPlan = {
  defaultKey: string;
  links: Record<string, BootstrapLink>;
  evidence: Record<string, BindingEvidence>;
  operations: PairingOperation[];
  outcomes: Record<string, PairingReceipt>;
};
export type BootstrapReplica = { transaction: string; generation: number; revision: number; app: ScopeState; plan?: BindingPlan; superseded?: BindingPlan[] };

const text = (v: unknown): v is string => typeof v === "string" && v.length > 0;
const integer = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= 0;
export const priorStateOf = (json: string) => `${json.length}:${digest(json)}`;
export const installationValid = (v: unknown): v is PairingInstallation => isObject(v) &&
  typeof v.transaction === "string" && /^[a-f0-9]{64}$/.test(v.transaction) &&
  text(v.folder) && text(v.folderIdentity) && typeof v.cid === "string" && /^[a-f0-9]{32}$/.test(v.cid) &&
  text(v.deviceId) && v.account === v.deviceId && integer(v.generation) && v.generation > 0 && integer(v.stopGeneration) &&
  (v.phase === "prepared" || v.phase === "key-saved") && (v.route === "settings" || v.route === "onboarding") &&
  text(v.priorState);

export const sameInstallation = (a: PairingInstallation, b: PairingInstallation) =>
  ["transaction", "folder", "folderIdentity", "cid", "deviceId", "account", "generation", "stopGeneration", "route", "priorState"].every((k) => a[k as keyof PairingInstallation] === b[k as keyof PairingInstallation]);

export function bootstrapValid(value: unknown): boolean {
  if (!isObject(value) || value.v !== 2 || !integer(value.stopGeneration) || !isObject(value.bootstrap)) return false;
  const b = value.bootstrap;
  if (!integer(b.generation) || !["awaiting-profile", "binding-persisted", "applying", "ready", "onboarding-completed", "stopped"].includes(b.phase as string)) return false;
  if (b.phase === "stopped") {
    if (value.enabled !== false || value.joining !== false || value.stopGeneration < 1) return false;
    if (value.installation === undefined) return b.transaction === null && value.joinTransaction === undefined;
    return installationValid(value.installation) && value.joinTransaction === value.installation.transaction && b.transaction === value.installation.transaction && b.generation === value.installation.generation && value.stopGeneration > value.installation.stopGeneration && value.folder === value.installation.folder && value.deviceId === value.installation.deviceId;
  }
  if (!installationValid(value.installation)) return false;
  const installed = value.installation;
  if (value.enabled !== true || value.joinTransaction !== installed.transaction || b.transaction !== installed.transaction || b.generation !== installed.generation || value.stopGeneration !== installed.stopGeneration || value.folder !== installed.folder || value.deviceId !== installed.deviceId) return false;
  if (value.joining !== !(b.phase === "ready" || b.phase === "onboarding-completed")) return false;
  if (b.checkpoint === undefined) return b.phase === "awaiting-profile";
  return isObject(b.checkpoint) && text(b.checkpoint.name) && new RegExp(`^sync-bootstrap-${installed.transaction}-[1-9][0-9]*\\.nns$`).test(b.checkpoint.name) && text(b.checkpoint.digest);
}

export const replicaValid = (v: unknown, installation: PairingInstallation): v is BootstrapReplica => isObject(v) &&
  v.transaction === installation.transaction && v.generation === installation.generation && integer(v.revision) && readableScope(v.app);

export function receiptMatches(operation: PairingOperation, receipt: PairingReceipt | null): receipt is PairingReceipt {
  return !!receipt && receipt.operationId === operation.operationId && receipt.transaction === operation.transaction && receipt.generation === operation.generation && receipt.key === operation.key && receipt.disposition === operation.disposition && canonical(receipt.value) === canonical(operation.localValue);
}

export function evidenceOf(app: ScopeState, key: string): BindingEvidence | null {
  const record = app.records[key];
  if (!record || !Array.isArray(record.o) || !text(record.h)) return null;
  const files = Object.entries(app.files).filter(([, meta]) => (meta.k === "log" ? meta.d === record.o[0] && meta.s === record.o[1] : meta.k === "snapshot" && (meta.vv?.[record.o[0]] ?? 0) >= record.o[1])).map(([id, meta]) => ({ id, meta }));
  if (!files.length) return null;
  return { record: JSON.parse(JSON.stringify(record)) as SyncRecord, digest: digest(canonical(record)), files };
}

export function planCurrent(app: ScopeState, plan: BindingPlan): boolean {
  return Object.entries(plan.evidence).every(([key, evidence]) => canonical(app.records[key]) === canonical(evidence.record) && digest(canonical(app.records[key])) === evidence.digest);
}
