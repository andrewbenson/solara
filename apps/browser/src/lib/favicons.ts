import { persistenceRefused } from "./persistLatch";
import { nativeOwnsWorkspace, nativeSafeMode } from "../store/nativeStore";
import { faviconsFor, fetchFavicon, onHistoryChanged } from "@solara/solaracore";
import * as settings from "@solara/settings";
import { nativeSnapshot } from "@solara/store";
import { iconTheme, readDocument, removeDocument, type IconTheme } from "@solara/shell";
import { useEffect, useState } from "react";
import { create } from "zustand";
import { pageOf, patchPage } from "../components/layout/pageState";
import { batchStoreUpdates, type BrowserState } from "../store/browser";
import type { Tab } from "../store/types";
import { engineProfile, isIncognitoProfile } from "../store/model";
import { DEFAULT_PROFILE_ID } from "../store/settings";
import { engineProfileLoaded, onLoadedProfilesChanged } from "./lazyProfiles";
import { webviews } from "./webviews";

type Icons = {
  pages: Record<string, string | null>;
  srcs: Record<string, string>;
};

const EMPTY: Icons = { pages: {}, srcs: {} };
const MAX_ICONS = 3000;
const LOOKUP_DELAY_MS = 16;
const LOOKUP_BATCH = 200;

type Favicons = {
  profiles: Record<string, Icons>;
  themes: Record<string, IconTheme | null>;
};

export const useFavicons = create<Favicons>(() => ({ profiles: {}, themes: {} }));

