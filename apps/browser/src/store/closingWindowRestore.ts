import type { BrowserState } from "./browser";
import type { ClosingWindowSnapshot } from "./windows";
import { IDLE_LIVE } from "./model";

export const sameClosingValue = (a: unknown, b: unknown) => a === b || JSON.stringify(a) === JSON.stringify(b);

export function undoClosingEntries<T>(current: Record<string, T>, before: Record<string, T>, after: Record<string, T>): Record<string, T> | null {
  const changed = [...new Set([...Object.keys(before), ...Object.keys(after)])].filter((id) => !sameClosingValue(before[id], after[id]));
  if (changed.some((id) => !sameClosingValue(current[id], after[id]))) return null;
  const next = { ...current };
  for (const id of changed) {
    if (id in before) next[id] = before[id]!;
    else delete next[id];
  }
  return next;
}

export type ClosingWindowUndo = { before: BrowserState; after: BrowserState; closedAt: number };
export const closingWindowUndos = new Map<string, ClosingWindowUndo>();

const tables = ["windows", "tabs", "groups", "splits", "parkedPins", "peeks", "pinChoices", "pinSync", "privateCleanedTabs", "privateSiteMutes", "live", "find", "selection", "windowUi"] as const;
const lists = ["closedTabs", "closedWindows", "windowOrder"] as const;
const focus = ["focusedWindowId", "focusOrder", "lastProfileId"] as const;

export function undoClosingWindow(s: BrowserState, undo: ClosingWindowUndo, snapshot: ClosingWindowSnapshot): BrowserState | null {
  const { before, after } = undo;
  const window = before.windows[snapshot.window.id];
  if (!window || !sameClosingValue(window.tabIds, snapshot.window.tabIds) || window.profileId !== snapshot.window.profileId || window.kind !== snapshot.window.kind || window.incognito !== snapshot.window.incognito) return null;
  const ids = new Set(window.tabIds);
  const groups = Object.values(before.groups).filter((g) => g.windowId === window.id);
  const splits = Object.values(before.splits).filter((v) => v.windowId === window.id);
  const sameIds = (a: string[], b: string[]) => sameClosingValue([...a].sort(), [...b].sort());
  if (!sameIds(window.tabIds, snapshot.tabs.map((t) => t.id)) || !sameIds(groups.map((g) => g.id), snapshot.groups.map((g) => g.id)) || !sameIds(splits.map((v) => v.id), snapshot.splits.map((v) => v.id))) return null;
  if (s.windows[window.id] || window.tabIds.some((id) => s.tabs[id]) || groups.some((g) => s.groups[g.id]) || splits.some((v) => s.splits[v.id])) return null;
  if (Object.values(s.windows).some((w) => [...w.tabIds, ...Object.values(w.activeTabIds)].some((id) => ids.has(id))) || Object.values(s.groups).some((g) => g.tabIds.some((id) => ids.has(id)) || groups.some((own) => own.id === g.parentId || own.id === g.id) || !!g.pinnedOpenerId && ids.has(g.pinnedOpenerId)) || Object.values(s.splits).some((v) => v.tabIds.some((id) => ids.has(id)))) return null;
  const next = { ...s, ui: { ...s.ui } };
  for (const key of tables) {
    const restored = undoClosingEntries(s[key] as Record<string, unknown>, before[key] as Record<string, unknown>, after[key] as Record<string, unknown>);
    if (!restored) return null;
    Object.assign(next, { [key]: restored });
  }
  for (const key of lists) {
    if (sameClosingValue(before[key], after[key])) continue;
    if (!sameClosingValue(s[key], after[key])) return null;
    Object.assign(next, { [key]: before[key] });
  }
  for (const key of focus) {
    if (sameClosingValue(before.ui[key], after.ui[key])) continue;
    if (!sameClosingValue(s.ui[key], after.ui[key])) return null;
    Object.assign(next.ui, { [key]: before.ui[key] });
  }
  const pinIds = new Set(window.tabIds.flatMap((id) => [id, before.tabs[id]!.pinKey ?? id]));
  const groupIds = new Set(groups.flatMap((g) => [g.id, g.pinKey ?? g.id]));
  if (Object.values(next.parkedPins).some((p) => p.tabs.some((t) => pinIds.has(t.id) || !!t.groupId && groupIds.has(t.groupId)) || p.groups.some((g) => groupIds.has(g.id) || !!g.parentId && groupIds.has(g.parentId)) || (p.splits ?? []).some((v) => v.ids.some((id) => pinIds.has(id))))) return null;
  return next;
}

