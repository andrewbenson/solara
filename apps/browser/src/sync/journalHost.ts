import { persistenceRefused } from "../lib/persistLatch";
import { readDocument, writeDocument } from "@solara/shell";
import type { ScopeState } from "@solara/sync";
import { GEN_DOC, openJournal, type EditJournal } from "./editJournal";
import { nativeSyncAnchor, nativeSyncAnchorSupported, setNativeSyncAnchor } from "@solara/store";
import { nativeOwnsWorkspace, nativeStoreActive } from "../store/nativeStore";
import { syncRedesign } from "./redesignSwitch";

const SESSION_DOC = "session.json";

let journal: EditJournal | null = null;
function changed() {
  writeNativeAnchor();
}

const NATIVE_SETTINGS_KEYS = ["set:", "devmode:"];
const anchoredNatively = () => nativeStoreActive() && nativeSyncAnchorSupported();
const inNativeStore = (key: string) => anchoredNatively() && (nativeOwnsWorkspace() || NATIVE_SETTINGS_KEYS.some((p) => key.startsWith(p)));

type Anchor = { journalG?: number; journalT?: number; everSeen?: SavedSeen };

function parseAnchor(value: unknown): Anchor | null {
  try {
    const anchor = typeof value === "string" ? JSON.parse(value) : value;
    return anchor && typeof anchor === "object" ? (anchor as Anchor) : null;
  } catch {
    return null;
  }
}

const savedNativeAnchor = () => (anchoredNatively() ? parseAnchor(nativeSyncAnchor()) : null);
let nativeAnchorText: string | null = null;

function anchorFields(j: EditJournal | null, seen: SavedSeen): Anchor {
  return {
    ...(j?.g ? { journalG: j.g } : {}),
    ...(j?.lastInStepT ? { journalT: j.lastInStepT } : {}),
    ...(Object.keys(seen.scopes).length ? { everSeen: seen } : {}),
  };
}

function writeJournalDocument(name: string, text: string) {
  if (persistenceRefused()) return;
  writeDocument(name, text);
  if (journal && name === GEN_DOC) writeNativeAnchor();
}

function writeNativeAnchor() {
  if (!syncRedesign.on || !anchoredNatively()) return;
  seenKeys();
  const text = JSON.stringify(anchorFields(journal, compactSeen(inNativeStore)));
  if (text === nativeAnchorText) return;
  if (setNativeSyncAnchor(text)) nativeAnchorText = text;
}
let everSeen: Record<string, Record<string, [string, number]>> | null = null;

function savedSession(): { journalG?: unknown; everSeen?: unknown } | null {
  try {
    return JSON.parse(readDocument(SESSION_DOC) ?? "null");
  } catch {
    return null;
  }
}

const numberOr0 = (value: unknown) => (typeof value === "number" ? value : 0);

function storeG(): number {
  return Math.max(numberOr0(savedSession()?.journalG), numberOr0(savedNativeAnchor()?.journalG));
}

function storeT(): number {
  const session = numberOr0((savedSession() as { journalT?: unknown } | null)?.journalT);
  if (!anchoredNatively()) return session;
  const native = numberOr0(savedNativeAnchor()?.journalT);
  return nativeOwnsWorkspace() ? native : Math.min(session, native);
}

type SavedSeen = { devices: string[]; scopes: Record<string, Record<string, [number, number]>> };

function mergeSeen(into: Record<string, Record<string, [string, number]>>, saved: Partial<SavedSeen> | undefined, keep: (key: string) => boolean) {
  if (!saved || !Array.isArray(saved.devices) || !saved.scopes || typeof saved.scopes !== "object") return;
  for (const [scope, keys] of Object.entries(saved.scopes)) {
    const out = (into[scope] ??= {});
    for (const [key, [device, seq]] of Object.entries(keys)) if (keep(key) && saved.devices[device] !== undefined) out[key] = [saved.devices[device]!, seq];
  }
}