const cacheKey = (profileId: string) => (isIncognitoProfile(profileId) ? profileId : engineProfile(profileId));
export const pageKey = (url: string) => url.replace(/#.*$/, "");
const siteOf = (url: string) => /^[a-z][\w+.-]*:\/\/[^/?#]*/i.exec(url)?.[0].toLowerCase() ?? "";
export const faviconOutlived = (iconPage: string | null, url: string) => !!iconPage && !!url && siteOf(iconPage) !== siteOf(url);

export function adoptIconPage(tabId: string, url?: string) {
  if (pageOf(tabId).iconPage === null) noteIconPage(tabId, url);
}

export function noteIconPage(tabId: string, url?: string) {
  patchPage(tabId, { iconPage: url || null });
}

export function shouldDropFavicon(tab: Pick<Tab, "id" | "favicon"> | undefined, url: string, isLoading: boolean) {
  return !isLoading && !!tab?.favicon && faviconOutlived(pageOf(tab.id).iconPage, url);
}

type Change = (f: Favicons) => Favicons;
const FLUSH_MS = 16;
const changes: Change[] = [];
let flushTimer: ReturnType<typeof setTimeout> | undefined;

function queue(change: Change, now = false) {
  changes.push(change);
  if (now) flush();
  else flushTimer ??= setTimeout(flush, FLUSH_MS);
}

function flush() {
  clearTimeout(flushTimer);
  flushTimer = undefined;
  const all = changes.splice(0);
  if (all.length) batchStoreUpdates(() => useFavicons.setState((f) => all.reduce((s, change) => change(s), f)));
}

function update(key: string, change: (icons: Icons) => Icons, now = false) {
  queue((f) => {
    const before = f.profiles[key] ?? EMPTY;
    const after = change(before);
    return after === before ? f : { ...f, profiles: { ...f.profiles, [key]: after } };
  }, now);
}

const capped = <T,>(map: Record<string, T>, key: string, value: T): Record<string, T> =>
  Object.keys(map).length >= MAX_ICONS ? { [key]: value } : { ...map, [key]: value };

let watching = false;
let touched: Set<string> | null = new Set();
const touch = (page: string) => void (watching && touched?.add(page));
const touchAll = () => void (touched = null);

const queued = new Map<string, Set<string>>();
const writes = new Map<string, number>();
let lookupsInFlight = 0;
const wrote = (key: string, page: string) => void (lookupsInFlight && writes.set(`${key}|${page}`, (writes.get(`${key}|${page}`) ?? 0) + 1));
const asked = new Set<string>();
let lookupTimer: ReturnType<typeof setTimeout> | undefined;

function ask(key: string, page: string) {
  if (!engineProfileLoaded(key) || isIncognitoProfile(key) || asked.has(`${key}|${page}`)) return;
  asked.add(`${key}|${page}`);
  if (!queued.has(key)) queued.set(key, new Set());
  queued.get(key)!.add(page);
  lookupTimer ??= setTimeout(lookUp, LOOKUP_DELAY_MS);
}

function lookUp() {
  lookupTimer = undefined;
  const batches = [...queued];
  queued.clear();
  for (const [key, pages] of batches) {
    const all = [...pages];
    for (let i = 0; i < all.length; i += LOOKUP_BATCH) lookUpPages(key, all.slice(i, i + LOOKUP_BATCH));
  }
}

function lookUpPages(key: string, list: string[]) {
  if (!engineProfileLoaded(key)) {
    for (const page of list) asked.delete(`${key}|${page}`);
    return;
  }
  const started = list.map((page) => writes.get(`${key}|${page}`));
  lookupsInFlight++;
  void faviconsFor(key, list)
    .then((found) =>
      update(key, (icons) => {
        let next: Record<string, string | null> | undefined;
        for (const [i, page] of list.entries()) {
          if (writes.get(`${key}|${page}`) !== started[i]) continue;
          const uri = found.pages.get(page)?.uri ?? null;
          if (icons.pages[page] === uri) continue;
          next ??= { ...icons.pages };
          next[page] = uri;
          touch(page);
        }
        return next ? { ...icons, pages: next } : icons;
      }, true),
    )
    .catch((error) => {
      for (const page of list) asked.delete(`${key}|${page}`);
      console.warn("[favicons] lookup failed", error);
    })
    .finally(() => {
      if (--lookupsInFlight === 0) writes.clear();
    });
}

const inflight = new Map<string, Promise<string | null>>();

export function noteFavicon(tab: Pick<Tab, "id" | "url" | "profileId">, src: string) {
  if (!tab.url || !src || isIncognitoProfile(tab.profileId)) return;
  const key = cacheKey(tab.profileId);
  const page = pageKey(tab.url);
  const known = useFavicons.getState().profiles[key]?.srcs[src];
  if (known) return remember(key, page, src, known);
  const handle = webviews.get(tab.id);
  if (!handle) return;
  const id = `${key}|${src}`;
  let pending = inflight.get(id);
  if (!pending) {
    pending = handle
      .downloadFavicon(src)
      .then((image) => image?.uri ?? null)
      .catch(() => null);
    inflight.set(id, pending);
    void pending.finally(() => inflight.delete(id));
  }
  void pending.then((uri) => uri && remember(key, page, src, uri));
}

function remember(key: string, page: string, src: string, uri: string) {
  const icons = changes.length ? undefined : useFavicons.getState().profiles[key];
  if (icons && icons.pages[page] === uri && icons.srcs[src] === uri) return;
  wrote(key, page);
  update(key, (icons) => {
    const previous = icons.pages[page];
    if (previous === uri && icons.srcs[src] === uri) return icons;
    const startsOver = Object.keys(icons.pages).length >= MAX_ICONS;
    if (startsOver) touchAll();
    else touch(page);
    const pages = startsOver ? { [page]: uri } : { ...icons.pages, [page]: uri };
    return { pages, srcs: icons.srcs[src] === uri ? icons.srcs : capped(icons.srcs, src, uri) };
  });
}

export type KnownFavicon = { page: string; icon: string; png: string };

export function adoptFaviconCache(profileId: string, known: KnownFavicon[]): Map<string, KnownFavicon> | null {
  if (isIncognitoProfile(profileId) || !known.length) return null;
  const key = cacheKey(profileId);
  const found = new Map(known.map((f) => [pageKey(f.page), f]));
  for (const page of found.keys()) wrote(key, page);
  update(key, (icons) => {
    const fresh = [...found].filter(([page]) => !icons.pages[page]);
    if (!fresh.length) return icons;
    const startsOver = Object.keys(icons.pages).length + fresh.length > MAX_ICONS;
    if (startsOver) touchAll();
    const pages: Record<string, string | null> = startsOver ? {} : { ...icons.pages };
    for (const [page, f] of fresh) {
      pages[page] = `data:image/png;base64,${f.png}`;
      touch(page);
    }
    return { ...icons, pages };
  }, true);
  return found;
}

const failedFetches = new Set<string>();

function fetchMissing(profileId: string, url: string, src: string) {
  const key = cacheKey(profileId);
  if (!engineProfileLoaded(key) || isIncognitoProfile(profileId) || !/^https?:/i.test(src)) return;
  const id = `${key}|${src}`;
  if (inflight.has(id) || failedFetches.has(id)) return;
  const pending = fetchFavicon(src, key)
    .then(async (image) => {
      const uri = image?.uri ?? null;
      if (uri?.startsWith("data:image/png;base64,")) await settings.nativeStoreFavicon(key, pageKey(url), src, uri.slice(22)).catch(() => null);
      return uri;
    })
    .catch(() => null);
  inflight.set(id, pending);
  void pending.then((uri) => {
    inflight.delete(id);
    if (uri) remember(key, pageKey(url), src, uri);
    else failedFetches.add(id);
  });
}

export function faviconFailed(profileId: string, uri: string) {
  update(cacheKey(profileId), (icons) => {
    if (!Object.values(icons.pages).includes(uri) && !Object.values(icons.srcs).includes(uri)) return icons;
    touchAll();
    return {
      pages: Object.fromEntries(Object.entries(icons.pages).map(([page, u]) => [page, u === uri ? null : u])),
      srcs: Object.fromEntries(Object.entries(icons.srcs).filter(([, u]) => u !== uri)),
    };
  });
}

export type ResolvedFavicon = { uri: string; profileId: string };

function lookupIn(key: string, url: string, src: string | null | undefined): string | undefined {
  const icons = useFavicons.getState().profiles[key];
  if (!icons) return undefined;
  const page = pageKey(url);
  return (src ? icons.srcs[src] : undefined) ?? icons.pages[page] ?? undefined;
}

function lookupScope(profileId?: string): string {
  return profileId ?? DEFAULT_PROFILE_ID;
}

export function resolveFavicon(url: string, src?: string | null, profileId?: string): ResolvedFavicon | null {
  if (!url) return null;
  const id = lookupScope(profileId);
  const uri = isIncognitoProfile(id) ? undefined : lookupIn(cacheKey(id), url, src);
  return uri ? { uri, profileId: id } : null;
}

export type LaunchFavicons = {
  images: string[];
  profiles: Record<string, { pages: Record<string, number>; srcs: Record<string, number> }>;
  themes: Record<string, IconTheme | null>;
};

const LAUNCH_ICON_LIMIT = 240;
const LAUNCH_URI_LIMIT = 16 * 1024;
export const LAUNCH_FAVICONS_LIMIT = 1024 * 1024;

const serialized = (value: unknown) => JSON.stringify(value).length + 1;

export function launchFavicons(tabs: { id?: string; url: string; favicon: string | null; profileId: string }[]): LaunchFavicons {
  const { profiles, themes } = useFavicons.getState();
  const ids = tabs.flatMap((tab) => tab.id && tab.url && !isIncognitoProfile(tab.profileId) ? [tab.id] : []).slice(0, LAUNCH_ICON_LIMIT);
  const native = nativeOwnsWorkspace() ? settings.nativeCachedFaviconURIs?.(ids) ?? {} : {};
  const look: LaunchFavicons = { images: [], profiles: {}, themes: {} };
  const indexOf = new Map<string, number>();
  let size = serialized(look);
  for (const t of tabs) {
    if (indexOf.size >= LAUNCH_ICON_LIMIT) break;
    if (!t.url || isIncognitoProfile(t.profileId)) continue;
    const key = cacheKey(t.profileId);
    const icons = profiles[key];
    const page = pageKey(t.url);
    const nativeURI = t.id ? native[t.id] : undefined;
    const uri = nativeURI ?? icons?.pages[page];
    if (!uri || uri.length > LAUNCH_URI_LIMIT || look.profiles[key]?.pages[page] !== undefined) continue;
    const fromSrc = t.favicon ? nativeURI ?? icons?.srcs[t.favicon] : undefined;
    const src = t.favicon && fromSrc && fromSrc.length <= LAUNCH_URI_LIMIT ? fromSrc : undefined;
    const fresh = [...new Set([uri, src].filter((u): u is string => !!u && !indexOf.has(u)))];
    const cost =
      (look.profiles[key] ? 0 : serialized(key) + serialized({ pages: {}, srcs: {} })) +
      serialized(page) + 6 +
      (src && t.favicon ? serialized(t.favicon) + 6 : 0) +
      fresh.reduce((sum, u) => sum + serialized(u) + (themes[u] !== undefined ? serialized(themes[u] ?? null) + 8 : 0), 0);
    if (size + cost > LAUNCH_FAVICONS_LIMIT) continue;
    size += cost;
    for (const u of fresh) {
      indexOf.set(u, look.images.push(u) - 1);
      if (themes[u] !== undefined) look.themes[indexOf.get(u)!] = themes[u] ?? null;
    }
    const entry = (look.profiles[key] ??= { pages: {}, srcs: {} });
    entry.pages[page] = indexOf.get(uri)!;
    if (src && t.favicon) entry.srcs[t.favicon] = indexOf.get(src)!;
  }
  return look;
}

const imagesOf = (map: unknown, images: string[]): Record<string, string> =>
  map && typeof map === "object"
    ? Object.fromEntries(Object.entries(map).flatMap(([k, i]) => (typeof i === "number" && typeof images[i] === "string" ? [[k, images[i]!]] : [])))
    : {};

export function seedFavicons(seed: LaunchFavicons) {
  const images = Array.isArray(seed.images) ? seed.images : [];
  const seeded = Object.entries(seed.profiles ?? {}).filter(([key]) => !isIncognitoProfile(key));
  if (!seeded.length || !images.length) return;
  const themes: Record<string, IconTheme | null> = {};
  for (const [i, theme] of Object.entries(seed.themes && typeof seed.themes === "object" ? seed.themes : {})) {
    const uri = images[Number(i)];
    if (typeof uri === "string" && (theme === null || typeof theme === "object")) themes[uri] = theme;
  }
  useFavicons.setState((f) => {
    const profiles = { ...f.profiles };
    for (const [key, saved] of seeded) {
      const icons = profiles[key] ?? EMPTY;
      profiles[key] = {
        pages: { ...imagesOf(saved?.pages, images), ...icons.pages },
        srcs: { ...imagesOf(saved?.srcs, images), ...icons.srcs },
      };
    }
    return { profiles, themes: { ...themes, ...f.themes } };
  });
}

function answered(url: string, profileId?: string): boolean {
  const { profiles } = useFavicons.getState();
  const page = pageKey(url);
  const id = lookupScope(profileId);
  return isIncognitoProfile(id) || profiles[cacheKey(id)]?.pages[page] !== undefined;
}

type Watcher = { url: string; src?: string | null; profileId?: string; known?: boolean };
const watchers = new Map<string, Set<Watcher>>();

function check(w: Watcher) {
  const known = answered(w.url, w.profileId);
  if (known === w.known) return;
  w.known = known;
  if (!known) ask(cacheKey(lookupScope(w.profileId)), pageKey(w.url));
  else if (w.src && w.profileId && !resolveFavicon(w.url, w.src, w.profileId)) fetchMissing(w.profileId, w.url, w.src);
}

function onFavicons(f: Favicons, prev: Favicons) {
  const pages = touched;
  touched = new Set();
  if (f.profiles === prev.profiles) return;
  for (const page of pages ?? [...watchers.keys()]) for (const w of [...(watchers.get(page) ?? [])]) check(w);
}

function watch(w: Watcher) {
  if (!watching) {
    watching = true;
    useFavicons.subscribe(onFavicons);
  }
  const page = pageKey(w.url);
  let set = watchers.get(page);
  if (!set) watchers.set(page, (set = new Set()));
  set.add(w);
  check(w);
  return () => {
    set.delete(w);
    if (!set.size && watchers.get(page) === set) watchers.delete(page);
  };
}

export function useFavicon(url: string, src?: string | null, profileId?: string, dark?: boolean): ResolvedFavicon | null {
  const owned = nativeOwnsWorkspace() && dark !== undefined;
  const scope = profileId ?? DEFAULT_PROFILE_ID;
  const request = JSON.stringify([url, src, scope, dark]);
  const [native, setNative] = useState<{ request: string; uri: string } | null>(null);
  useEffect(() => {
    if (!owned || !url) return;
    let generation = 0;
    const refresh = () => {
      const ticket = ++generation;
      void settings.nativeFaviconURI?.(url, src ?? null, scope, dark)?.then((uri) => {
        if (generation === ticket) setNative(uri ? { request, uri } : null);
      }).catch(() => {});
    };
    const subscription = settings.onNativeFaviconInvalidated?.(refresh);
    refresh();
    return () => {
      generation++;
      subscription?.remove();
    };
  }, [owned, url, src, scope, dark, request]);
  const key = useFavicons(() => {
    const found = owned && isIncognitoProfile(scope) ? null : resolveFavicon(url, src, owned ? scope : profileId);
    return found ? `${found.profileId} ${found.uri}` : null;
  });
  const missing = !owned && !!url && !key;
  useEffect(() => (missing ? watch({ url, src, profileId }) : undefined), [missing, profileId, url, src]);
  const split = key?.indexOf(" ") ?? -1;
  if (owned && native?.request === request) return { profileId: scope, uri: native.uri };
  return key ? { profileId: key.slice(0, split), uri: key.slice(split + 1) } : null;
}

const theming = new Set<string>();

export function useFaviconTheme(url: string, src?: string | null, profileId?: string, resolvedURI?: string | null): IconTheme | null | undefined {
  const uri = useFavicons(() => resolvedURI === undefined ? resolveFavicon(url, src, profileId)?.uri ?? null : resolvedURI);
  const theme = useFavicons((f) => (uri ? f.themes[uri] : undefined));
  const pending = !!uri && theme === undefined;
  useEffect(() => {
    if (!pending || !uri || theming.has(uri)) return;
    theming.add(uri);
    void iconTheme({ uri })
      .catch(() => null)
      .then((found) => queue((f) => (f.themes[uri] === (found ?? null) ? f : { ...f, themes: capped(f.themes, uri, found ?? null) })))
      .finally(() => theming.delete(uri));
  }, [pending, uri]);
  return theme;
}

function forget(key: string) {
  for (const id of [...asked]) if (id.startsWith(`${key}|`)) asked.delete(id);
  touchAll();
  update(key, () => EMPTY, true);
}

export const pruneProfileFavicons = (profileId: string) => forget(cacheKey(profileId));

function removeLegacyFiles(s: Pick<BrowserState, "profiles">) {
  if (nativeSafeMode()) return;
  for (const id of Object.keys(s.profiles)) {
    const doc = `favicons-${id}.json`;
    try {
      if (readDocument(doc) === null) continue;
      if (!persistenceRefused()) removeDocument(doc);
    } catch (error) {
      console.warn(`[favicons] couldn't remove ${doc}`, error);
    }
  }
}

export function startFavicons() {
  if (nativeOwnsWorkspace()) {
    const profiles = nativeSnapshot()?.data.profiles as BrowserState["profiles"] | undefined;
    if (profiles) removeLegacyFiles({ profiles });
    return () => {};
  }
  const stopLoads = onLoadedProfilesChanged(() => {
    for (const set of watchers.values()) for (const watcher of set) { watcher.known = undefined; check(watcher); }
  });
  const history = onHistoryChanged((change) => {
    if (change.kind !== "deleted") return;
    if (change.all) return forget(change.profile);
    const gone = new Set(change.urls.map(pageKey));
    const key = change.profile;
    for (const page of gone) asked.delete(`${key}|${page}`);
    update(key, (icons) => {
      if (!Object.keys(icons.pages).some((page) => gone.has(page))) return icons;
      for (const page of gone) touch(page);
      return { ...icons, pages: Object.fromEntries(Object.entries(icons.pages).filter(([page]) => !gone.has(page))) };
    });
  });
  return () => {
    history.remove();
    stopLoads();
  };
}
