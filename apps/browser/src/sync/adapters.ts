import { deletePassword, savePassword } from "@solara/solaracore";
import { ackBookmarkFacts, bookmarkWriterErrorCode, bookmarkWriterSnapshot, bookmarkWriterState, clearBookmarkFacts, observeBookmarkRecords, replaceBookmarkDocumentWithRecords, type BookmarkFactClear } from "@solara/settings";
import { nativeAddHistoryVisits, nativeDeleteHistoryUrls } from "@solara/settings";
import { ApplyRefusal, assignPositions, canonical, editHLC, hlcDevice, SyncNative, type Adapter, type SavedLogin, type SyncRecord } from "@solara/sync";
import { bookmarkUuidFor, isBookmarkUuid, rootIdsFor } from "../store/bookmarks";
import { MAX_HISTORY, MAX_VISIT_TIMES } from "../store/history";
import { useBrowser } from "../store/browser";
import { engineProfile } from "../store/model";
import { isPeekTab } from "../store/peek";
import { fromSync } from "../store/pinOrderChoices";
import { engineIdOf, requireGeneratedProfileIdentity } from "../store/profiles";
import { DEFAULT_PROFILE_ID, DEFAULT_SETTINGS, type Settings } from "../store/settings";
import { sanitizeTheme } from "../lib/profileTheme";
import { developerModeOf } from "../lib/developerMode";
import { fromLegacy } from "../legacy";
import type { BookmarkNode, Bookmarks, HistoryEntry, Profile, ProfileTheme } from "../store/types";
import { syncRedesign } from "./redesignSwitch";

const store = () => useBrowser.getState();
const asSyncApply = <T>(apply: () => T): T => (syncRedesign.on ? fromSync(apply) : apply());

export function applySyncedProfilePatch(id: string, patch: Partial<Pick<Profile, "name" | "color" | "icon" | "theme">>): void {
  requireGeneratedProfileIdentity(store().profiles[id]!, id);
  asSyncApply(() => store().updateProfile(id, patch));
}

export const inTodaysNames = (adapter: Adapter): Adapter => ({
  ...adapter,
  apply: (visible, changed, base, records) =>
    adapter.apply(new Map([...visible].map(([key, value]) => [key, fromLegacy(value)])), changed, (key) => fromLegacy(base(key)), records),
});

export const SYNCED_SETTINGS = [
  "warnBeforeQuitting",
  "warnBeforeClosingWindow",
  "searchEngine",
  "customSearchUrl",
  "customSearchEngines",
  "searchSuggestions",
  "showSelectionSearch",
  "commandBarPreference",
  "tabLayout",
  "hideToolbarWhileScrolling",
  "showSidebarButton",
  "showClearButton",
  "balancedTopApps",
  "pinnedTabIconRing",
  "selectedTabGlow",
  "pageScrollBars",
  "fadeUnloadedTabs",
  "showUnreadBadges",
  "sleepInactiveTabs",
  "sleepTabsAfterMinutes",
  "keepAwakeSites",
  "warnBeforeClosingTabGroup",
  "newTabPosition",
  "newTabButtonPosition",
  "newTabOpens",
  "warnBeforeClosingLastTab",
  "undoReopensClosedTab",
  "warnBeforeMovingTabsToProfile",
  "tabReorderHaptics",
  "extendWebsiteColor",
  "cmdClickCreatesTabGroup",
  "optShiftClickOpensInGroup",
  "peekModifier",
  "splitLinkModifier",
  "autoGroupMeetingTabs",
  "cleanUpInactiveTabsAfterHours",
  "mutedSites",
  "autoPictureInPicture",
  "videoUpscaling",
  "sidebarMediaControls",
  "hoverCardMemoryUsage",
  "showFullUrl",
  "bookmarksBar",
  "appearance",
  "addressBar",
  "commandBarPlacement",
  "shortcuts",
  "shortcutPrecedence",
] as const satisfies readonly (keyof Settings)[];

