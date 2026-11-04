import { setWindowSidebar, type WindowSidebarPatch } from "./sidebarRail";
import type { StateCreator } from "zustand";
import type { BrowserState } from "./browser";
import { rejoinGroups } from "./groups";
import { closingWindowUndos as closing, remapClosingWindow, undoClosingWindow } from "./closingWindowRestore";
import { findLast,
  IDLE_LIVE,
  incognitoOriginal,
  incognitoProfileId,
  inPinnedContainer,
  isIncognitoProfile,
  makeTab,
  navigationTo,
  newId,
  pendingRestore,
  pinnedFirst,
  resolveWindowId,
  restoreId,
  snapshotTab,
  viewTabIds,
  without, closedWindowPresentation } from "./model";
import { newTabSlot, nextToActive } from "./openers";
import { groupWithOpener, nextPinChoice, placeChoiceKey, restoringGroup } from "./organize";
import { hasLoadedPage, hasPage } from "./pageSession";
import { withoutPeek } from "./peek";
import { adoptParkedPins, parkWindowPins } from "./parkedPins";
import { settleMovedPins } from "./pinMirror";
import { holderOf, returnSharedPages, swapPinPage } from "./pinShare";
import { sharedElsewhere, sharesTabs } from "./tabShare";
import { isSmall, isSmallWindow, lastActiveProfile, linkProfileOf, mainWindowFor } from "./small";
import { activated, apply, removeTabs, unloadPinnedTabs, withNewTab } from "./tabs";
import type { BrowserWindow, ClosedTab, ClosedWindow, Frame, ParkedPins, SplitView, Tab, TabGroup } from "./types";

export type CreateWindowOptions = {
  profileId?: string;
  incognito?: boolean;
  url?: string;
  adoptId?: string;
  tabIds?: string[];
  frame?: Frame | null;
  small?: boolean;
  linkPointer?: [number, number];
  background?: boolean;
  chromeWindow?: string;
};

export type WindowsSlice = {
  windows: Record<string, BrowserWindow>;
  windowOrder: string[];
  closedWindows: ClosedWindow[];
  setWindowSidebar(windowId: string, patch: WindowSidebarPatch): void;
  parkedPins: Record<string, ParkedPins>;

  createWindow(options?: CreateWindowOptions): string;
  closeWindow(id: string): void;
  restoreClosingWindow(snapshot: ClosingWindowSnapshot, chromeWindow: string, liveTabIds: string[]): string | null;
  forgetClosedWindow(id: string): void;
  setWindowFrame(id: string, frame: Frame): void;
  setWindowFullScreen(id: string, on: boolean): void;
  toggleSidebar(windowId: string): void;
  switchProfile(windowId: string, profileId: string): void;
  moveTabsToWindow(tabIds: string[], windowId: string | null): string | undefined;
  moveTabToProfile(tabId: string, profileId: string): void;
  mergeAllWindows(windowId: string): void;
  reopenClosed(windowId?: string | null): void;
  reopenClosedTab(windowId?: string | null): void;
  reopenClosedWindow(): void;
  restoreClosed(entryId: string, windowId?: string | null): void;
};

export type ClosingWindowSnapshot = { window: BrowserWindow; tabs: Tab[]; groups: TabGroup[]; splits: SplitView[] };

const MAX_CLOSED_WINDOWS = 10;

function emptyWindow(id: string, profileId: string, incognito: boolean, frame: Frame | null = null): BrowserWindow {
  return { id, profileId, incognito, tabIds: [], activeTabIds: {}, sidebarOpen: true, frame, createdAt: Date.now() };
}

const smallWindow = (id: string, profileId: string, frame: Frame | null = null): BrowserWindow => ({ ...emptyWindow(id, profileId, false, frame), sidebarOpen: false, kind: "small" });

function lastProfileAfterClosing(s: BrowserState, id: string): string | null {
  const w = s.windows[id];
  if (!w || w.incognito || s.ui.focusedWindowId !== id) return s.ui.lastProfileId;
  const next = s.ui.focusOrder.find((f) => f !== id && linkProfileOf(s, s.windows[f]));
  return linkProfileOf(s, next ? s.windows[next] : undefined) ?? s.ui.lastProfileId;
}

