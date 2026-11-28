import { type LinkRoute, routeLinkTabs } from "@solara/solaracore";
import { focus, openWindow } from "./actions";
import { runsJavaScript } from "./scriptUrls";
import { useBrowser } from "../store/browser";
import { engineProfile } from "../store/model";
import { lastActiveProfile, mainWindowFor } from "../store/small";

export type RoutedLinks = { profileId: string | null; adoptIds: (string | undefined)[] };

export function routedLinks(route: LinkRoute, count: number): RoutedLinks {
  const s = useBrowser.getState();
  const marks = route.adoptIds ?? [];
  const last = lastActiveProfile(s);
  const profileId =
    route.profile === undefined ? null : engineProfile(last) === route.profile ? last : (s.profileOrder.find((id) => engineProfile(id) === route.profile) ?? null);
  return {
    profileId,
    adoptIds: Array.from({ length: count }, (_, i) => (profileId !== null && typeof marks[i] === "string" ? marks[i]! : undefined)),
  };
}

const store = () => useBrowser.getState();

export function openExternalUrls(given: string[], profile?: string) {
  const settings = store().settings;
  const urls = settings.allowJavaScriptFromAppleEvents ? given : given.filter((url) => !runsJavaScript(url, settings));
  if (!urls.length) return;
  if (profile !== undefined) return openUrlsFromApps(urls, routedLinks({ profile }, urls.length));
  void routeLinkTabs(urls).then(
    (route) => openRoutedUrls(urls, route),
    () => openUrlsFromApps(urls, routedLinks({}, urls.length)),
  );
}

function openRoutedUrls(urls: string[], route: LinkRoute) {
  const dismissed = new Set(route.dismissed ?? []);
  const kept = urls.map((_, i) => i).filter((i) => !dismissed.has(i));
  if (!kept.length) return;
  const marks = route.adoptIds ?? [];
  openUrlsFromApps(
    kept.map((i) => urls[i]!),
    routedLinks({ ...route, adoptIds: kept.map((i) => marks[i] ?? null) }, kept.length),
  );
}

function openUrlsFromApps(urls: string[], routed: RoutedLinks) {
  const profileId = routed.profileId ?? lastActiveProfile(store());
  openLinksInMainWindow(urls, profileId, routed.adoptIds);
}

function openLinksInMainWindow(urls: string[], profileId: string, adoptIds: (string | undefined)[]) {
  let target = mainWindowFor(store(), profileId);
  urls.forEach((url, i) => {
    const s = store();
    const adoptId = adoptIds[i];
    const w = target ? s.windows[target] : undefined;
    const blank = w && w.tabIds.length === 1 ? s.tabs[w.tabIds[0]!] : undefined;
    const intoBlank = blank && !blank.url && !blank.navigation && blank.profileId === profileId && !s.windowUi[w!.id]?.panel.open;
    if (!w) target = openWindow({ url, profileId, adoptId });
    else if (intoBlank && !adoptId) s.navigate(blank.id, url);
    else {
      s.newTab(w.id, { url, profileId, adoptId });
      if (intoBlank) store().closeTab(blank.id);
    }
  });
  if (target) focus(target);
}