export const settingsAdapter: Adapter = {
  prefix: "set:",
  adoptRemoteOnJoin: true,
  extract: (base) => {
    const settings = store().settings;
    const chosen = new Set(settings.chosen ?? []);
    const inferred = new Set(settings.inferred ?? []);
    const filledIn = (name: (typeof SYNCED_SETTINGS)[number], value: unknown) => {
      if (!inferred.has(name) || JSON.stringify(value) !== JSON.stringify(DEFAULT_SETTINGS[name])) return false;
      const last = base(`set:${name}`) as { v?: unknown } | undefined;
      return last === undefined || last.v === null || last.v === undefined;
    };
    const values = new Map<string, unknown>();
    for (const name of SYNCED_SETTINGS) {
      const value = settings[name] as unknown;
      if (!chosen.has(name) || value === undefined || (value === null && DEFAULT_SETTINGS[name] !== null) || filledIn(name, value)) continue;
      values.set(`set:${name}`, { v: value });
    }
    return { values, ignore: (key) => !values.has(key) };
  },
  apply: (visible, changed) => {
    const patch: Record<string, unknown> = {};
    for (const key of changed) {
      const name = key.slice(4);
      const record = visible.get(key) as { v: unknown } | undefined;
      if (!record || !(SYNCED_SETTINGS as readonly string[]).includes(name)) continue;
      const value = record.v;
      if (value === undefined || (value === null && DEFAULT_SETTINGS[name as keyof Settings] !== null)) continue;
      patch[name] = value;
    }
    if (Object.keys(patch).length) asSyncApply(() => store().updateSettings(patch as Partial<Settings>, { fromSync: true }));
  },
};

export function settingsToReapply(records: Record<string, SyncRecord>): string[] {
  const settings = store().settings;
  const chosen = new Set(settings.chosen ?? []);
  return SYNCED_SETTINGS.flatMap((name) => {
    const key = `set:${name}`;
    const value = (fromLegacy(records[key]?.v) as { v?: unknown } | null | undefined)?.v;
    if (chosen.has(name) || value === undefined || (value === null && DEFAULT_SETTINGS[name] !== null)) return [];
    return canonical(value) === canonical(settings[name]) ? [] : [key];
  });
}

export type ProfileRecord = { n: string; c: Profile["color"]; i: string | null; d?: true; th?: ProfileTheme | null };

export type ProfileThemeRecord = { t: ProfileTheme } | { preset: true };

export type ThemeAngleRecord = { a?: number; d?: number };

export const themeAngleKey = (syncId: string) => `pth:${syncId}:angle`;

function withoutAngles({ angle: _angle, dark, ...theme }: ProfileTheme): ProfileTheme {
  if (!dark) return theme;
  const { angle: _darkAngle, ...darkLook } = dark;
  return { ...theme, dark: darkLook };
}

function anglesOf(theme: ProfileTheme): ThemeAngleRecord {
  return { ...(theme.angle !== undefined ? { a: theme.angle } : {}), ...(theme.dark?.angle !== undefined ? { d: theme.dark.angle } : {}) };
}

export function themeFromRecord(record: unknown, angles?: unknown): Pick<Profile, "theme"> | null {
  if (!record || typeof record !== "object") return null;
  if ("preset" in record && record.preset === true) return { theme: null };
  const theme = "t" in record ? sanitizeTheme(record.t) : null;
  if (!theme) return null;
  if (!angles || typeof angles !== "object") return { theme };
  const { a, d } = angles as Record<string, unknown>;
  const look = withoutAngles(theme);
  return { theme: sanitizeTheme({ ...look, angle: a, ...(look.dark ? { dark: { ...look.dark, angle: d } } : {}) }) };
}

export function legacyThemeOf(record: ProfileRecord): Pick<Profile, "theme"> | null {
  const theme = record.th ? sanitizeTheme(record.th) : null;
  return theme ? { theme } : null;
}

export function profilesAdapter(links: () => Record<string, { syncId: string; themeAdopting?: true }>): Adapter {
  const linked = () => Object.entries(links()).filter(([id]) => store().profiles[id]);
  return {
    prefix: "prof:",
    adoptRemoteOnJoin: true,
    extract: (base, _queued, _now, known, remote, _stamp, _downloading, _agreedKeys, unapplied) => {
      const values = new Map<string, unknown>();
      const all = links();
      for (const [id, { syncId, themeAdopting }] of linked()) {
        const p = store().profiles[id]!;
        const sharesSyncedData = !!p.dataId && p.dataId !== id && !!all[p.dataId] && !!store().profiles[p.dataId];
        if (sharesSyncedData && !known(`share:${syncId}`)) continue;
        const key = `prof:${syncId}`;
        const metadata: ProfileRecord = {
          n: p.name,
          c: p.color,
          i: p.icon,
          ...(id === DEFAULT_PROFILE_ID ? { d: true } : {}),
        };
        const pending = themeAdopting || unapplied?.(key);
        const previous = pending && canonical(base(key)) !== canonical(metadata) ? remote?.(key) as ProfileRecord | null | undefined : undefined;
        values.set(key, { ...metadata, ...(previous?.th !== undefined ? { th: previous.th } : {}) } satisfies ProfileRecord);
      }
      const mine = new Set(values.keys());
      return { values, ignore: (key) => !mine.has(key) };
    },
    apply: (visible, changed, _base, records) => {
      const refused = new Set<string>();
      let cause: unknown;
      for (const [id, { syncId }] of linked()) {
        const key = `prof:${syncId}`;
        const record = visible.get(key) as ProfileRecord | undefined;
        if (!record || !changed.has(key)) continue;
        try {
          const legacy = store().profiles[id]!.theme === undefined && !records.known(`pth:${syncId}`) ? legacyThemeOf(record) : null;
          applySyncedProfilePatch(id, { name: record.n, color: record.c, icon: record.i, ...legacy });
        } catch (error) {
          refused.add(key);
          cause ??= error;
        }
      }
      if (refused.size) throw new ApplyRefusal(refused, cause);
    },
  };
}

