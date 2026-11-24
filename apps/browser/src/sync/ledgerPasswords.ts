import { persistenceRefused } from "../lib/persistLatch";
import { deletePassword, engineCall } from "@solara/solaracore";
import { readDocument, readDocumentResult, writeDocument } from "@solara/shell";
import { DOWNLOAD_HOLD_MS, type Adapter, type MarkedLogins, type SealedValue } from "@solara/sync";
import { engineProfile } from "../store/model";
import { digestOf, formatMark, judge, nextLedger, parseMark, readLedgerDoc, type FolderRecord, type LedgerDoc, type LedgerValue, type LocalLogin, type Mark, type StoredLedger } from "./passwordLedger";

const LEDGER_DOC = "sync-pw-ledger.json";
const MARK_KEY = "solara_sync_ledger";
const READ_INTERVAL = 30_000;
const MASS_CHANGE_AT_LEAST = 5;

type Stored = StoredLedger;
export { readLedgerDoc } from "./passwordLedger";

let warnedUnreadable = false;
function ledgerRead() {
  const read = readDocumentResult(LEDGER_DOC);
  const doc = "failure" in read ? "unreadable" : readLedgerDoc("contents" in read ? read.contents : null);
  if (doc === "unreadable" && !warnedUnreadable) {
    warnedUnreadable = true;
    console.warn("[sync] the password ledger can't be read; passwords pause until it can", "failure" in read ? read.failure : "it doesn't parse");
  }
  if (doc !== "unreadable") warnedUnreadable = false;
  return doc;
}

export const ledgerFromNewerVersion = () => ledgerRead() === "newer";
const ledgerWritable = () => typeof ledgerRead() !== "string";

const unwritable = new Set<string>();
let migrationTried = false;
export type LedgerPause = "newer" | "older" | "unreadable" | "unwritable";
export function ledgerPauseReason(syncing?: Iterable<string>): LedgerPause | null {
  if (syncing) {
    const still = new Set(syncing);
    for (const profile of unwritable) if (!still.has(profile)) unwritable.delete(profile);
  }
  const doc = ledgerRead();
  if (doc === "older") return migrationTried ? "older" : null;
  if (typeof doc === "string") return doc;
  return unwritable.size ? "unwritable" : null;
}

function writeLedgers(doc: LedgerDoc, profile: string): boolean {
  const text = JSON.stringify(doc);
  if (typeof readLedgerDoc(text) === "string") {
    if (!unwritable.has(profile)) console.warn("[sync] the password ledger wasn't written: it wouldn't read back; passwords pause");
    unwritable.add(profile);
    return false;
  }
  unwritable.delete(profile);
  if (persistenceRefused()) return false;
  writeDocument(LEDGER_DOC, text);
  return true;
}

function readLedgers(): LedgerDoc | null {
  const doc = ledgerRead();
  return typeof doc === "string" ? null : doc;
}

export async function migrateLedger(migrate: (text: string) => Promise<string | null | undefined>) {
  const text = readDocument(LEDGER_DOC);
  if (!text || readLedgerDoc(text) !== "older") return;
  migrationTried = true;
  const migrated = await migrate(text);
  if (migrated && typeof readLedgerDoc(migrated) !== "string" && readDocument(LEDGER_DOC) === text && !persistenceRefused()) writeDocument(LEDGER_DOC, migrated);
}

export type SealedPasswordCalls = {
  check: (values: SealedValue[]) => Promise<boolean[]>;
  save: (engineProfile: string, origin: string, username: string, sealed: string, replacing: boolean) => Promise<boolean>;
};

type Read = { local: Map<string, LocalLogin>; mark: Mark | null };

export type HeldPasswords = { held: () => number; resolveHeld: (choice: "restore" | "confirm") => void };

