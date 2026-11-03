import { canonical } from "./canon.ts";
import { hlcAfter, hlcWall, type Clock, type HLC } from "./hlc.ts";

export type Origin = [device: string, seq: number];
export type SyncRecord = { h: HLC; v: unknown; o: Origin };
export type Op = { k: string; h: HLC; v: unknown };

export type LogFile = { v: 1; kind: "log"; device: string; seq: number; at: number; ops: Op[] };
export type SnapshotFile = {
  v: 1;
  kind: "snapshot";
  device: string;
  at: number;
  vv: Record<string, number>;
  seen: Record<string, number>;
  records: Record<string, SyncRecord>;
};
export type SyncFile = LogFile | SnapshotFile;

type FileMeta = { d: string; k: "log" | "snapshot" | "bad"; s?: number; vv?: Record<string, number>; at: number };

export type ScopeState = {
  records: Record<string, SyncRecord>;
  base: Record<string, string>;
  unapplied: string[];
  vv: Record<string, number>;
  extra: Record<string, number[]>;
  files: Record<string, FileMeta>;
  damaged: Record<string, number>;
  pendingSince?: Record<string, number>;
  seq: number;
  outbox: Op[];
  journal?: LogFile[];
  seen: Record<string, number>;
  joined: boolean;
  awaitRemote?: boolean;
  applyAs?: Record<string, "joined" | "joining">;
  snapshotAt: number;
  pending: number;
};

export const emptyScope = (): ScopeState => ({
  records: {},
  base: {},
  unapplied: [],
  vv: {},
  extra: {},
  files: {},
  damaged: {},
  seq: 0,
  outbox: [],
  seen: {},
  joined: false,
  snapshotAt: 0,
  pending: 0,
});

export interface Transport {
  write(scope: string, payload: string): Promise<string>;
  read(scope: string, known: string[]): Promise<Listing>;
  remove(scope: string, ids: string[]): Promise<void>;
}

export type Listing = {
  files: { id: string; payload: string }[];
  pending: string[];
  damaged: { id: string; age: number }[];
  present: string[];
};

export type Extraction = {
  values: Map<string, unknown>;
  ignore?: (key: string) => boolean;
  republish?: (key: string) => boolean;
  published?: (keys: Set<string>) => void;
  stamp?: (key: string) => { at: number; after?: HLC | null } | undefined;
  remove?: Set<string>;
  reapply?: Set<string>;
};

export type ApplyRecords = {
  known(key: string): boolean;
  now: number;
  horizon: number;
  joined: boolean;
};

export class ApplyRefusal extends Error {
  readonly refused: Set<string>;

  constructor(refused: Set<string>, cause?: unknown) {
    super(`Sync records refused: ${[...refused].join(", ")}`, { cause });
    this.name = "ApplyRefusal";
    this.refused = refused;
  }
}

export type ApplyResult = boolean | void | Set<string>;

export interface Adapter {
  prefix: string;
  extract(
    base: (key: string) => unknown,
    queued: (key: string) => boolean,
    now: number,
    known: (key: string) => boolean,
    remote: (key: string) => unknown,
    stamp: (key: string) => HLC | undefined,
    downloading: () => boolean,
    agreedKeys?: () => string[],
    unapplied?: (key: string) => boolean,
  ): Extraction | null | Promise<Extraction | null>;
  apply(visible: Map<string, unknown>, changed: Set<string>, base: (key: string) => unknown, records: ApplyRecords): ApplyResult | Promise<ApplyResult>;
  editedAt?(value: unknown): number | undefined;
  adoptRemoteOnJoin?: boolean;
  publishAfterPull?: boolean;
  publishOnlyAfterPull?: boolean;
  ownsItsChanges?: boolean;
}

export type ScopeOptions = {
  expired?: (key: string, value: unknown, now: number) => boolean;
  tombstoneTTL?: number;
  compactAfterFiles?: number;
  compactInterval?: number;
  pruneGrace?: number;
  damagedGiveUp?: number;
  persist?: (batches: LogFile[]) => Promise<void>;
  writtenKeysOnly?: boolean;
  beforeApply?: (keys: Set<string>) => void;
  extracted?: (prefix: string, keys: Set<string>, ignore: (key: string) => boolean) => void;
};