export function profileThemesAdapter(
  links: () => Record<string, { syncId: string; themeAdopting?: true }>,
  records: () => Record<string, { v: unknown }> | undefined,
  adopted: (profileId: string) => void = () => {},
): Adapter {
  const linked = () => Object.entries(links()).filter(([id]) => store().profiles[id]);
  const unapplied = (key: string, base: (key: string) => unknown) => {
    const record = records()?.[key];
    return !!record && record.v !== null && canonical(record.v) !== canonical(base(key) ?? null);
  };
  return {
    prefix: "pth:",
    adoptRemoteOnJoin: true,
    extract: (base, _queued, _now, known) => {
      const values = new Map<string, unknown>();
      for (const [id, { syncId, themeAdopting }] of linked()) {
        const theme = store().profiles[id]!.theme;
        const key = `pth:${syncId}`;
        const angleKey = themeAngleKey(syncId);
        if (theme === undefined || themeAdopting || unapplied(key, base) || unapplied(angleKey, base)) continue;
        values.set(key, (theme ? { t: withoutAngles(theme) } : { preset: true }) satisfies ProfileThemeRecord);
        const angles = theme ? anglesOf(theme) : {};
        if (Object.keys(angles).length || known(angleKey)) values.set(angleKey, angles satisfies ThemeAngleRecord);
      }
      const mine = new Set(values.keys());
      return { values, ignore: (key) => !mine.has(key) };
    },
    apply: (visible, changed) => {
      const refused = new Set<string>();
      let cause: unknown;
      for (const [id, { syncId }] of linked()) {
        const key = `pth:${syncId}`;
        const angleKey = themeAngleKey(syncId);
        if (!changed.has(key) && !changed.has(angleKey)) continue;
        const patch = themeFromRecord(visible.get(key), visible.get(angleKey));
        if (!patch) continue;
        try {
          applySyncedProfilePatch(id, patch);
          adopted(id);
        } catch (error) {
          for (const pending of [key, angleKey]) if (changed.has(pending)) refused.add(pending);
          cause ??= error;
        }
      }
      if (refused.size) throw new ApplyRefusal(refused, cause);
    },
  };
}

export type ShareRecord = { o: string };

type ShareLink = { syncId: string; enabled: boolean; retire?: boolean };

export function sharedDataAdapter(links: () => Record<string, ShareLink>): Adapter {
  return {
    prefix: "share:",
    adoptRemoteOnJoin: true,
    publishAfterPull: true,
    extract: (_base, _queued, _now, known) => {
      const all = links();
      const synced = (id: string) => !!store().profiles[id] && !!all[id]?.enabled && !all[id]?.retire;
      const values = new Map<string, unknown>();
      for (const [id, link] of Object.entries(all)) {
        const ownerId = store().profiles[id]?.dataId;
        if (!synced(id) || !ownerId || ownerId === id || !synced(ownerId)) continue;
        const key = `share:${link.syncId}`;
        if (!known(key)) values.set(key, { o: all[ownerId]!.syncId } satisfies ShareRecord);
      }
      return { values, ignore: (key) => !values.has(key) };
    },
    apply: () => true,
  };
}

export type DeviceRecord = { n: string };

export function deviceAdapter(deviceId: string, name: () => string, retired = false): Adapter {
  return {
    prefix: "dev:",
    extract: () => ({
      values: retired ? new Map() : new Map([[`dev:${deviceId}`, { n: name() } satisfies DeviceRecord]]),
      ignore: (key) => key !== `dev:${deviceId}`,
    }),
    apply: () => true,
  };
}

type BookmarkValue = { k: "u" | "f"; p: string; t: string; u?: string; a: number; pos: string };