function withWindow(s: BrowserState, w: BrowserWindow): BrowserState {
  return {
    ...s,
    windows: { ...s.windows, [w.id]: w },
    windowOrder: [...s.windowOrder, w.id],
    ui: { ...s.ui, focusedWindowId: w.id, focusOrder: [w.id, ...s.ui.focusOrder], lastProfileId: linkProfileOf(s, w) ?? s.ui.lastProfileId },
  };
}

export function moveTabsInto(s: BrowserState, ids: string[], targetId: string, landing: "end" | "newTab" = "end"): BrowserState {
  const target = s.windows[targetId];
  if (!target || isSmallWindow(target)) return s;
  const moving = ids
    .map((id) => s.tabs[id])
    .filter((t): t is Tab => !!t && t.windowId !== targetId && !isIncognitoProfile(t.profileId) && !target.incognito);
  if (!moving.length) return s;

  const sources = new Set(moving.map((t) => t.windowId));
  let next = removeTabs(s, moving.map((t) => t.id), false);
  const w = next.windows[targetId]!;
  const landed = [...w.tabIds];
  landed.splice(landing === "newTab" ? newTabSlot(next, w, moving[0]!) : w.tabIds.length, 0, ...moving.map((t) => t.id));
  const tabs = { ...next.tabs };
  const live = { ...next.live };
  const activeTabIds = { ...w.activeTabIds };
  for (const tab of moving) {
    const { adoptId: _adopted, ...t } = tab;
    const loaded = hasLoadedPage(tab);
    tabs[t.id] = { ...t, windowId: targetId, navigation: loaded ? navigationTo(t.url) : null };
    live[t.id] = IDLE_LIVE;
    activeTabIds[t.profileId] ??= t.id;
  }
  next = {
    ...next,
    tabs,
    live,
    windows: { ...next.windows, [targetId]: { ...w, tabIds: pinnedFirst(landed, tabs, next.groups), activeTabIds } },
  };
  for (const id of sources) {
    const src = next.windows[id];
    if (!src || viewTabIds(next, id).length) continue;
    const recent = src.tabIds.map((t) => next.tabs[t]!).sort((a, b) => b.lastActiveAt - a.lastActiveAt)[0];
    if (recent) next = apply(next, activated(next, src.activeTabIds[recent.profileId] ?? recent.id));
  }
  return settleMovedPins(s, next, moving.map((t) => t.id), targetId);
}

function restoreGroup(groups: Record<string, TabGroup>, g: Omit<TabGroup, "tabIds">, tabIds: string[]): [Record<string, TabGroup>, string] {
  const id = groups[g.id] ? newId("g") : g.id;
  return [{ ...groups, [id]: { ...g, id, tabIds } }, id];
}