const DEFAULTS: Required<Omit<ScopeOptions, "persist" | "beforeApply" | "extracted">> = {
  expired: () => false,
  tombstoneTTL: 45 * 86_400_000,
  compactAfterFiles: 40,
  compactInterval: 10 * 60_000,
  pruneGrace: 60 * 60_000,
  damagedGiveUp: 86_400_000,
  writtenKeysOnly: false,
};

export const covered = (vv: Record<string, number>, [device, seq]: Origin) => (vv[device] ?? 0) >= seq;

function markApplied(state: ScopeState, device: string, seq: number) {
  if (covered(state.vv, [device, seq])) return;
  const extra = new Set(state.extra[device] ?? []);
  extra.add(seq);
  let top = state.vv[device] ?? 0;
  while (extra.delete(top + 1)) top++;
  state.vv[device] = top;
  if (extra.size) state.extra[device] = [...extra].sort((a, b) => a - b);
  else delete state.extra[device];
}

const isApplied = (state: ScopeState, [device, seq]: Origin) =>
  covered(state.vv, [device, seq]) || (state.extra[device]?.includes(seq) ?? false);

function see(state: ScopeState, device: string, at: number) {
  if (!(device in state.seen) || at > state.seen[device]!) state.seen[device] = at;
}

function mergeRecord(state: ScopeState, key: string, record: SyncRecord, clock: Clock): boolean {
  clock.observe(record.h);
  const current = state.records[key];
  if (current && current.h >= record.h) return false;
  state.records[key] = record;
  return true;
}

function ingestLog(state: ScopeState, file: LogFile, clock: Clock, changed: Set<string>) {
  see(state, file.device, file.at);
  if (isApplied(state, [file.device, file.seq])) return;
  for (const op of file.ops) {
    if (mergeRecord(state, op.k, { h: op.h, v: op.v, o: [file.device, file.seq] }, clock)) changed.add(op.k);
  }
  markApplied(state, file.device, file.seq);
}

export function ingestSnapshot(state: ScopeState, file: SnapshotFile, clock: Clock, changed: Set<string>) {
  for (const [device, at] of Object.entries(file.seen)) see(state, device, at);
  see(state, file.device, file.at);
  for (const [key, record] of Object.entries(file.records)) {
    if (!(key in state.records) && isApplied(state, record.o)) continue;
    if (mergeRecord(state, key, record, clock)) changed.add(key);
  }
  for (const [key, record] of Object.entries(state.records)) {
    if (!(key in file.records) && covered(file.vv, record.o)) {
      delete state.records[key];
      changed.add(key);
    }
  }
  for (const [device, seq] of Object.entries(file.vv)) {
    if (seq > (state.vv[device] ?? 0)) {
      state.vv[device] = seq;
      const extra = (state.extra[device] ?? []).filter((s) => s > seq);
      for (let top = seq; extra[0] === top + 1; top++) state.vv[device] = extra.shift()!;
      if (extra.length) state.extra[device] = extra;
      else delete state.extra[device];
    }
  }
}

export function visible(state: ScopeState, prefix: string): Map<string, unknown> {
  const out = new Map<string, unknown>();
  for (const [key, record] of Object.entries(state.records)) {
    if (record.v !== null && key.startsWith(prefix)) out.set(key, record.v);
  }
  return out;
}

const parseBase = (json: string | undefined) => (json === undefined ? undefined : (JSON.parse(json) as unknown));

const settling = new WeakMap<ScopeState, (() => void)[]>();
const waitingAfterPull = new WeakMap<ScopeState, boolean>();
const downloadingRecently = new WeakMap<ScopeState, boolean>();
const extractedHook = new WeakMap<ScopeState, (prefix: string, keys: Set<string>, ignore: (key: string) => boolean) => void>();
export const DOWNLOAD_HOLD_MS = 10 * 60_000;

function settleWhenDurable(state: ScopeState, settle: () => void) {
  const queue = settling.get(state);
  if (queue) queue.push(settle);
  else settling.set(state, [settle]);
}

function settleDurable(state: ScopeState) {
  const queue = settling.get(state);
  if (!queue) return;
  settling.delete(state);
  for (const settle of queue) settle();
}