function bookmarkValues(b: Bookmarks, roots: { bar: string; other: string }, base: (key: string) => unknown): Map<string, unknown> {
  const values = new Map<string, unknown>();
  const keyOf = (id: string) => {
    if (id === roots.bar) return "bar";
    if (id === roots.other) return "other";
    const key = b.nodes[id]?.syncKey;
    return key && bookmarkUuidFor(key) === id ? key : id;
  };
  const seen = new Set<string>();
  const walk = (folderId: string) => {
    const folder = b.nodes[folderId];
    if (folder?.kind !== "folder" || seen.has(folderId)) return;
    seen.add(folderId);
    const parent = keyOf(folderId);
    const children = folder.children.filter((id) => b.nodes[id]);
    const positions = assignPositions(
      children.map((id) => {
        const known = base(`bm:${keyOf(id)}`) as BookmarkValue | undefined;
        return known?.p === parent && typeof known.pos === "string" ? known.pos : undefined;
      }),
    );
    children.forEach((id, i) => {
      const node = b.nodes[id]!;
      values.set(`bm:${keyOf(id)}`, {
        k: node.kind === "url" ? "u" : "f",
        p: parent,
        t: node.title,
        ...(node.kind === "url" ? { u: node.url } : {}),
        a: node.addedAt,
        pos: positions[i]!,
      } satisfies BookmarkValue);
      if (node.kind === "folder") walk(id);
    });
  };
  walk(roots.bar);
  walk(roots.other);
  return values;
}

function syncedBookmarkNodes(b: Bookmarks, roots: { bar: string; other: string }, visible: Map<string, unknown>): Record<string, BookmarkNode> {
  const values = new Map([...visible].map(([k, v]) => [bookmarkUuidFor(k.slice(3)), v as BookmarkValue]));
  const keys = new Map([...visible.keys()].map((k) => [bookmarkUuidFor(k.slice(3)), k.slice(3)]));
  const rootOf = (key: string) => (key === "bar" ? roots.bar : key === "other" ? roots.other : null);
  const parentOf = new Map<string, string>();
  for (const [id, v] of values) {
    const root = rootOf(v.p);
    const parent = root ? null : bookmarkUuidFor(v.p);
    parentOf.set(id, root ?? (parent && values.get(parent)?.k === "f" ? parent : roots.other));
  }
  for (const id of [...values.keys()].sort()) {
    const seen = new Set<string>([id]);
    for (let at = parentOf.get(id)!; parentOf.has(at); at = parentOf.get(at)!) {
      if (seen.has(at)) {
        parentOf.set(id, roots.other);
        break;
      }
      seen.add(at);
    }
  }
  const children = new Map<string, string[]>([[roots.bar, []], [roots.other, []]]);
  for (const id of values.keys()) children.set(parentOf.get(id)!, [...(children.get(parentOf.get(id)!) ?? []), id]);
  const byPosition = (a: string, z: string) => {
    const pa: unknown = values.get(a)!.pos;
    const pz: unknown = values.get(z)!.pos;
    const placedA = typeof pa === "string";
    const placedZ = typeof pz === "string";
    if (placedA !== placedZ) return placedA ? -1 : 1;
    if (placedA && placedZ && pa !== pz) return (pa as string) < (pz as string) ? -1 : 1;
    const ka = keys.get(a)!;
    const kz = keys.get(z)!;
    return ka < kz ? -1 : ka > kz ? 1 : 0;
  };
  const nodes: Record<string, BookmarkNode> = { ...b.nodes };
  const drop = (id: string) => {
    const node = nodes[id];
    if (node?.kind === "folder") node.children.forEach(drop);
    if (id !== roots.bar && id !== roots.other) delete nodes[id];
  };
  drop(roots.bar);
  drop(roots.other);
  for (const [id, v] of values) {
    const old = b.nodes[id];
    const key = keys.get(id)!;
    const syncKey = isBookmarkUuid(key) ? {} : { syncKey: key };
    nodes[id] =
      v.k === "u"
        ? { kind: "url", id, parentId: parentOf.get(id)!, title: v.t, url: v.u ?? "", favicon: old?.kind === "url" ? old.favicon : null, addedAt: v.a, ...syncKey }
        : { kind: "folder", id, parentId: parentOf.get(id)!, title: v.t, children: [], addedAt: v.a, ...syncKey };
  }
  for (const [parent, ids] of children) {
    const folder = nodes[parent];
    if (folder?.kind === "folder") nodes[parent] = { ...folder, children: ids.sort(byPosition) };
  }
  return nodes;
}

