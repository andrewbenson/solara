import { onPinnedLink, resolvePinnedLink, setPinnedLinkSources } from "@solara/solaracore";
import { useBrowser, type BrowserState } from "../store/browser";
import { isWindowClosing } from "../store/closingWindows";
import { activeTabId, isPinnedRow } from "../store/model";
import { isSmall } from "../store/small";
import { splitOf } from "../store/splits";
import { pinnedLinkController } from "./pinnedLinkController";

let started = false;

export function pinnedLinkSourceIds(s: Pick<BrowserState, "tabs" | "windows">): string[] {
  const ids: string[] = [];
  for (const w of Object.values(s.windows)) {
    if (w.kind === "small") continue;
    for (const id of w.tabIds) {
      const t = s.tabs[id];
      if (!t?.pinned) continue;
      if (t.windowId === w.id) ids.push(id);
    }
  }
  return ids.sort();
}

function liveSourceWindow(s: BrowserState, id: string) {
  const t = s.tabs[id];
  const w = t && s.windows[t.windowId];
  return t && w && !isSmall(s, w.id) && !isWindowClosing(w.id) && w.tabIds.includes(id) ? { t, w } : null;
}

export function startPinnedLinks() {
  if (started) return;
  started = true;
  let lastSources = "";
  const syncSources = () => {
    const sources = pinnedLinkSourceIds(useBrowser.getState());
    const signature = sources.join("\n");
    if (signature === lastSources) return;
    lastSources = signature;
    void setPinnedLinkSources(sources);
  };
  syncSources();
  let syncQueued = false;
  useBrowser.subscribe((s, prev) => {
    if (syncQueued || (s.tabs === prev.tabs && s.windows === prev.windows)) return;
    syncQueued = true;
    queueMicrotask(() => {
      syncQueued = false;
      syncSources();
    });
  });
  onPinnedLink(pinnedLinkController({
    source(id) {
      const s = useBrowser.getState();
      const live = liveSourceWindow(s, id);
      const active = live ? activeTabId(s, live.w.id) : undefined;
      if (!live || live.w.profileId !== live.t.profileId || !active || (active !== id && !splitOf(s, active)?.tabIds.includes(id))) return null;
      const { t, w } = live;
      return {
        id,
        identity: `${t.id}:${w.id}:${t.profileId}:${t.createdAt}:${t.url.split("#", 1)[0]}`,
        url: t.url,
        pinned: t.pinned,
        topApp: t.pinned && !isPinnedRow(t),
        target: s.settings.pinnedLinkTarget,
        incognito: w.incognito,
      };
    },
    present: (id) => !!liveSourceWindow(useBrowser.getState(), id),
    answer: resolvePinnedLink,
    open(source, url, route, point) {
      const s = useBrowser.getState();
      const live = liveSourceWindow(s, source.id);
      if (!live) return;
      const { t, w } = live;
      if (route === "peek") s.openPeek(t.id, url, point);
      else if (route === "littleSolara") s.createWindow({ small: true, profileId: t.profileId, url });
      else s.newTab(w.id, { url, openerId: t.id, profileId: t.profileId, background: route === "background" });
    },
  }));
}