function stampedHLC(clock: Clock, device: string, stamped: { at: number; after?: HLC | null }): HLC {
  const at = clock.at(stamped.at);
  const after = stamped.after ? hlcAfter(stamped.after, device) : null;
  const h = after && after > at ? after : at;
  clock.observe(h);
  return h;
}

async function publishAdapter(state: ScopeState, adapter: Adapter, clock: Clock, device: string, now: number, beforePull = false): Promise<Set<string>> {
  const published = new Set<string>();
  if (beforePull && adapter.publishOnlyAfterPull) return published;
  if (adapter.adoptRemoteOnJoin && !state.joined) return published;
  if (adapter.publishAfterPull && waitingAfterPull.get(state) !== false) return published;
  let pending: Set<string> | null = null;
  const queued = (key: string) => (pending ??= new Set([...state.outbox, ...(state.journal ?? []).flatMap((f) => f.ops)].map((op) => op.k))).has(key);
  const extraction = await adapter.extract((key) => parseBase(state.base[key]), queued, now, (key) => key in state.records, (key) => state.records[key]?.v, (key) => state.records[key]?.h, () => downloadingRecently.get(state) !== false, () => Object.keys(state.base).filter((key) => key.startsWith(adapter.prefix) && !state.unapplied.includes(key)), (key) => state.unapplied.includes(key));
  if (!extraction) return published;
  extractedHook.get(state)?.(adapter.prefix, new Set(extraction.values.keys()), (key) => !!extraction.ignore?.(key));
  const put = (key: string, value: unknown) => {
    const known = state.records[key];
    const stamped = extraction.stamp?.(key);
    const editedAt = !known && value !== null ? adapter.editedAt?.(value) : undefined;
    const h = stamped ? stampedHLC(clock, device, stamped) : editedAt !== undefined ? clock.at(editedAt) : clock.tick();
    if (known && known.h >= h) return;
    state.records[key] = { h, v: value, o: [device, state.seq + 1] };
    state.outbox.push({ k: key, h, v: value });
    published.add(key);
  };
  for (const [key, value] of extraction.values) {
    if (value === null || value === undefined) throw new Error(`[sync] ${key}: a live value can't be null`);
    const json = canonical(value);
    if (state.base[key] === json && !extraction.republish?.(key)) continue;
    state.base[key] = json;
    put(key, value);
  }
  for (const key of Object.keys(state.base)) {
    if (!key.startsWith(adapter.prefix) || extraction.values.has(key) || extraction.ignore?.(key)) continue;
    delete state.base[key];
    put(key, null);
  }
  for (const key of extraction.remove ?? []) {
    if (!key.startsWith(adapter.prefix) || extraction.values.has(key) || !state.records[key] || state.records[key]!.v === null) continue;
    delete state.base[key];
    put(key, null);
  }
  for (const key of extraction.reapply ?? []) if (key.startsWith(adapter.prefix) && !state.unapplied.includes(key)) state.unapplied.push(key);
  const { published: settle } = extraction;
  if (settle && published.size) settleWhenDurable(state, () => settle(published));
  return published;
}

export async function publish(state: ScopeState, adapters: Adapter[], clock: Clock, device: string, now = Date.now()): Promise<Set<string>> {
  const published = new Set<string>();
  for (const adapter of adapters) for (const key of await publishAdapter(state, adapter, clock, device, now, true)) published.add(key);
  return published;
}

export async function flush(state: ScopeState, transport: Transport, scope: string, device: string, now: number, options: ScopeOptions = {}) {
  if (state.outbox.length) {
    state.seq++;
    (state.journal ??= []).push({ v: 1, kind: "log", device, seq: state.seq, at: now, ops: state.outbox });
    state.outbox = [];
  }
  if (!state.journal?.length) return;
  if (options.persist) {
    await options.persist(state.journal);
    settleDurable(state);
  }
  while (state.journal.length) {
    const file = state.journal[0]!;
    const id = await transport.write(scope, JSON.stringify(file));
    state.files[id] = { d: file.device, k: "log", s: file.seq, at: file.at };
    state.journal.shift();
    markApplied(state, file.device, file.seq);
    see(state, file.device, now);
  }
  delete state.journal;
  settleDurable(state);
}