type BookmarkSyncContext = { device: string; link: () => string | null; opened?: () => void };

export function bookmarksAdapter(profileId: string, sync?: BookmarkSyncContext): Adapter {
  if (bookmarkWriterState().state === "owned") return nativeBookmarksAdapter(profileId, sync);
  return { prefix: "bm:", extract: () => null, apply: () => false };
}

function nativeBookmarksAdapter(profileId: string, sync?: BookmarkSyncContext): Adapter {
  sync?.opened?.();
  const link = sync?.link() ?? null;
  const opened = bookmarkWriterSnapshot(profileId);
  const binding = { engine: opened.engine, generation: opened.generation };
  let extractedRevision: string | undefined;
  let replacementClears: BookmarkFactClear[] = [];
  const current = () => {
    if (bookmarkWriterState().state !== "owned") throw new Error("native bookmark sync is paused");
    const snapshot = bookmarkWriterSnapshot(profileId);
    if (snapshot.engine !== binding.engine || snapshot.generation !== binding.generation) throw new Error("the native bookmark owner changed during this sync");
    return { snapshot, document: JSON.parse(snapshot.document) as Bookmarks };
  };
  const rootsOf = (b: Bookmarks) => b.roots[profileId] ?? rootIdsFor(binding.engine);
  return {
    prefix: "bm:",
    publishOnlyAfterPull: true,
    originalEditTime: true,
    extract: (base, _queued, _now, _known, _remote, stamp, _downloading, _agreed, unapplied) => {
      replacementClears = [];
      if ((sync?.link() ?? null) !== link) return null;
      const { snapshot, document } = current();
      if (!(snapshot.readyForSync ?? snapshot.ready)) return null;
      const roots = rootsOf(document);
      if (document.nodes[roots.bar]?.kind !== "folder" || document.nodes[roots.other]?.kind !== "folder") return null;
      extractedRevision = snapshot.revision;
      const wireDocument = JSON.parse(snapshot.wireDocument ?? snapshot.document) as Bookmarks;
      const values = bookmarkValues(wireDocument, roots, base);
      if (!link && (sync || Object.keys(snapshot.facts).length)) return { values: new Map(), ignore: () => true };
      const cleared: BookmarkFactClear[] = [];
      const observed: { key: string; hlc: string }[] = [];
      const reapply = new Set<string>();
      const claims = new Map<string, { at: number; after: string | null }>();
      const remove = new Set<string>();
      const ignored = new Set<string>();
      const canonicalBaselines = new Set(snapshot.wireBaselineKeys ?? []);
      for (const key of new Set([...values.keys(), ...(_agreed?.() ?? [])])) {
        if (snapshot.facts[key]) continue;
        const local = canonical(values.get(key) ?? null);
        const known = !!_known?.(key);
        const needsRemote = canonicalBaselines.has(key) && known && (local !== canonical(base(key) ?? null) || local !== canonical(_remote?.(key) ?? null));
        if (!needsRemote && !unapplied?.(key)) continue;
        values.delete(key);
        ignored.add(key);
        if (needsRemote) reapply.add(key);
      }
      for (const [key, fact] of Object.entries(snapshot.facts)) {
        if (!key.startsWith("bm:")) continue;
        const value = values.get(key);
        const previous = base(key);
        const same = canonical(value ?? null) === canonical(previous ?? null) && (value !== undefined || previous !== undefined || !_known?.(key) || _remote?.(key) == null);
        const known = stamp?.(key);
        let after = fact.link === link ? fact.after : null;
        if (fact.link === link && known && sync && hlcDevice(known) === sync.device && (!after || after < known)) after = known;
        const stamped = { at: fact.at, after };
        const lost = !same && !!known && !!sync && known >= editHLC(stamped, sync.device);
        if (same || lost) {
          values.delete(key);
          ignored.add(key);
          if (lost || canonical(value ?? null) !== canonical(_remote?.(key) ?? null)) {
            replacementClears.push({ key, seq: fact.seq });
            reapply.add(key);
          } else {
            cleared.push({ key, seq: fact.seq });
            if (known) observed.push({ key, hlc: known });
          }
          continue;
        }
        claims.set(key, stamped);
        if (!values.has(key)) remove.add(key);
      }
      return {
        values,
        ignore: (key) => ignored.has(key) || (!snapshot.facts[key] && !!unapplied?.(key)),
        remove,
        reapply,
        republish: (key) => claims.has(key),
        stamp: (key) => claims.get(key),
        published: (keys, stamps) => {
          const records = [...keys].flatMap((key) => {
            const fact = snapshot.facts[key];
            const mintedHLC = stamps.get(key);
            return fact && mintedHLC ? [{ key, seq: fact.seq, mintedHLC }] : [];
          });
          if (!records.length || (sync?.link() ?? null) !== link) return;
          try { ackBookmarkFacts(profileId, binding, records, link ?? "none"); } catch {}
        },
        committed: cleared.length ? () => {
          try {
            if ((sync?.link() ?? null) !== link) return;
            if (observed.length && !observeBookmarkRecords(profileId, binding, observed, link ?? "none")) return;
            clearBookmarkFacts(profileId, binding, cleared);
          } catch {}
        } : undefined,
      };
    },
    apply: (visible, changed, _base, records) => {
      const { snapshot, document } = current();
      if ((sync?.link() ?? null) !== link || (sync && !link) || !(snapshot.readyForSync ?? snapshot.ready) || (extractedRevision !== undefined && snapshot.revision !== extractedRevision)) return false;
      const roots = rootsOf(document);
      if (document.nodes[roots.bar]?.kind !== "folder" || document.nodes[roots.other]?.kind !== "folder") throw new Error("the native bookmark document has no roots for this profile");
      const observed = [...new Set([...visible.keys(), ...changed])].flatMap((key) => {
        const hlc = records.stamp?.(key);
        return hlc ? [{ key, hlc }] : [];
      });
      const clears = replacementClears;
      return replaceBookmarkDocumentWithRecords(profileId, { ...document, nodes: syncedBookmarkNodes(document, roots, visible) }, snapshot.revision, binding, observed, link ?? "none").then(() => {
        if ((sync?.link() ?? null) !== link) return false;
        if (clears.length) {
          try { clearBookmarkFacts(profileId, binding, clears); } catch {}
        }
        return true;
      }, (error: unknown) => {
        if (bookmarkWriterErrorCode(error) === "expired") return false;
        throw error;
      });
    },
  };
}

