export type NativePaneFallbackTarget = { rootTag: number; targetGeneration: number; lease: number; shown: boolean };
export type NativePaneFallbackSnapshot = { windowGeneration: number; revision: number; targets: Record<string, NativePaneFallbackTarget> };
export type NativePaneFallbackOffer = { windowGeneration: number; revision: number; targets: Record<string, Omit<NativePaneFallbackTarget, "lease">> };
type Receipt = { tabId: string; generation: number; lease: number; version: number };
const EMPTY: Record<string, NativePaneFallbackTarget> = {};

export class NativePaneFallbackFeed {
  private entries = new Map<string, NativePaneFallbackSnapshot>();
  private owners = new Map<string, object>();
  private pending = new Map<string, Map<string, Receipt>>();
  private versions = new Map<string, number>();
  private listeners = new Set<() => void>();
  private generation: (windowId: string) => number;
  private release: (windowId: string, tabId: string, generation: number, lease: number) => void;

  constructor(generation: (windowId: string) => number, release: (windowId: string, tabId: string, generation: number, lease: number) => void = () => {}) {
    this.generation = generation;
    this.release = release;
  }

  begin(windowId: string, owner: object) {
    this.owners.set(windowId, owner);
  }

  end(windowId: string, owner: object) {
    if (this.owners.get(windowId) !== owner) return;
    const current = this.entries.get(windowId);
    if (current) this.queueSnapshot(windowId, current);
    this.owners.delete(windowId);
    this.entries.delete(windowId);
    this.drain(windowId);
    this.changed(windowId);
  }

  admit(windowId: string, offered: NativePaneFallbackOffer, confirm: () => NativePaneFallbackSnapshot | null): boolean {
    if (!this.eligible(windowId, offered)) return false;
    const acquired = confirm();
    return acquired ? this.accept(windowId, acquired) : false;
  }

  private rejectAcquired(windowId: string, snapshot: NativePaneFallbackSnapshot): false {
    if (this.queueSnapshot(windowId, snapshot)) this.changed(windowId);
    if (!this.owners.has(windowId)) this.drain(windowId);
    return false;
  }

  accept(windowId: string, snapshot: NativePaneFallbackSnapshot): boolean {
    if (!this.eligible(windowId, snapshot)) return this.rejectAcquired(windowId, snapshot);
    const current = this.entries.get(windowId);
    this.entries.set(windowId, snapshot);
    if (current) {
      for (const [tabId, target] of Object.entries(current.targets)) {
        const next = snapshot.targets[tabId];
        if (next?.shown && next.targetGeneration === target.targetGeneration && next.lease === target.lease) continue;
        this.queue(windowId, tabId, target.targetGeneration, target.lease);
      }
    }
    for (const [tabId, target] of Object.entries(snapshot.targets)) {
      if (!target.shown) this.queue(windowId, tabId, target.targetGeneration, target.lease);
    }
    this.changed(windowId);
    return true;
  }

  private eligible(windowId: string, snapshot: NativePaneFallbackOffer): boolean {
    if (!this.owners.has(windowId) || snapshot.windowGeneration <= 0 || snapshot.windowGeneration !== this.generation(windowId)) return false;
    const current = this.entries.get(windowId);
    return current?.windowGeneration !== snapshot.windowGeneration || current.revision < snapshot.revision;
  }

  read(windowId: string) {
    const entry = this.entries.get(windowId);
    return entry?.windowGeneration === this.generation(windowId) ? entry.targets : EMPTY;
  }

  version(windowId: string) {
    return this.versions.get(windowId) ?? 0;
  }

  flush(windowId: string, owner: object, committedVersion: number) {
    if (this.owners.get(windowId) === owner) this.drain(windowId, committedVersion);
  }

  private queue(windowId: string, tabId: string, generation: number, lease: number): boolean {
    let pending = this.pending.get(windowId);
    if (!pending) this.pending.set(windowId, pending = new Map());
    const key = JSON.stringify([tabId, generation, lease]);
    if (pending.has(key)) return false;
    pending.set(key, { tabId, generation, lease, version: this.version(windowId) + 1 });
    return true;
  }

  private queueSnapshot(windowId: string, snapshot: NativePaneFallbackSnapshot): boolean {
    let queued = false;
    for (const [tabId, target] of Object.entries(snapshot.targets)) queued = this.queue(windowId, tabId, target.targetGeneration, target.lease) || queued;
    return queued;
  }

  private drain(windowId: string, committedVersion = Infinity) {
    const pending = this.pending.get(windowId);
    const current = this.read(windowId);
    for (const [key, receipt] of pending?.entries() ?? []) {
      if (receipt.version > committedVersion) continue;
      pending?.delete(key);
      const target = current[receipt.tabId];
      if (target?.shown && target.targetGeneration === receipt.generation && target.lease === receipt.lease) continue;
      this.release(windowId, receipt.tabId, receipt.generation, receipt.lease);
    }
    if (!pending?.size) this.pending.delete(windowId);
  }

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  };

  private changed(windowId: string) {
    this.versions.set(windowId, this.version(windowId) + 1);
    for (const listener of this.listeners) listener();
  }
}