export const createWindowsSlice: StateCreator<BrowserState, [], [], WindowsSlice> = (set, get) => ({
  windows: {},
  windowOrder: [],
  closedWindows: [],
  parkedPins: {},

  createWindow(o = {}) {
    const s = get();
    const id = newId("w");
    const small = !!o.small && !o.incognito;
    const known = o.profileId && s.profiles[o.profileId] ? o.profileId : undefined;
    const restoredPrivate = o.incognito && o.chromeWindow && o.profileId && isIncognitoProfile(o.profileId) && s.profiles[incognitoOriginal(o.profileId)] ? o.profileId : undefined;
    const original = o.incognito ? (restoredPrivate ? incognitoOriginal(restoredPrivate) : known ?? lastActiveProfile(s)) : undefined;
    const profileId = restoredPrivate ?? (original !== undefined
      ? incognitoProfileId(id, original)
      : (known ?? (small ? lastActiveProfile(s) : s.settings.defaultProfileId)));
    const w = small ? smallWindow(id, profileId, o.frame ?? null) : emptyWindow(id, profileId, !!o.incognito, o.frame ?? null);
    if (original !== undefined) w.originalProfileId = original;
    if (small && o.linkPointer) w.linkPointer = o.linkPointer;
    if (o.chromeWindow) w.chromeWindow = o.chromeWindow;
    let next = withWindow(s, w);
    if (o.tabIds?.length && !small) next = moveTabsInto(next, o.tabIds, id);
    if (!next.windows[id]!.tabIds.length) next = withNewTab(next, id, { url: o.url, adoptId: o.adoptId })[0];
    const first = next.windows[id]!.tabIds[0]!;
    const shown = next.windows[id]!.activeTabIds[next.tabs[first]!.profileId] ?? first;
    if (!small) next = adoptParkedPins(next, id, next.tabs[shown]!.profileId);
    next = apply(next, activated(next, shown));
    const focused = s.ui.focusedWindowId;
    if (o.background && focused && s.windows[focused]) {
      next = {
        ...next,
        ui: { ...next.ui, focusedWindowId: focused, focusOrder: [focused, id, ...s.ui.focusOrder.filter((w) => w !== focused)], lastProfileId: s.ui.lastProfileId },
      };
    }
    set(next);
    return id;
  },

  restoreClosingWindow(snapshot, chromeWindow, liveTabIds) {
    const s = get();
    const live = new Set(snapshot.tabs.filter((t) => liveTabIds.includes(t.id)).map((t) => t.id));
    if (!live.size) return null;
    for (const [key, entry] of closing) if (Date.now() - entry.closedAt > 30_000) closing.delete(key);
    const undo = closing.get(snapshot.window.id);
    if (!undo || Date.now() - undo.closedAt > 30_000) return null;
    const profileId = snapshot.window.incognito ? snapshot.window.originalProfileId ?? incognitoOriginal(snapshot.window.profileId) : snapshot.window.profileId;
    if (!s.profiles[profileId] || undo.before.windows[snapshot.window.id]!.tabIds.some((id) => {
      const tab = undo.before.tabs[id];
      return !tab || !s.profiles[isIncognitoProfile(tab.profileId) ? incognitoOriginal(tab.profileId) : tab.profileId];
    })) return null;
    const next = undoClosingWindow(s, undo, snapshot);
    if (!next) return null;
    const id = newId("w");
    closing.delete(snapshot.window.id);
    let restored = remapClosingWindow(next, snapshot.window.id, id, chromeWindow);
    const window = restored.windows[id]!;
    const survivors = window.tabIds.filter((tabId) => live.has(tabId));
    const activeTabIds: Record<string, string> = {};
    for (const tabId of survivors) {
      const profile = restored.tabs[tabId]!.profileId;
      if (!activeTabIds[profile] || window.activeTabIds[profile] === tabId) activeTabIds[profile] = tabId;
    }
    const missing = window.tabIds.filter((tabId) => !live.has(tabId));
    restored = { ...restored, windows: { ...restored.windows, [id]: { ...window, activeTabIds, profileId: activeTabIds[window.profileId] ? window.profileId : restored.tabs[survivors[0]!]!.profileId } } };
    if (restored.ui.focusedWindowId === id && restored.windows[id]!.profileId !== window.profileId && !window.incognito) restored = { ...restored, ui: { ...restored.ui, lastProfileId: restored.windows[id]!.profileId } };
    const peek = restored.peeks[id];
    if (peek && !live.has(peek.tabId)) restored = withoutPeek(restored, id);
    restored = unloadPinnedTabs(restored, missing, false);
    restored = removeTabs(restored, missing.filter((tabId) => !inPinnedContainer(restored, tabId)), true);
    if (missing.includes(restored.selectionAnchors[id] ?? "")) restored = { ...restored, selectionAnchors: without(restored.selectionAnchors, [id]) };
    set(restored);
    return id;
  },

  setWindowSidebar(windowId, patch) {
    setWindowSidebar(windowId, patch);
  },

  closeWindow(id) {
    const before = get();
    const s = returnSharedPages(before, id);
    const w = s.windows[id];
    if (!w) return;
    const tabs = w.tabIds.map((t) => s.tabs[t]).filter((t): t is Tab => !!t && !inPinnedContainer(s, t.id) && !sharedElsewhere(s, t));
    const tabIds = tabs.map((t) => t.id);
    const small = isSmallWindow(w);
    let closedWindows = s.closedWindows;
    if (!w.incognito && !small && tabs.some((t) => t.url)) {
      const active = new Set(Object.values(w.activeTabIds));
      const entry: ClosedWindow = {
        kind: "window",
        id: newId("cw"),
        window: closedWindowPresentation(w),
        tabs: tabs.map((t) => ({ ...snapshotTab(t), active: active.has(t.id), ...(hasLoadedPage(t) ? { tabId: t.id } : pendingRestore(t) ? { tabId: pendingRestore(t) } : {}) })),
        groups: Object.values(s.groups)
          .filter((g) => g.windowId === id && !g.pinned && (!sharesTabs(s) || g.tabIds.some((t) => tabIds.includes(t))))
          .map(({ tabIds: members, windowId: _, ...g }) => ({ ...g, tabIndexes: members.map((t) => tabIds.indexOf(t)) })),
        closedAt: Date.now(),
      };
      closedWindows = [...closedWindows, entry].slice(-MAX_CLOSED_WINDOWS);
    }
    const next = removeTabs(s, w.tabIds, small);
    set({
      ...next,
      windows: without(next.windows, [id]),
      windowOrder: next.windowOrder.filter((w) => w !== id),
      windowUi: without(next.windowUi, [id]),
      closedWindows,
      parkedPins: small ? s.parkedPins : parkWindowPins(s.parkedPins, w, s),
      closedTabs: w.incognito ? next.closedTabs.filter((c) => c.windowId !== id) : next.closedTabs,
      ui: {
        ...next.ui,
        focusOrder: next.ui.focusOrder.filter((f) => f !== id),
        focusedWindowId: next.ui.focusedWindowId === id ? (next.ui.focusOrder.find((f) => f !== id) ?? null) : next.ui.focusedWindowId,
        lastProfileId: lastProfileAfterClosing(s, id),
      },
    });
    for (const [key, entry] of closing) if (Date.now() - entry.closedAt > 30_000 || get().windows[key]) closing.delete(key);
    closing.set(id, { before, after: get(), closedAt: Date.now() });
    while (closing.size > MAX_CLOSED_WINDOWS) closing.delete(closing.keys().next().value!);
  },

  forgetClosedWindow(id) {
    set((s) => ({ closedWindows: s.closedWindows.filter((entry) => entry.id !== id) }));
  },

  setWindowFrame(id, frame) {
    set((s) => {
      const w = s.windows[id];
      if (!w || (w.frame && w.frame.every((v, i) => v === frame[i]))) return {};
      const windows = { ...s.windows, [id]: { ...w, frame } };
      if (!isSmallWindow(w)) return { windows };
      const size: [number, number] = [Math.round(frame[2]), Math.round(frame[3])];
      const [width, height] = s.settings.littleSolaraSize ?? [];
      return size[0] === width && size[1] === height ? { windows } : { windows, settings: { ...s.settings, littleSolaraSize: size } };
    });
  },

  setWindowFullScreen(id, on) {
    set((s) => {
      const w = s.windows[id];
      if (!w || !!w.fullScreen === on) return {};
      const { fullScreen: _, ...rest } = w;
      return { windows: { ...s.windows, [id]: on ? { ...rest, fullScreen: Date.now() } : rest } };
    });
  },

  toggleSidebar(windowId) {
    set((s) => {
      const w = s.windows[windowId];
      return w ? { windows: { ...s.windows, [windowId]: { ...w, sidebarOpen: !w.sidebarOpen } } } : {};
    });
  },

  switchProfile(windowId, profileId) {
    let s = get();
    const w = s.windows[windowId];
    if (!w || w.incognito || isSmallWindow(w) || !s.profiles[profileId] || w.profileId === profileId) return;
    s = adoptParkedPins(s, windowId, profileId);
    const remembered = w.activeTabIds[profileId];
    let target = remembered && s.tabs[remembered]?.windowId === windowId ? remembered : undefined;
    target ??= s.windows[windowId]!.tabIds.find((id) => s.tabs[id]?.profileId === profileId && !s.tabs[id]!.unloaded);
    if (!target) [s, target] = withNewTab(s, windowId, { profileId, background: true });
    s = apply(s, activated(s, target));
    if (s.ui.focusedWindowId === windowId) s = { ...s, ui: { ...s.ui, lastProfileId: profileId } };
    set(s);
  },

  moveTabsToWindow(tabIds, windowId) {
    const s = get();
    if (windowId === null) {
      const first = s.tabs[tabIds[0] ?? ""];
      if (!first || isIncognitoProfile(first.profileId)) return undefined;
      return get().createWindow({ profileId: first.profileId, tabIds });
    }
    const beside = nextToActive(s, windowId, s.tabs[tabIds[0] ?? ""]?.profileId);
    let next = moveTabsInto(s, tabIds, windowId, "newTab");
    if (beside && !inPinnedContainer(next, beside.openerId)) {
      for (const id of tabIds) {
        if (s.tabs[id]?.windowId !== windowId && next.tabs[id]?.windowId === windowId) next = groupWithOpener(next, id, beside.openerId, false);
      }
    }
    const last = findLast(tabIds, (id) => next.tabs[id]?.windowId === windowId);
    if (last) next = apply(next, activated(next, last));
    set(next);
    return windowId;
  },

  moveTabToProfile(tabId, profileId) {
    const s = get();
    const tab = s.tabs[tabId];
    const w = tab && s.windows[tab.windowId];
    if (!tab || !w || w.incognito || !s.profiles[profileId] || tab.profileId === profileId) return;
    let next = removeTabs(s, [tabId], false);
    const base = next.windows[w.id] ?? { ...w, tabIds: [], activeTabIds: {} };
    const loaded = hasLoadedPage(tab);
    const { adoptId: _, wakeAdoptId: _w, ...rest } = tab;
    const moved: Tab = { ...rest, profileId, navigation: loaded ? navigationTo(tab.url) : null, lastActiveAt: Date.now() };
    const movedKey = moved.pinKey ?? moved.id;
    const pinChoices = tab.pinned
      ? { ...next.pinChoices, [profileId]: { ...next.pinChoices[profileId], [movedKey]: nextPinChoice(), [placeChoiceKey(movedKey)]: nextPinChoice() } }
      : next.pinChoices;
    const tabs = { ...next.tabs, [tabId]: moved };
    const index = Math.min(w.tabIds.indexOf(tabId), base.tabIds.length);
    const tabIds = [...base.tabIds];
    tabIds.splice(index, 0, tabId);
    next = {
      ...next,
      tabs,
      pinChoices,
      live: { ...next.live, [tabId]: IDLE_LIVE },
      windows: { ...next.windows, [w.id]: { ...base, tabIds: pinnedFirst(tabIds, tabs, next.groups) } },
      windowOrder: next.windowOrder.includes(w.id) ? next.windowOrder : s.windowOrder,
    };
    set(apply(next, activated(next, tabId)));
  },

  mergeAllWindows(windowId) {
    const s = get();
    const target = s.windows[windowId]?.incognito || isSmallWindow(s.windows[windowId]) ? mainWindowFor(s) : windowId;
    if (!target) return;
    const others = s.windowOrder.filter((id) => id !== target && !s.windows[id]?.incognito && !isSmallWindow(s.windows[id]));
    const tabIds = others.flatMap((id) => s.windows[id]!.tabIds);
    if (!tabIds.length) return;
    let next = moveTabsInto(s, tabIds, target);
    const groups = { ...next.groups };
    const taken = new Set(Object.values(next.groups).flatMap((g) => g.tabIds));
    for (const g of Object.values(s.groups)) {
      if (!others.includes(g.windowId)) continue;
      const members = g.tabIds.filter((id) => next.tabs[id]?.windowId === target && !taken.has(id));
      if (members.length) groups[g.id] = { ...g, windowId: target, tabIds: members };
    }
    next = { ...next, groups };
    set(next);
  },

  reopenClosed(windowId) {
    const s = get();
    const target = resolveWindowId(s, windowId);
    const lastTab = lastClosedTab(s, target);
    const regular = (p: string | undefined) => !s.windows[target ?? ""]?.incognito && shownProfile(s, target, p);
    const lastWindow = findLast(s.closedWindows, (c) => regular(c.window.profileId));
    const lastGroup = findLast(s.closedGroups, (c) => regular(c.tabs[0]?.profileId));
    const entry = [lastWindow, lastGroup, lastTab].reduce<{ id: string; closedAt: number } | undefined>(
      (latest, e) => (e && (!latest || e.closedAt > latest.closedAt) ? e : latest),
      undefined,
    );
    if (entry) get().restoreClosed(entry.id, target);
  },

  reopenClosedTab(windowId) {
    const s = get();
    const target = resolveWindowId(s, windowId);
    const entry = lastClosedTab(s, target);
    if (entry) get().restoreClosed(entry.id, target);
  },

  reopenClosedWindow() {
    const entry = get().closedWindows.at(-1);
    if (entry) get().restoreClosed(entry.id);
  },

  restoreClosed(entryId, windowId) {
    const s = get();
    if (isSmall(s, windowId)) windowId = mainWindowFor(s) ?? null;
    const closedTab = s.closedTabs.find((c) => c.id === entryId);
    if (closedTab) return set(restoreTab(s, closedTab, windowId));
    const closedWindow = s.closedWindows.find((c) => c.id === entryId);
    if (closedWindow) return set(restoreWindow(s, closedWindow));
    const closedGroup = s.closedGroups.find((c) => c.id === entryId) ?? s.deletedGroups.find((c) => c.id === entryId);
    if (closedGroup) set(restoringGroup(s, closedGroup, windowId));
  },
});