const HISTORY_WINDOW_MS = 90 * 86_400_000;

type HistoryValue = { t: string; n: number; vt: number[] };
const lastVisitOf = (v: HistoryValue) => Math.max(0, ...v.vt);
const keptInHistory = (url: string) => /^(https?|file):/i.test(url);
const SAME_VISIT_MS = 1;

export const historyExpired = (key: string, value: unknown, now: number) =>
  key.startsWith("h:") && lastVisitOf(value as HistoryValue) < now - HISTORY_WINDOW_MS;

const historyLifetimes = new Map(Object.keys(store().profiles).map((id) => [id, Symbol()]));

useBrowser.subscribe((s, previous) => {
  if (s.profiles === previous.profiles && s.orphanedProfileData === previous.orphanedProfileData) return;
  for (const id of historyLifetimes.keys()) if (!s.profiles[id]) historyLifetimes.delete(id);
  for (const [id, profile] of Object.entries(s.profiles)) {
    const before = previous.profiles[id];
    const engine = engineIdOf(profile);
    const retired = s.orphanedProfileData.includes(engine) && !previous.orphanedProfileData.includes(engine);
    if (!before || before.id !== profile.id || before.createdAt !== profile.createdAt || engineIdOf(before) !== engine || retired) historyLifetimes.set(id, Symbol());
  }
});