export function restoreJournal(state: ScopeState, batches: LogFile[], clock: Clock, written = 0) {
  const saved = state.seq;
  for (const file of [...batches].sort((a, b) => a.seq - b.seq)) {
    if (file.seq <= state.seq) continue;
    if (file.seq === saved + 1) state.outbox = [];
    for (const op of file.ops) {
      mergeRecord(state, op.k, { h: op.h, v: op.v, o: [file.device, file.seq] }, clock);
      if (op.v === null) delete state.base[op.k];
      else state.base[op.k] = canonical(op.v);
    }
    state.seq = file.seq;
    if (file.seq <= written) markApplied(state, file.device, file.seq);
    else (state.journal ??= []).push(file);
  }
  state.seq = Math.max(state.seq, written);
}

export const writtenSeq = (state: ScopeState) => state.seq - (state.journal?.length ?? 0);

export async function pull(state: ScopeState, transport: Transport, scope: string, clock: Clock, now: number, options: ScopeOptions = {}) {
  const { damagedGiveUp } = { ...DEFAULTS, ...options };
  const listing = await transport.read(scope, Object.keys(state.files));
  const changed = new Set<string>();
  const parsed: { id: string; file: SyncFile }[] = [];
  const bad = (id: string) => {
    state.damaged[id] = Math.min(state.damaged[id] ?? now, now);
    if (now - state.damaged[id]! > damagedGiveUp) {
      state.files[id] = { d: "", k: "bad", at: now };
      delete state.damaged[id];
    }
  };
  for (const { id, payload } of listing.files) {
    try {
      const file = JSON.parse(payload) as SyncFile;
      if (file.v !== 1 || (file.kind !== "log" && file.kind !== "snapshot")) throw new Error("unknown file");
      parsed.push({ id, file });
    } catch {
      bad(id);
    }
  }
  for (const { id } of listing.damaged) bad(id);
  parsed.sort((a, b) => (a.file.kind === b.file.kind ? 0 : a.file.kind === "snapshot" ? -1 : 1));
  for (const { id, file } of parsed) {
    if (file.kind === "snapshot") {
      ingestSnapshot(state, file, clock, changed);
      state.files[id] = { d: file.device, k: "snapshot", vv: file.vv, at: file.at };
    } else {
      ingestLog(state, file, clock, changed);
      state.files[id] = { d: file.device, k: "log", s: file.seq, at: file.at };
    }
    delete state.damaged[id];
  }
  const present = new Set(listing.present);
  for (const id of Object.keys(state.files)) if (!present.has(id)) delete state.files[id];
  for (const id of Object.keys(state.damaged)) if (!present.has(id)) delete state.damaged[id];
  state.pending = listing.pending.length;
  const pendingSince: Record<string, number> = {};
  for (const id of listing.pending) pendingSince[id] = Math.min(state.pendingSince?.[id] ?? now, now);
  if (listing.pending.length) state.pendingSince = pendingSince;
  else delete state.pendingSince;
  const downloading = Object.values(pendingSince).some((at) => now - at <= damagedGiveUp);
  waitingAfterPull.set(state, downloading || Object.keys(state.damaged).length > 0);
  downloadingRecently.set(state, [...Object.values(pendingSince), ...Object.values(state.damaged)].some((at) => now - at <= DOWNLOAD_HOLD_MS));
  return changed;
}

async function applyAdapter(state: ScopeState, adapter: Adapter, keys: Set<string>, now: number, horizon: number, writtenKeysOnly: boolean, beforeApply?: (keys: Set<string>) => void): Promise<Set<string>> {
  const mine = new Set([...keys].filter((k) => k.startsWith(adapter.prefix)));
  if (!mine.size) return mine;
  const view = visible(state, adapter.prefix);
  const applyAs = (state.applyAs ??= {});
  applyAs[adapter.prefix] ??= state.joined ? "joined" : "joining";
  let ok: ApplyResult = false;
  let refused: Set<string> | undefined;
  beforeApply?.(mine);
  try {
    ok = await adapter.apply(view, mine, (key) => parseBase(state.base[key]), { known: (key) => key in state.records, now, horizon, joined: applyAs[adapter.prefix] === "joined" });
  } catch (error) {
    if (error instanceof ApplyRefusal) {
      refused = error.refused;
      ok = true;
    }
    console.warn("[sync]", {
      prefix: adapter.prefix,
      outcome: refused ? "apply-refused" : "apply-failed",
      changed: mine.size,
      refused: refused?.size ?? 0,
    });
  }
  if (ok === false) return mine;
  applyAs[adapter.prefix] = "joined";
  const written = writtenKeysOnly && ok instanceof Set ? ok : mine;
  const left = new Set<string>();
  for (const key of mine) {
    if (refused?.has(key) || !written.has(key)) left.add(key);
    else if (view.has(key)) state.base[key] = canonical(view.get(key));
    else delete state.base[key];
  }
  return left;
}

