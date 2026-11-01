import type { StorePatch, StoreEffect } from "@solara/store";
import { cancelDownload, endWebKitPrivateSession } from "@solara/solaracore";
import type { BrowserState, HydrateData } from "./browser";
import { bookmarkRoots, ensureRoots, removeBookmarkTree } from "./bookmarks";
import { IDLE_LIVE, without } from "./model";
import { rememberNativeClosingLocals } from "./closingWindowRestore";
import { runPinHandoff } from "./tabs";
import { startNavigation } from "../lib/earlyNavigate";
import { commandBarFocus, expectFocus } from "../lib/focusClaims";

export const WORKSPACE_COMMANDS: ReadonlySet<string> = new Set([
  "newTab", "closeTab", "closeTabs", "activate", "handOffPin", "activateIndex", "cycle", "navigate", "updateTab", "navigated", "faviconChanged",
  "duplicateTab", "togglePin", "moveTab", "moveTabBy", "createWindow", "closeWindow", "restoreClosingWindow", "forgetClosedWindow", "setWindowFrame", "setWindowFullScreen", "toggleSidebar",
  "switchProfile", "moveTabsToWindow", "moveTabToProfile", "mergeAllWindows", "reopenClosed", "reopenClosedTab", "reopenClosedWindow",
  "restoreClosed", "createProfile", "updateProfile", "deleteProfile", "reorderProfiles", "setDefaultProfile", "profileDataDeleted",
  "createGroup", "updateGroup", "addTabsToGroup", "removeTabsFromGroup", "ungroup", "newNestedGroup", "closeGroup", "deleteGroup",
  "placeTabs", "dropTabs", "pinTabs", "returnToPinnedUrl", "setPinnedUrl", "setMuted", "setSiteMuted", "groupTabs", "groupOnto", "moveGroup",
  "duplicateGroup", "newTabInGroup", "cleanUpTabs", "restoreCleaned", "clearUnpinnedTabs", "undoClearTabs", "removeClosedPin",
  "closeAbandonedNewTabs", "createSplit", "openSplitPane", "replaceSplitPane", "removeTabFromSplit", "separateSplit", "updateSplit",
  "flipSplit", "toggleSplitOrientation", "movePane", "focusPane", "toggleTabLayout", "openPeek", "closePeek", "peekToTab", "updateSettings",
  "setFocusedWindow", "setFind", "upsertDownload", "removeDownload", "clearDownloads", "forgetDownloads", "tidyPins", "untidyPins",
  "renameTileFolder", "newTileFolder", "leaveTileFolder", "dissolveTileFolder", "openDraftGroups", "forgetClosedTab",
  "setSelection", "setSelectionAnchor", "clickTab", "openPanel", "closePanel", "setDownloadsOpen",
]);

export const COMMAND_PRELUDES: ReadonlyMap<string, (...args: unknown[]) => void> = new Map([
  ["openPanel", (windowId: unknown) => expectFocus(windowId as string, commandBarFocus)],
]);

export const LIVE_PATCH_COMMANDS: ReadonlySet<string> = new Set(["updateTab", "navigated"]);

const TABLES = ["profiles", "windows", "tabs", "groups", "splits"] as const;
const LISTS = ["profileOrder", "orphanedProfileData", "windowOrder", "closedTabs", "closedWindows", "closedGroups", "deletedGroups", "cleanedTabs", "downloads"] as const;
const KEYED = ["privateCleanedTabs", "privateSiteMutes"] as const;

type TablePatch = { upsert: Record<string, unknown>[]; remove: string[]; order?: string[] };

function applyTable(current: Record<string, unknown>, patch: TablePatch, keyOf: (entry: Record<string, unknown>) => [string, unknown]) {
  const next: Record<string, unknown> = { ...current };
  for (const id of patch.remove) delete next[id];
  for (const entry of patch.upsert) {
    const [id, value] = keyOf(entry);
    next[id] = value;
  }
  if (!patch.order) return next;
  const ordered: Record<string, unknown> = {};
  for (const id of patch.order) if (id in next) ordered[id] = next[id];
  return ordered;
}