export function ledgerPasswordsAdapter(
  profileId: string,
  forced: () => boolean,
  readMarked: (engineProfile: string) => Promise<MarkedLogins | null | undefined>,
  ledgerScope: () => string,
  sealed: SealedPasswordCalls,
): Adapter & HeldPasswords {
  const profile = () => engineProfile(profileId);
  const keyOf = (origin: string, username: string) => `pw:${origin}\n${username}`;
  let lastRead = 0;
  let quietUntil = 0;
  let unconfirmed = new Set<string>();
  let claimed = new Set<string>();
  let held = new Set<string>();
  let heldDigests = new Map<string, string>();
  let confirmed = new Set<string>();
  let restoring = new Map<string, string>();
  let judgedForFolder = new Set<string>();
  let writing: Promise<boolean> = Promise.resolve(true);

  const read = async (): Promise<Read | null> => {
    const marked = await readMarked(profile());
    if (!marked) return null;
    const local = new Map<string, LocalLogin>();
    for (const l of marked.logins) local.set(keyOf(l.origin, l.username), { value: { o: l.origin, u: l.username, s: l.s }, modified: l.modified ?? l.created });
    return { local, mark: parseMark(marked.mark) };
  };

  const rejoinedFrom = (stored: Stored | null) => !!stored && stored.scope !== undefined && stored.scope !== ledgerScope();
  const ledgerNow = (): { ledger: Stored | null; fresh: boolean } | null => {
    const doc = readLedgers();
    if (!doc) return null;
    const stored = doc.profiles[profile()] ?? null;
    const fresh = rejoinedFrom(stored);
    return { ledger: fresh ? null : stored, fresh };
  };
  const saveGated = (gated: Record<string, number>): boolean => {
    const doc = readLedgers();
    if (!doc) return false;
    const stored = doc.profiles[profile()];
    if (!stored || rejoinedFrom(stored)) return true;
    if (JSON.stringify(stored.gated ?? {}) === JSON.stringify(gated)) return true;
    doc.profiles[profile()] = { ...stored, gated };
    return writeLedgers(doc, profile());
  };
  const saveHeld = (keys: Set<string>): boolean => {
    const doc = readLedgers();
    if (!doc) return false;
    const stored = doc.profiles[profile()];
    if (!stored || rejoinedFrom(stored)) return true;
    const next = [...keys].sort();
    if (JSON.stringify(stored.held ?? []) === JSON.stringify(next)) return true;
    doc.profiles[profile()] = { ...stored, held: next };
    return writeLedgers(doc, profile());
  };

  const record = (records: Map<string, FolderRecord>, keys: Iterable<string>, remote: (key: string) => unknown, stamp: (key: string) => string | undefined) => {
    for (const key of keys) {
      const h = stamp(key);
      if (h) records.set(key, { v: (remote(key) as LedgerValue | null | undefined) ?? null, h });
    }
  };

  const write = (now: Read, records: Map<string, FolderRecord>, keys: Iterable<string>, newest: number, deletedBeforeUpgrade: Iterable<string> = []) => {
    const gone = [...deletedBeforeUpgrade];
    const list = [...keys];
    writing = writing.then(async () => {
      const before = ledgerNow();
      if (!before) return false;
      const ledger = before.ledger;
      const L = Math.max(ledger?.L ?? 0, now.mark?.L ?? 0) + 1;
      const mark = { L, t: Math.max(Date.now(), newest) };
      try {
        await engineCall("ac_passwords_mark", profile(), { key: MARK_KEY, value: formatMark(mark) });
      } catch (error) {
        console.warn("[sync] couldn't write Login Data's mark; the ledger waits", error);
        return false;
      }
      const doc = readLedgers();
      if (!doc) return false;
      const latest = doc.profiles[profile()] ?? null;
      const kept = latest && !rejoinedFrom(latest) ? latest : null;
      doc.profiles[profile()] = { ...nextLedger(ledger, now.local, records, mark, list, gone), scope: ledgerScope(), held: kept?.held ?? [], gated: kept?.gated ?? {} };
      return writeLedgers(doc, profile());
    });
    return writing;
  };

  return {
    held: () => held.size,
    resolveHeld: (choice) => {
      if (choice === "confirm") confirmed = new Set([...confirmed, ...held]);
      else for (const key of held) restoring.set(key, heldDigests.get(key) ?? "");
      held = new Set();
      saveHeld(held);
      lastRead = 0;
    },
    prefix: "pw:",
    publishOnlyAfterPull: true,
    ownsItsChanges: true,
    extract: async (base, _queued, _now, _known, remote, stamp, downloading, agreedKeys, unapplied) => {
      const now = Date.now();
      if (!ledgerWritable()) return null;
      if ((now < quietUntil || now - lastRead < READ_INTERVAL) && !forced()) return null;
      await writing;
      const here = await read();
      if (!here) return null;
      const localValues = [...here.local];
      const opens = await sealed.check(localValues.map(([, l]) => l.value));
      const unopened = new Set(localValues.filter((_, i) => opens[i] !== true).map(([key]) => key));
      lastRead = now;
      const decided = ledgerNow();
      if (!decided) return null;
      const { fresh, ledger } = decided;
      const records = new Map<string, FolderRecord>();
      const firstLedger = !ledger;
      record(records, new Set([...here.local.keys(), ...Object.keys(ledger?.keys ?? {}), ...(firstLedger ? (agreedKeys?.() ?? []) : [])]), remote, stamp);
      const j = judge(here.local, fresh ? null : here.mark, ledger, records, now, (key) => base(key) as LedgerValue | undefined, (key) => !!unapplied?.(key));
      const deletedBeforeUpgrade = [...j.deletedBeforeUpgrade];
      const recordOpens = await sealed.check(deletedBeforeUpgrade.map((key) => records.get(key)!.v!));
      for (const [i, key] of deletedBeforeUpgrade.entries()) if (recordOpens[i] !== true) j.deletedBeforeUpgrade.delete(key);
      j.claims = j.claims.filter((c) => !unopened.has(c.key));
      for (const key of unopened) {
        j.apply.delete(key);
        j.seed.delete(key);
      }
      const keptHeld = new Set(ledger?.held ?? []);
      if (j.mode === "rebuild") {
        for (const key of keptHeld) {
          j.apply.delete(key);
          j.seed.delete(key);
        }
      }
      const lost = (c: (typeof j.claims)[number]) => {
        const r = records.get(c.key);
        return !!r && !c.afterRecord && Math.min(c.at, now) <= parseInt(r.h.slice(0, 9), 36);
      };
      const winning = j.claims.filter((c) => !lost(c));
      for (const c of j.claims) if (lost(c)) j.apply.add(c.key);
      const known = Object.keys(ledger?.keys ?? {}).length;
      for (const [key, digest] of restoring) if (!unopened.has(key) && digestOf(here.local.get(key)?.value) === digest) j.apply.add(key);
      const changes = winning.filter((c) => ledger?.keys[c.key] && !confirmed.has(c.key) && !j.apply.has(c.key));
      const stillHeld = [...keptHeld].filter((key) => changes.some((c) => c.key === key) || (j.mode === "rebuild" && digestOf(here.local.get(key)?.value) !== digestOf(records.get(key)?.v)));
      const mass = changes.length > MASS_CHANGE_AT_LEAST && changes.length > known / 2;
      const nextHeld = new Set([...stillHeld, ...(mass ? changes.map((c) => c.key) : [])]);
      const live = winning.filter((c) => !nextHeld.has(c.key) && !j.apply.has(c.key));
      const deletions = live.filter((c) => !c.v).map((c) => c.key);
      const firstGated: Record<string, number> = {};
      for (const key of deletions) firstGated[key] = ledger?.gated?.[key] ?? now;
      const busy = downloading();
      const gated = new Set(busy ? deletions.filter((key) => now - firstGated[key]! < DOWNLOAD_HOLD_MS) : []);
      if (!saveHeld(nextHeld)) return null;
      if (!saveGated(busy ? Object.fromEntries(Object.entries(firstGated).filter(([key]) => gated.has(key) || ledger?.gated?.[key] !== undefined)) : {})) return null;
      restoring = new Map();
      confirmed = new Set();
      held = nextHeld;
      heldDigests = new Map([...held].map((key) => [key, digestOf(here.local.get(key)?.value)]));
      claimed = new Set(live.map((c) => c.key));
      judgedForFolder = new Set(j.apply);
      const byKey = new Map(live.filter((c) => !gated.has(c.key)).map((c) => [c.key, c]));
      const seeds = [...j.seed].filter((k) => (j.mode !== "consistent" || ledger?.keys[k]?.d[0] !== digestOf(here.local.get(k)?.value)));
      if ((j.mode !== "consistent" || seeds.length) && !(await write(here, records, seeds, 0, j.deletedBeforeUpgrade))) return null;
      return {
        values: new Map([...byKey.values()].filter((c) => c.v).map((c) => [c.key, c.v!])),
        ignore: (key) => !byKey.has(key),
        republish: (key) => byKey.has(key),
        remove: new Set([...byKey.values()].filter((c) => !c.v).map((c) => c.key)),
        stamp: (key) => {
          const c = byKey.get(key);
          return c ? { at: c.at, after: c.afterRecord } : undefined;
        },
        reapply: j.apply,
        published: (keys) => {
          for (const key of keys) claimed.delete(key);
          void write(here, records, keys, 0);
        },
      };
    },
    editedAt: () => undefined,
    apply: async (visible, changed) => {
      if (!ledgerWritable()) return false;
      await writing;
      const before = await read();
      if (!before) return false;
      const decided = ledgerNow();
      if (!decided) return false;
      const ledger = decided.ledger;
      const changedHere = (key: string) => {
        const have = before.local.get(key);
        if (!have || judgedForFolder.has(key)) return false;
        const entry = ledger?.keys[key];
        return entry ? digestOf(have.value) !== entry.d[0] : digestOf(have.value) !== digestOf(visible.get(key) as LedgerValue | undefined);
      };
      const haveHere = [...changed].filter((key) => before.local.has(key));
      const opens = await sealed.check(haveHere.map((key) => before.local.get(key)!.value));
      const unopened = new Set(haveHere.filter((_, i) => opens[i] !== true));
      const kept = new Set([...changed].filter((key) => unopened.has(key) || claimed.has(key) || held.has(key) || changedHere(key)));
      const refused = new Set<string>();
      for (const key of changed) {
        if (kept.has(key)) continue;
        const v = visible.get(key) as LedgerValue | undefined;
        const have = before.local.get(key)?.value;
        const [origin, username] = [key.slice(3, key.indexOf("\n")), key.slice(key.indexOf("\n") + 1)];
        let ok = true;
        if (v) {
          if (have?.s === v.s) continue;
          ok = await sealed.save(profile(), v.o, v.u, v.s, !!have);
        } else if (have) {
          ok = (await deletePassword(profile(), origin, username)) && ok;
        }
        if (!ok) refused.add(key);
      }
      const wanted = [...changed].filter((k) => !kept.has(k) && !refused.has(k));
      const confirmed = (now: Read | null, k: string) => !!now && (visible.get(k) as LedgerValue | undefined)?.s === now.local.get(k)?.value.s;
      let latest: Read | null = null;
      let settled = false;
      for (let i = 0; i < 20 && !settled; i++) {
        latest = await read();
        settled = wanted.every((k) => confirmed(latest, k));
        if (!settled) await new Promise((r) => setTimeout(r, 250));
      }
      const failing = new Set(wanted.filter((k) => !confirmed(latest, k)));
      if ([...failing].some((k) => !unconfirmed.has(k))) quietUntil = Date.now() + 30_000;
      unconfirmed = failing;
      if (!latest) return false;
      const written = new Set(wanted.filter((k) => confirmed(latest, k)));
      if (written.size) {
        const records = new Map<string, FolderRecord>();
        for (const key of written) records.set(key, { v: (visible.get(key) as LedgerValue | undefined) ?? null, h: "" });
        const newest = Math.max(0, ...[...written].map((k) => latest!.local.get(k)?.modified ?? 0));
        if (!(await write(latest, records, written, newest))) return false;
      }
      return written;
    },
  };
}