export function historyAdapter(profileId: string): Adapter {
  const ready = () => {
    const s = store();
    const profile = s.profiles[profileId];
    return !!profile && profile.id === profileId && !!s.historyReady[profileId] && !s.orphanedProfileData.includes(engineIdOf(profile));
  };
  return {
    prefix: "h:",
    extract: (base) => {
      if (!ready()) return null;
      const since = Date.now() - HISTORY_WINDOW_MS;
      const values = new Map<string, unknown>();
      const older = new Set<string>();
      const view = store().history[profileId] ?? [];
      const floor = store().historyFloor[profileId] ?? -Infinity;
      for (const e of view) {
        if (!keptInHistory(e.url)) continue;
        const key = `h:${e.url}`;
        if (e.lastVisit < since) {
          older.add(key);
          continue;
        }
        const local: HistoryValue = { t: e.title, n: e.visits, vt: e.visitTimes?.length ? e.visitTimes : [e.lastVisit] };
        const known = base(key) as HistoryValue | undefined;
        const edited = !known || local.vt.some((t) => !known.vt.some((k) => Math.abs(k - t) <= SAME_VISIT_MS));
        values.set(key, edited ? local : known);
      }
      const ignore = (key: string) => {
        if (older.has(key) || !keptInHistory(key.slice(2))) return true;
        const known = base(key) as HistoryValue | undefined;
        return !!known && (lastVisitOf(known) < since || lastVisitOf(known) <= floor);
      };
      return { values, ignore };
    },
    editedAt: (v) => lastVisitOf(v as HistoryValue),
    apply: async (visible, changed) => {
      if (!ready()) return false;
      const profile = store().profiles[profileId]!;
      const lifetime = historyLifetimes.get(profileId);
      const createdAt = profile.createdAt;
      const engine = engineIdOf(profile);
      const alive = () => {
        const current = store().profiles[profileId];
        return ready() && !!current && current.id === profile.id && current.createdAt === createdAt && engineIdOf(current) === engine && historyLifetimes.get(profileId) === lifetime;
      };
      const refused = () => new ApplyRefusal(new Set(changed), new Error("Profile history lifetime retired"));
      const since = Date.now() - HISTORY_WINDOW_MS;
      const byUrl = new Map((store().history[profileId] ?? []).map((e) => [e.url, e]));
      const add: { url: string; title: string; visitTimes: number[] }[] = [];
      const remove: string[] = [];
      const updates = new Map<string, HistoryEntry | null>();
      for (const key of changed) {
        const url = key.slice(2);
        if (!keptInHistory(url)) continue;
        const v = visible.get(key) as HistoryValue | undefined;
        const old = byUrl.get(url);
        if (v) {
          const have = old?.visitTimes ?? [];
          const fresh = v.vt.filter((t) => t >= since && !have.some((h) => Math.abs(h - t) <= SAME_VISIT_MS));
          if (fresh.length) add.push({ url, title: v.t, visitTimes: fresh });
          const times = [...have, ...fresh].sort((a, z) => a - z).slice(-MAX_VISIT_TIMES);
          if (!times.length) continue;
          updates.set(url, {
            url,
            title: v.t || old?.title || "",
            favicon: null,
            visits: Math.max(v.n, old?.visits ?? 0),
            lastVisit: times[times.length - 1]!,
            visitTimes: times,
          });
        } else if (old && old.lastVisit >= since) {
          remove.push(url);
          updates.set(url, null);
        }
      }
      if (!updates.size) return;
      await Promise.all([nativeAddHistoryVisits(engine, add, SAME_VISIT_MS), nativeDeleteHistoryUrls(engine, remove)]);
      if (!alive()) throw refused();
      asSyncApply(() =>
        useBrowser.setState((s) => {
          if (!alive()) throw refused();
          const current = new Map((s.history[profileId] ?? []).map((e) => [e.url, e]));
          for (const [url, update] of updates) {
            const now = current.get(url);
            if (!update) current.delete(url);
            else if (!now) current.set(url, update);
            else {
              const times = [...new Set([...(now.visitTimes ?? []), ...(update.visitTimes ?? [])])].sort((a, z) => a - z).slice(-MAX_VISIT_TIMES);
              current.set(url, { ...update, visits: Math.max(now.visits, update.visits), lastVisit: times[times.length - 1]!, visitTimes: times });
            }
          }
          const list = [...current.values()].sort((a, z) => z.lastVisit - a.lastVisit).slice(0, MAX_HISTORY);
          return { history: { ...s.history, [profileId]: list } };
        }),
      );
    },
  };
}

export type DeviceTabs = { n: string; tabs: { u: string; t: string }[] };
const MAX_DEVICE_TABS = 30;

export function deviceTabsAdapter(profileId: string, deviceId: string, name: () => string, retired = false): Adapter {
  const key = `tabs:${deviceId}`;
  return {
    prefix: "tabs:",
    extract: () => {
      if (retired) return { values: new Map(), ignore: (k) => k !== key };
      const s = store();
      const open = Object.values(s.tabs)
        .filter((t) => t.profileId === profileId && !t.pinned && !t.unloaded && /^(https?|file):/.test(t.url) && !s.windows[t.windowId]?.incognito && !isPeekTab(s, t.id))
        .sort((a, z) => z.lastActiveAt - a.lastActiveAt)
        .slice(0, MAX_DEVICE_TABS)
        .map((t) => ({ u: t.url, t: t.customTitle || t.title }));
      return { values: new Map([[key, { n: name(), tabs: open } satisfies DeviceTabs]]), ignore: (k) => k !== key };
    },
    apply: () => true,
  };
}

type PasswordValue = { o: string; u: string; p: string };
const PASSWORD_READ_INTERVAL = 30_000;