const byId = (entry: Record<string, unknown>): [string, unknown] => [entry.id as string, entry];
const keyedBy = (key: string) => (entry: Record<string, unknown>): [string, unknown] => {
  const { [key]: id, ...rest } = entry;
  return [id as string, rest];
};
const tableOf = (entry: Record<string, unknown>): [string, unknown] => [entry.profileId as string, entry.table];

export function workspaceFromPatch(s: BrowserState, patch: StorePatch): Partial<BrowserState> {
  const next: Record<string, unknown> = {};
  const p = patch as Record<string, unknown>;
  const state = s as unknown as Record<string, Record<string, unknown>>;
  for (const name of TABLES) if (p[name]) next[name] = applyTable(state[name]!, p[name] as TablePatch, byId);
  if (p.peeks) next.peeks = applyTable(state.peeks!, p.peeks as TablePatch, keyedBy("windowId"));
  if (p.parkedPins) next.parkedPins = applyTable(state.parkedPins!, p.parkedPins as TablePatch, keyedBy("profileId"));
  for (const name of ["pinChoices", "pinSync"] as const) if (p[name]) next[name] = applyTable(state[name]!, p[name] as TablePatch, tableOf);
  for (const name of [...LISTS, ...KEYED]) if (name in p) next[name] = p[name];
  if (p.ui) next.ui = retainingJSON(s.ui, { ...s.ui, ...(p.ui as object) });
  if (p.find) next.find = applyTable(state.find!, p.find as TablePatch, (entry) => [entry.tabId as string, entry.state]);
  if (p.selection) next.selection = applyTable(state.selection!, p.selection as TablePatch, (entry) => [entry.windowId as string, entry.ids]);
  if (p.selectionAnchors) next.selectionAnchors = applyTable(state.selectionAnchors!, p.selectionAnchors as TablePatch, (entry) => [entry.windowId as string, entry.tabId]);
  if (p.windowUi) next.windowUi = applyTable(state.windowUi!, p.windowUi as TablePatch, (entry) => [entry.windowId as string, entry.state]);
  if (patch.settings) {
    const settings = { ...s.settings, ...(patch.settings.set ?? {}) } as Record<string, unknown>;
    for (const key of patch.settings.remove ?? []) delete settings[key];
    next.settings = settings;
  }
  return withDerived(s, { ...s, ...next } as BrowserState, next);
}

function withDerived(prev: BrowserState, s: BrowserState, next: Record<string, unknown>): Partial<BrowserState> {
  const out = next as Partial<BrowserState>;
  if (s.tabs !== prev.tabs) {
    const gone = new Set(Object.keys(prev.tabs).filter((id) => !s.tabs[id]));
    let live = gone.size ? without(prev.live, gone) : prev.live;
    for (const id of Object.keys(s.tabs)) {
      if (live[id]) continue;
      if (live === prev.live) live = { ...prev.live };
      live[id] = IDLE_LIVE;
    }
    for (const t of Object.values(s.tabs)) {
      const holder = t.pageIn ? live[t.pageIn] : undefined;
      if (!holder || live[t.id] === holder) continue;
      if (live === prev.live) live = { ...prev.live };
      live[t.id] = { ...holder };
    }
    if (live !== prev.live) out.live = live;
  }
  rememberNativeClosingLocals(prev, { ...s, ...out });
  return out;
}

export function runEffects(effects: StoreEffect[] | undefined, get: () => BrowserState, set: (partial: Partial<BrowserState>) => void) {
  for (const effect of effects ?? []) {
    const s = get();
    switch (effect.type) {
      case "swapTabs": {
        const a = effect.a as string;
        const b = effect.b as string;
        set({ live: { ...s.live, [b]: { ...(s.live[a] ?? s.live[b] ?? IDLE_LIVE) } } });
        break;
      }
      case "startNavigation":
        startNavigation(effect.tabId as string, effect.navigation as Parameters<typeof startNavigation>[1]);
        break;
      case "pinHandoff": {
        const id = effect.tabId as string;
        runPinHandoff(id, () => get().handOffPin(id));
        break;
      }
      case "profileCreated": {
        const id = effect.profileId as string;
        const source = effect.sharedWith as string | null;
        if (source) {
          const [withRoots, roots] = ensureRoots(s.bookmarks, source);
          set({
            bookmarks: { ...withRoots, roots: { ...withRoots.roots, [id]: roots } },
            ...(s.history[source] ? { history: { ...s.history, [id]: s.history[source]! } } : {}),
          });
        } else set({ bookmarks: ensureRoots(s.bookmarks, id)[0] });
        break;
      }
      case "profileDeleted": {
        const id = effect.profileId as string;
        const roots = bookmarkRoots(s.bookmarks, id);
        set({
          history: without(s.history, [id]),
          bookmarks: roots && !effect.shared ? removeBookmarkTree(s.bookmarks, [roots.bar, roots.other], id) : { ...s.bookmarks, roots: without(s.bookmarks.roots, [id]) },
        });
        break;
      }
      case "cancelDownload":
        void cancelDownload(effect.id as string);
        break;
      case "endPrivateSession":
        void endWebKitPrivateSession(effect.session as string);
        break;
      default:
        effectHandlers.get(effect.type)?.(effect);
    }
  }
}