function shownProfile(s: BrowserState, windowId: string | undefined, profileId: string | undefined): boolean {
  return !windowId || profileId === s.windows[windowId]!.profileId;
}

function lastClosedTab(s: BrowserState, windowId: string | undefined): ClosedTab | undefined {
  return findLast(
    s.closedTabs,
    (c) => canRestoreTabInto(s, c, windowId) && (isIncognitoProfile(c.tab.profileId) || shownProfile(s, windowId, c.tab.profileId)),
  );
}

function canRestoreTabInto(s: BrowserState, c: ClosedTab, windowId: string | undefined): boolean {
  const w = windowId ? s.windows[windowId] : undefined;
  if (isIncognitoProfile(c.tab.profileId)) return c.windowId === windowId;
  return !w?.incognito;
}

function restoreTab(s: BrowserState, entry: ClosedTab, requested?: string | null): BrowserState {
  const owner = entry.tab.profileId;
  if (entry.pinnedTile && entry.tabId && !s.tabs[entry.tabId] && s.parkedPins[owner]?.tabs.some((p) => p.id === entry.tabId)) {
    const target = resolveWindowId(s, requested);
    let windowId = target && !s.windows[target]!.incognito && s.windows[target]!.profileId === owner ? target : undefined;
    let next = s;
    if (!windowId) {
      windowId = newId("w");
      next = withWindow(next, emptyWindow(windowId, owner, false));
    }
    next = adoptParkedPins(next, windowId, owner);
    if (next.tabs[entry.tabId]) return restoreTab(next, entry, windowId);
  }
  const closedTabs = s.closedTabs.filter((c) => c.id !== entry.id);
  if (entry.small && !isIncognitoProfile(entry.tab.profileId)) {
    const id = newId("w");
    const profileId = s.profiles[entry.tab.profileId] ? entry.tab.profileId : lastActiveProfile(s);
    const next = withWindow({ ...s, closedTabs }, smallWindow(id, profileId));
    return withNewTab(next, id, {
      url: entry.tab.url || undefined,
      profileId,
      snapshot: { ...entry.tab, pinned: false, profileId },
      adoptId: entry.tabId && entry.tab.url ? restoreId(entry.restoreFrom ?? entry.tabId) : undefined,
    })[0];
  }
  const tile = entry.pinnedTile && entry.tabId ? s.tabs[entry.tabId] : undefined;
  const swapped = tile && !hasPage(tile) && holderOf(s, tile.id) ? swapPinPage({ ...s, closedTabs }, tile.id) : null;
  if (swapped) return apply(swapped.state, activated(swapped.state, swapped.holderId));
  if (tile) {
    const unloaded = !hasPage(tile);
    const tabs = unloaded
      ? { ...s.tabs, [tile.id]: { ...tile, url: entry.tab.url, title: entry.tab.title, favicon: entry.tab.favicon, muted: entry.tab.muted, adoptId: restoreId(entry.restoreFrom ?? tile.id) } }
      : s.tabs;
    const next: BrowserState = { ...s, closedTabs, tabs };
    return apply(next, activated(next, tile.id));
  }
  const original = s.windows[entry.windowId];
  let windowId = original && canRestoreTabInto(s, entry, original.id) ? original.id : resolveWindowId(s, requested);
  let next: BrowserState = { ...s, closedTabs };
  if (!windowId || !canRestoreTabInto(s, entry, windowId)) {
    if (isIncognitoProfile(entry.tab.profileId)) return next;
    windowId = newId("w");
    next = withWindow(next, emptyWindow(windowId, s.profiles[entry.tab.profileId] ? entry.tab.profileId : s.settings.defaultProfileId, false));
  }
  const w = next.windows[windowId]!;
  const profileId = isIncognitoProfile(entry.tab.profileId) || s.profiles[entry.tab.profileId] ? entry.tab.profileId : w.profileId;
  const [withTab, tabId] = withNewTab(next, windowId, {
    url: entry.tab.url || undefined,
    profileId,
    snapshot: entry.tab,
    index: w.id === entry.windowId ? entry.index : undefined,
    adoptId: entry.tabId && entry.tab.url ? restoreId(entry.restoreFrom ?? entry.tabId) : undefined,
  });
  next = withTab;
  if (entry.group) next = { ...next, groups: rejoinGroups(next.groups, [entry.group, ...(entry.parents ?? [])], [tabId], windowId, profileId) };
  return next;
}

