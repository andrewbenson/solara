import { nativeWorkspaceCommand } from "@solara/settings";
import { type LinkRoute, routeLinkTabs } from "@solara/solaracore";
import { focus, openWindow } from "../../lib/actions";
import { closeWindowAnimated } from "../../lib/closeAnimated";
import { routedLinks, type RoutedLinks } from "../../lib/linkRoutes";
import { runsJavaScript } from "../../lib/scriptUrls";
import { useBrowser } from "../../store/browser";
import { isSmall, lastActiveProfile, mainWindowFor } from "../../store/small";
import { nativeOwnsWorkspace } from "../../store/nativeStore";

const store = () => useBrowser.getState();

function openLittleSolara(url: string, profileId?: string, adoptId?: string, linkPointer?: [number, number]): string {
  return store().createWindow({ small: true, url, profileId, adoptId, linkPointer });
}

const opensInLittleSolara = (url: string) => /^(https?|file):/i.test(url);

export function openExternalUrls(given: string[], pointer?: [number, number], profile?: string) {
  const settings = store().settings;
  const urls = settings.allowJavaScriptFromAppleEvents ? given : given.filter((url) => !runsJavaScript(url, settings));
  if (!urls.length) return;
  if (profile !== undefined) return openUrlsFromApps(urls, routedLinks({ profile }, urls.length), pointer);
  void routeLinkTabs(urls).then(
    (route) => openRoutedUrls(urls, route, pointer),
    () => openUrlsFromApps(urls, routedLinks({}, urls.length), pointer),
  );
}

function openRoutedUrls(urls: string[], route: LinkRoute, pointer?: [number, number]) {
  const dismissed = new Set(route.dismissed ?? []);
  const kept = urls.map((_, i) => i).filter((i) => !dismissed.has(i));
  if (!kept.length) return;
  const marks = route.adoptIds ?? [];
  openUrlsFromApps(
    kept.map((i) => urls[i]!),
    routedLinks({ ...route, adoptIds: kept.map((i) => marks[i] ?? null) }, kept.length),
    pointer,
  );
}

function openUrlsFromApps(urls: string[], routed: RoutedLinks, pointer?: [number, number]) {
  const [url] = urls;
  const profileId = routed.profileId ?? lastActiveProfile(store());
  if (store().settings.openLinksInLittleSolara && urls.length === 1 && url && opensInLittleSolara(url)) return void openLittleSolara(url, profileId, routed.adoptIds[0], pointer);
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

export function closeLittleSolara(windowId: string) {
  if (!isSmall(store(), windowId)) return;
  if (nativeOwnsWorkspace() && nativeWorkspaceCommand("closeWindow", null, windowId)) return;
  closeWindowAnimated(windowId);
}

export function closeLittleSolaraOnEscape(tabId: string) {
  const s = store();
  const tab = s.tabs[tabId];
  if (!tab || !isSmall(s, tab.windowId) || s.find[tabId]?.open || s.windowUi[tab.windowId]?.panel.open) return;
  closeLittleSolara(tab.windowId);
}