const effectHandlers = new Map<string, (effect: StoreEffect) => void>();
export const onStoreEffect = (type: string, handler: (effect: StoreEffect) => void) => {
  effectHandlers.set(type, handler);
  return () => effectHandlers.delete(type);
};

function retainingJSON(previous: unknown, value: unknown): unknown {
  if (previous === value || JSON.stringify(previous) === JSON.stringify(value)) return previous;
  if (Array.isArray(previous) && Array.isArray(value)) {
    const byId = new Map(previous.filter((entry) => entry && typeof entry === "object" && "id" in entry).map((entry) => [entry.id, entry]));
    return value.map((entry, index) => retainingJSON(entry && typeof entry === "object" && "id" in entry ? byId.get(entry.id) : previous[index], entry));
  }
  if (previous && value && typeof previous === "object" && typeof value === "object" && !Array.isArray(previous) && !Array.isArray(value)) {
    const before = previous as Record<string, unknown>;
    return Object.fromEntries(Object.entries(value).map(([key, entry]) => [key, retainingJSON(before[key], entry)]));
  }
  return value;
}

export function workspaceHydration(s: BrowserState, data: HydrateData): Partial<BrowserState> {
  let bookmarks = data.bookmarks ?? s.bookmarks;
  for (const id of s.profileOrder) bookmarks = ensureRoots(bookmarks, id)[0];
  return {
    history: Object.fromEntries(Object.entries(data.history ?? {}).filter(([id]) => s.profiles[id])),
    historyReady: Object.fromEntries(Object.keys(data.history ?? {}).filter((id) => s.profiles[id]).map((id) => [id, true as const])),
    bookmarks,
    bookmarksReady: Object.fromEntries(Object.keys(data.bookmarks?.roots ?? {}).filter((id) => s.profiles[id]).map((id) => [id, true as const])),
    live: Object.fromEntries(Object.keys(s.tabs).map((id) => [id, IDLE_LIVE])),
  };
}

export function workspaceFromSnapshot(s: BrowserState, data: Record<string, unknown>, { keepLocal = false } = {}): Partial<BrowserState> {
  const next: Record<string, unknown> = {};
  for (const name of [...TABLES, "peeks", "parkedPins", "pinChoices", "pinSync", ...LISTS, ...KEYED]) if (name in data) next[name] = retainingJSON((s as unknown as Record<string, unknown>)[name], data[name]);
  if (data.settings) next.settings = retainingJSON(s.settings, data.settings);
  if (data.ui) next.ui = retainingJSON(s.ui, { ...s.ui, ...(data.ui as object) });
  const tabs = (next.tabs ?? {}) as BrowserState["tabs"];
  next.live = Object.fromEntries(Object.keys(tabs).map((id) => [id, (keepLocal && s.live[id]) || IDLE_LIVE]));
  for (const name of ["find", "selection", "selectionAnchors", "windowUi"] as const) next[name] = retainingJSON(s[name], data[name] ?? {});
  let bookmarks = s.bookmarks;
  for (const id of (next.profileOrder ?? []) as string[]) bookmarks = ensureRoots(bookmarks, id)[0];
  next.bookmarks = bookmarks;
  rememberNativeClosingLocals(s, { ...s, ...next } as BrowserState);
  return next as Partial<BrowserState>;
}