export async function compact(state: ScopeState, transport: Transport, scope: string, device: string, now: number, options: ScopeOptions = {}, force = false) {
  const o = { ...DEFAULTS, ...options };
  const count = Object.keys(state.files).length;
  const newestSnapshot = Math.max(state.snapshotAt, ...Object.values(state.files).filter((f) => f.k === "snapshot").map((f) => f.at));
  if (!force && (count <= o.compactAfterFiles || now - newestSnapshot < o.compactInterval)) return false;
  await flush(state, transport, scope, device, now, options);
  const records: Record<string, SyncRecord> = {};
  const tombstoneTTL = Object.keys(state.extra).length ? 2 * o.tombstoneTTL : o.tombstoneTTL;
  for (const [key, record] of Object.entries(state.records)) {
    const drop = record.v === null ? now - hlcWall(record.h) > tombstoneTTL : o.expired(key, record.v, now);
    if (drop) delete state.records[key];
    else records[key] = record;
  }
  const vv = { ...state.vv };
  const file: SnapshotFile = { v: 1, kind: "snapshot", device, at: now, vv, seen: { ...state.seen }, records };
  const id = await transport.write(scope, JSON.stringify(file));
  state.files[id] = { d: device, k: "snapshot", vv, at: now };
  state.snapshotAt = now;
  const dominated = (other: Record<string, number>) => Object.entries(other).every(([d, s]) => (vv[d] ?? 0) >= s);
  const prune = Object.entries(state.files)
    .filter(([fileId, f]) => {
      if (fileId === id || now - f.at < o.pruneGrace) return false;
      if (f.k === "log") return covered(vv, [f.d, f.s ?? Infinity]);
      if (f.k === "snapshot") return dominated(f.vv ?? {});
      return false;
    })
    .map(([fileId]) => fileId);
  if (prune.length) {
    await transport.remove(scope, prune);
    for (const fileId of prune) delete state.files[fileId];
  }
  return true;
}

export type CycleResult = { published: number; changed: number; pending: number; compacted: boolean };

export async function syncScope(args: {
  scope: string;
  state: ScopeState;
  transport: Transport;
  adapters: Adapter[];
  clock: Clock;
  device: string;
  now?: () => number;
  options?: ScopeOptions;
}): Promise<CycleResult> {
  const { scope, state, transport, adapters, clock, device, options } = args;
  if (options?.extracted) extractedHook.set(state, options.extracted);
  else extractedHook.delete(state);
  const now = args.now ?? Date.now;
  let published = (await publish(state, adapters, clock, device, now())).size;
  await flush(state, transport, scope, device, now(), options);
  const changed = await pull(state, transport, scope, clock, now(), options);
  const keys = new Set([...state.unapplied, ...changed]);
  const unapplied: string[] = [];
  for (const adapter of adapters) {
    const late = await publishAdapter(state, adapter, clock, device, now());
    published += late.size;
    for (const key of state.unapplied) if (key.startsWith(adapter.prefix)) keys.add(key);
    for (const key of late) keys.delete(key);
    unapplied.push(...(await applyAdapter(state, adapter, keys, now(), 2 * (options?.tombstoneTTL ?? DEFAULTS.tombstoneTTL), !!options?.writtenKeysOnly, options?.beforeApply)));
  }
  state.unapplied = [...unapplied, ...[...keys].filter((k) => !adapters.some((a) => k.startsWith(a.prefix)))];
  if (!state.awaitRemote || Object.keys(state.seen).some((d) => d !== device)) {
    state.joined = true;
    delete state.awaitRemote;
  }
  await flush(state, transport, scope, device, now(), options);
  const compacted = await compact(state, transport, scope, device, now(), options);
  return { published, changed: changed.size, pending: state.pending, compacted };
}