export function passwordsAdapter(
  profileId: string,
  forced: () => boolean,
  readLogins: (engineProfile: string) => Promise<SavedLogin[] | null | undefined> = async (p) => SyncNative?.readPasswords(p),
): Adapter {
  let lastRead = 0;
  let quietUntil = 0;
  let created = new Map<string, number>();
  const profile = () => engineProfile(profileId);
  const keyOf = (origin: string, username: string) => `pw:${origin}\n${username}`;
  const read = async () => {
    const logins = await readLogins(profile());
    if (!logins) return null;
    const out = new Map<string, PasswordValue & { c: number }>();
    for (const l of logins) {
      const origin = originOf(l);
      if (origin) out.set(keyOf(origin, l.username), { o: origin, u: l.username, p: l.password, c: l.created });
    }
    return out;
  };
  return {
    prefix: "pw:",
    extract: async () => {
      const now = Date.now();
      if (now < quietUntil || (now - lastRead < PASSWORD_READ_INTERVAL && !forced())) return null;
      const logins = await read();
      if (!logins) return null;
      lastRead = now;
      created = new Map([...logins].map(([k, v]) => [k, v.c]));
      return { values: new Map([...logins].map(([k, { o, u, p }]) => [k, { o, u, p } satisfies PasswordValue])) };
    },
    editedAt: (v) => created.get(keyOf((v as PasswordValue).o, (v as PasswordValue).u)) || undefined,
    apply: async (visible, changed, base) => {
      const local = await read();
      if (!local) return false;
      let ok = true;
      const keptHere = new Set<string>();
      for (const key of changed) {
        const v = visible.get(key) as PasswordValue | undefined;
        const have = local.get(key);
        const known = base(key) as PasswordValue | undefined;
        if (have && known?.p !== have.p) {
          keptHere.add(key);
          continue;
        }
        const [origin, username] = [key.slice(3, key.indexOf("\n")), key.slice(key.indexOf("\n") + 1)];
        if (v) {
          if (have?.p === v.p) continue;
          if (have) ok = (await deletePassword(profile(), origin, username)) && ok;
          ok = (await savePassword(profile(), v.o, v.u, v.p)) && ok;
        } else if (have) {
          ok = (await deletePassword(profile(), origin, username)) && ok;
        }
      }
      const confirmed = (now: Awaited<ReturnType<typeof read>>, k: string) => !!now && (visible.get(k) as PasswordValue | undefined)?.p === now.get(k)?.p;
      let latest: Awaited<ReturnType<typeof read>> = null;
      let settled = false;
      for (let i = 0; i < 20 && !settled; i++) {
        latest = await read();
        settled = [...changed].every((k) => (syncRedesign.on && keptHere.has(k)) || confirmed(latest, k));
        if (!settled) await new Promise((r) => setTimeout(r, 250));
      }
      if (!settled) quietUntil = Date.now() + 30_000;
      if (!ok) return false;
      return new Set([...changed].filter((k) => confirmed(latest, k)));
    },
  };
}

export function originOf(login: SavedLogin): string | null {
  const realm = login.origin.replace(/\/$/, "");
  return /^https?:\/\/[^/\s]+$/.test(realm) ? realm : null;
}

const DEV_MODE = "devmode:";

export function developerModeAdapter(profileId: string): Adapter {
  return {
    prefix: DEV_MODE,
    adoptRemoteOnJoin: true,
    extract: () => {
      const state = developerModeOf(store().settings.developerMode?.[profileId]);
      const values = new Map<string, unknown>();
      for (const host of state.on) values.set(`${DEV_MODE}on:${host}`, { v: 1 });
      for (const host of state.off) values.set(`${DEV_MODE}off:${host}`, { v: 1 });
      if (state.reload !== "reload") values.set(`${DEV_MODE}reload`, { r: state.reload });
      return { values };
    },
    apply: (visible) => {
      const on: string[] = [];
      const off: string[] = [];
      let reload: unknown = "reload";
      for (const [key, value] of visible) {
        const rest = key.slice(DEV_MODE.length);
        if (rest.startsWith("on:")) on.push(rest.slice(3));
        else if (rest.startsWith("off:")) off.push(rest.slice(4));
        else if (rest === "reload" && value && typeof value === "object") reload = (value as { r?: unknown }).r;
      }
      const next = developerModeOf({ on, off, reload });
      const all = store().settings.developerMode ?? {};
      if (canonical(next) === canonical(developerModeOf(all[profileId]))) return;
      asSyncApply(() => store().updateSettings({ developerMode: { ...all, [profileId]: next } }, { fromSync: true }));
    },
  };
}