function restoreWindow(s: BrowserState, entry: ClosedWindow): BrowserState {
  const id = newId("w");
  const profileOk = (p: string) => (s.profiles[p] ? p : s.settings.defaultProfileId);
  const w = emptyWindow(id, profileOk(entry.window.profileId), false, entry.window.frame);
  Object.assign(w, entry.window, { profileId: profileOk(entry.window.profileId) });
  const tabs = { ...s.tabs };
  const live = { ...s.live };
  const ids: string[] = [];
  for (const { active, tabId, ...snap } of entry.tabs) {
    const t = makeTab(id, profileOk(snap.profileId), "", { ...snap, profileId: profileOk(snap.profileId) });
    if (tabId && snap.url) t.wakeAdoptId = restoreId(tabId);
    tabs[t.id] = t;
    live[t.id] = IDLE_LIVE;
    ids.push(t.id);
    if (active || !w.activeTabIds[t.profileId]) w.activeTabIds[t.profileId] = t.id;
  }
  w.tabIds = pinnedFirst(ids, tabs);
  let groups = s.groups;
  const restored = new Map<string, string>();
  for (const { tabIndexes, parentId: _, ...g } of entry.groups) {
    const members = tabIndexes.map((i) => ids[i]).filter((t): t is string => !!t);
    if (!members.length) continue;
    const [next, groupId] = restoreGroup(groups, { ...g, windowId: id }, members);
    groups = next;
    restored.set(g.id, groupId);
  }
  for (const g of entry.groups) {
    const groupId = restored.get(g.id);
    const parent = g.parentId && restored.get(g.parentId);
    if (groupId && parent) groups = { ...groups, [groupId]: { ...groups[groupId]!, parentId: parent } };
  }
  let next = withWindow({ ...s, tabs, live, groups, closedWindows: s.closedWindows.filter((c) => c.id !== entry.id) }, w);
  const shown = w.activeTabIds[w.profileId] ?? w.tabIds[0]!;
  next = adoptParkedPins(next, id, w.profileId);
  next = apply(next, activated(next, shown));
  return next;
}
