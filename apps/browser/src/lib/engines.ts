import { nativeSafeMode } from "../store/nativeStore";
import type { PageEngine } from "@solara/solaracore";
import { nativeEngineCommand, nativeAddHistoryVisits } from "@solara/settings";
import { create } from "zustand";
import { useBrowser } from "../store/browser";
import { hideKeyedToast, showToast } from "../components/layout/splitActions";
import { chosenEngine, siteOf, tabEngine, visitRecorder, type WebKitPage } from "../store/engines";
import { engineProfile, isIncognitoProfile } from "../store/model";
import type { Tab } from "../store/types";

export type EngineOffer = { site: string; host: string; keySystem: string; canRemember: boolean };

export const useEngineOffers = create<Record<string, EngineOffer>>(() => ({}));

const store = () => useBrowser.getState();
const pageUrl = (tab: Tab | undefined) => tab?.url || tab?.navigation?.url || "";
const declinedSites = new Set<string>();
const movingTabs = new Set<string>();
const hostLabel = (site: string) => new URL(site).hostname.replace(/^www\./, "");

export function setWebsiteEngine(url: string, engine: PageEngine | null) {
  const site = siteOf(url);
  if (!site) return;
  const rules = { ...store().settings.websiteEngines };
  if (engine) rules[site] = engine;
  else delete rules[site];
  store().updateSettings({ websiteEngines: rules });
}

export const persistEngine = (tabId: string, engine: PageEngine) => { void nativeEngineCommand(tabId, "persist", { engine }); };
export const goBackAcrossEngines = (tabId: string) => nativeEngineCommand(tabId, "back");
export const openPageIn = (tabId: string, engine: PageEngine, options: { rule?: PageEngine | null; checkWork?: boolean } = {}) => {
  clearEngineOffer(tabId);
  return nativeEngineCommand(tabId, "open", { engine, ...options });
};
export const togglePageEngine = (tabId: string) => nativeEngineCommand(tabId, "toggle");

export function offerWebKit(tabId: string, data: unknown) {
  const s = store();
  const t = s.tabs[tabId];
  if (!t || tabEngine(s, tabId) === "webkit") return;
  const site = siteOf(t.url);
  if (!site) return;
  const rule = chosenEngine(s, t.url);
  if (rule === "chromium" || declinedSites.has(site)) return;
  if (rule === "webkit") return void moveForProtectedVideo(tabId, site);
  if (useEngineOffers.getState()[tabId]?.site === site) return;
  const keySystem = typeof (data as { keySystem?: unknown } | null)?.keySystem === "string" ? (data as { keySystem: string }).keySystem : "";
  useEngineOffers.setState({ [tabId]: { site, host: hostLabel(site), keySystem, canRemember: !isIncognitoProfile(t.profileId) } });
}

export function clearEngineOffer(tabId: string) {
  if (!useEngineOffers.getState()[tabId]) return;
  useEngineOffers.setState((offers) => {
    const { [tabId]: _, ...rest } = offers;
    return rest;
  }, true);
}

export function stayOnPage(tabId: string, remember = false) {
  const offer = useEngineOffers.getState()[tabId];
  if (offer) declinedSites.add(offer.site);
  if (offer && remember && offer.canRemember) setWebsiteEngine(offer.site, "chromium");
  clearEngineOffer(tabId);
}

export const acceptEngineOffer = (tabId: string) => openPageIn(tabId, "webkit", { rule: "webkit" });

async function moveForProtectedVideo(tabId: string, site: string) {
  if (movingTabs.has(tabId)) return;
  movingTabs.add(tabId);
  try {
    if (!(await openPageIn(tabId, "webkit"))) {
      declinedSites.add(site);
      return;
    }
  } finally {
    movingTabs.delete(tabId);
  }
  const t = store().tabs[tabId];
  if (!t) return;
  const key = `engine-move:${tabId}`;
  const stillThere = () => siteOf(pageUrl(store().tabs[tabId])) === site;
  showToast(t.windowId, "Opened in WebKit for protected video", `${hostLabel(site)} plays here with FairPlay. WebKit keeps its own sign-ins.`, {
    icon: "play.rectangle",
    key,
    action: { title: "Move Back", run: () => void (stillThere() && openPageIn(tabId, "chromium", { rule: "chromium" })) },
  });
  const unwatchSite = useBrowser.subscribe((s, prev) => {
    if (s.tabs[tabId] === prev.tabs[tabId] || stillThere()) return;
    unwatchSite();
    hideKeyedToast(t.windowId, key);
  });
}

export function followSiteChoice(tabId: string, engine: PageEngine, url: string, previousUrl: string) {
  void nativeEngineCommand(tabId, "follow", { engine, url, previousUrl });
}

const visits = visitRecorder(
  (profile, visit) => {
    if (nativeSafeMode()) return;
    void nativeAddHistoryVisits(profile, [{ url: visit.url, title: visit.title, visitTimes: [visit.at] }]).catch(() => {});
  },
  { set: (run, ms) => setTimeout(run, ms), clear: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>) },
  Date.now,
);

const visitedTabs = new Set<string>();
let unwatch: (() => void) | null = null;

function watchClosedTabs() {
  unwatch ??= useBrowser.subscribe((s, prev) => {
    if (s.tabs === prev.tabs) return;
    for (const id of visitedTabs) {
      if (s.tabs[id]) continue;
      visitedTabs.delete(id);
      visits.close(id);
    }
  });
}

export function noteWebKitPage(tabId: string, page: WebKitPage) {
  const t = store().tabs[tabId];
  if (!t) return;
  watchClosedTabs();
  visitedTabs.add(tabId);
  visits.note(tabId, isIncognitoProfile(t.profileId) ? null : engineProfile(t.profileId), page);
}