export function remapClosingWindow(s: BrowserState, oldId: string, id: string, chromeWindow: string): BrowserState {
  const remap = (key: string) => key === oldId ? id : key;
  const keyed = <T>(table: Record<string, T>) => Object.fromEntries(Object.entries(table).map(([key, value]) => [remap(key), value]));
  return {
    ...s,
    windows: Object.fromEntries(Object.entries(s.windows).map(([key, w]) => [remap(key), key === oldId ? { ...w, id, chromeWindow } : w])),
    tabs: Object.fromEntries(Object.entries(s.tabs).map(([key, t]) => [key, t.windowId === oldId ? { ...t, windowId: id } : t])),
    groups: Object.fromEntries(Object.entries(s.groups).map(([key, g]) => [key, g.windowId === oldId ? { ...g, windowId: id } : g])),
    splits: Object.fromEntries(Object.entries(s.splits).map(([key, v]) => [key, v.windowId === oldId ? { ...v, windowId: id } : v])),
    windowOrder: s.windowOrder.map(remap),
    ui: { ...s.ui, focusedWindowId: s.ui.focusedWindowId && remap(s.ui.focusedWindowId), focusOrder: s.ui.focusOrder.map(remap) },
    windowUi: keyed(s.windowUi),
    selection: keyed(s.selection),
    selectionAnchors: keyed(s.selectionAnchors),
    privateCleanedTabs: keyed(s.privateCleanedTabs),
    privateSiteMutes: keyed(s.privateSiteMutes),
    peeks: keyed(s.peeks),
  };
}

type LocalCloseState = Pick<BrowserState, "live">;
const nativeLocals = new Map<string, NativeClosingUndo>();

export function rememberNativeClosingLocals(before: BrowserState, after: BrowserState) {
  for (const id of Object.keys(before.windows)) {
    if (after.windows[id]) continue;
    for (const [key, entry] of nativeLocals) if (Date.now() - entry.closedAt > 30_000) nativeLocals.delete(key);
    nativeLocals.set(id, { before: { live: before.live }, after: { live: after.live }, closedAt: Date.now() });
    while (nativeLocals.size > 10) nativeLocals.delete(nativeLocals.keys().next().value!);
  }
}

type NativeClosingUndo = { before: LocalCloseState; after: LocalCloseState; closedAt: number };

export function nativeClosingUndo(oldId: string): NativeClosingUndo | null {
  const undo = nativeLocals.get(oldId);
  return undo && Date.now() - undo.closedAt <= 30_000 ? undo : null;
}

export function restoredNativeClosingLocals(s: BrowserState, oldId: string): LocalCloseState | null {
  const undo = nativeClosingUndo(oldId);
  if (!undo) return null;
  const live = undoClosingEntries(s.live, undo.before.live, undo.after.live);
  return live ? { live } : null;
}

export function nativeClosingLiveAtApply(s: BrowserState, undo: NativeClosingUndo): LocalCloseState {
  const live = { ...s.live };
  const { before, after } = undo;
  for (const id of new Set([...Object.keys(before.live), ...Object.keys(after.live)])) {
    const untouched = sameClosingValue(s.live[id], after.live[id]) || (!(id in after.live) && sameClosingValue(s.live[id], IDLE_LIVE));
    if (sameClosingValue(before.live[id], after.live[id]) || !untouched) continue;
    if (id in before.live) live[id] = before.live[id]!;
    else delete live[id];
  }
  return { live };
}

export function clearNativeClosingLocals(id?: string) {
  if (id) nativeLocals.delete(id);
  else nativeLocals.clear();
}

export function pruneClosingLocals(local: LocalCloseState, state?: BrowserState, tabIds: string[] = []): LocalCloseState {
  if (!state) return { live: local.live };
  const affected = new Set(tabIds);
  const kept = (tabId: string) => !!state.tabs[tabId] && (!affected.has(tabId) || !state.tabs[tabId]!.unloaded);
  return {
    live: Object.fromEntries(Object.entries(local.live).filter(([tabId]) => state.tabs[tabId]).map(([tabId, value]) => [tabId, kept(tabId) ? value : IDLE_LIVE])),
  };
}

export function clearClosingWindowRestores() {
  closingWindowUndos.clear();
  clearNativeClosingLocals();
}