function seenKeys() {
  if (everSeen) return everSeen;
  everSeen = {};
  const native = savedNativeAnchor();
  const nativeHasAnchor = !!native;
  mergeSeen(everSeen, savedSession()?.everSeen as Partial<SavedSeen> | undefined, (key) => !nativeHasAnchor || !inNativeStore(key));
  mergeSeen(everSeen, native?.everSeen, inNativeStore);
  if (anchoredNatively() && !nativeHasAnchor) queueMicrotask(writeNativeAnchor);
  return everSeen;
}

function compactSeen(keep: (key: string) => boolean = () => true): SavedSeen {
  const devices: string[] = [];
  const index = new Map<string, number>();
  const scopes: SavedSeen["scopes"] = {};
  for (const [scope, keys] of Object.entries(everSeen ?? {})) {
    const out: Record<string, [number, number]> = {};
    for (const [key, [device, seq]] of Object.entries(keys)) {
      if (!keep(key)) continue;
      let i = index.get(device);
      if (i === undefined) index.set(device, (i = devices.push(device) - 1));
      out[key] = [i, seq];
    }
    if (Object.keys(out).length) scopes[scope] = out;
  }
  return { devices, scopes };
}

export function noteSeen(scope: string, key: string, origin: [string, number]) {
  if (!syncRedesign.on || key.startsWith("bm:")) return;
  const keys = (seenKeys()[scope] ??= {});
  const was = keys[key];
  if (was && was[0] === origin[0] && was[1] === origin[1]) return;
  keys[key] = origin;
  changed();
}

export const seenOrigin = (scope: string, key: string): [string, number] | undefined => (syncRedesign.on ? seenKeys()[scope]?.[key] : undefined);

export const SEEN_TOMBSTONE_PRUNE_MS = 90 * 86_400_000;

export type SeenPruneInput = {
  extractedThisCycle: boolean;
  localHas: boolean;
  localIgnored: boolean;
  record: { v: unknown; wall: number } | undefined;
  now: number;
};

export const prunableSeen = ({ extractedThisCycle, localHas, localIgnored, record, now }: SeenPruneInput) =>
  extractedThisCycle && !localHas && !localIgnored && (!record || (record.v === null && now - record.wall > SEEN_TOMBSTONE_PRUNE_MS));

export function pruneSeen(scope: string, prune: (key: string) => boolean) {
  const keys = seenKeys()[scope];
  if (!keys) return;
  let dropped = false;
  for (const key of Object.keys(keys)) if (prune(key)) {
    delete keys[key];
    dropped = true;
  }
  if (dropped) changed();
}

export function forgetSeenScope(scope: string) {
  if (seenKeys()[scope]) delete seenKeys()[scope];
}

export function editJournal(): EditJournal | null {
  if (!syncRedesign.on) return null;
  if (!journal) {
    journal = openJournal({ read: readDocument, write: writeJournalDocument }, { storeG: storeG(), storeT: storeT() });
    if (journal.lost && nativeStoreActive() && !savedNativeAnchor()) journal.fallback = "nothing";
  }
  return journal;
}

export function forgetEditJournal() {
  journal = null;
  everSeen = null;
  nativeAnchorText = null;
}

export function journalAnchor(): Anchor {
  if (!syncRedesign.on) return {};
  const j = editJournal()!;
  seenKeys();
  return anchorFields(j, compactSeen((key) => !inNativeStore(key)));
}

export function noteInStep(scopes: Record<string, ScopeState>, now: number, waitsFor: (key: string) => boolean = () => true) {
  const j = editJournal();
  if (!j) return;
  const entries = Object.entries(scopes);
  if (entries.some(([, s]) => s.unapplied.some(waitsFor) || s.pending || Object.keys(s.damaged).length || s.outbox.length || s.journal?.length)) return;
  j.inStepAt(now, Object.fromEntries(entries.map(([scope, s]) => [scope, { ...s.vv }])));
  changed();
}
