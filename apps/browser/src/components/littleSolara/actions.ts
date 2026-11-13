import { type LinkRoute, routeLinkTabs } from "@solara/solaracore";
import { showMenu } from "@solara/shell";
import { focus, openWindow } from "../../lib/actions";
import { menuShortcut } from "../../lib/commandShortcuts";
import { closeWindowAnimated, isWindowClosing } from "../../lib/closeAnimated";
import { routedLinks, type RoutedLinks } from "../../lib/linkRoutes";
import { runsJavaScript } from "../../lib/scriptUrls";
import { profileAccent } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { activeTabId } from "../../store/model";
import { isSmall, lastActiveProfile, mainWindowFor } from "../../store/small";
import { nativeOwnsWorkspace, nativeWrite } from "../../store/nativeStore";

const store = () => useBrowser.getState();

export function openLittleSolara(url?: string, profileId?: string, adoptId?: string, linkPointer?: [number, number]): string {
  const id = store().createWindow({ small: true, url, profileId, adoptId, linkPointer });
  if (!url) store().openPanel(id, "");
  return id;
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

export function openInMainWindow(windowId: string) {
  const s = store();
  if (!isSmall(s, windowId)) return;
  const tabId = activeTabId(s, windowId);
  const tab = tabId ? s.tabs[tabId] : undefined;
  const target = mainWindowFor(s, tab?.profileId ?? s.windows[windowId]!.profileId);
  if (!tab?.url) {
    s.closeWindow(windowId);
    if (target) focus(target);
    else openWindow({ profileId: tab?.profileId });
    return;
  }
  const moved = s.moveTabsToWindow([tab.id], target ?? null);
  if (moved) focus(moved);
}

export function moveLittleSolaraToProfile(windowId: string, profileId: string) {
  const s = store();
  const w = s.windows[windowId];
  if (!w || !isSmall(s, windowId) || isWindowClosing(windowId) || !s.profiles[profileId] || w.profileId === profileId) return;
  const tabId = activeTabId(s, windowId);
  const url = (tabId ? s.tabs[tabId]?.url : undefined) || undefined;
  const id = store().createWindow({ small: true, url, profileId, frame: w.frame });
  if (!url) store().openPanel(id, "");
  closeWindowAnimated(windowId, id, () => {
    if (tabId && nativeOwnsWorkspace()) nativeWrite({ name: "forgetClosedTab", args: [tabId] });
    else if (tabId) useBrowser.setState((now) => ({ closedTabs: now.closedTabs.filter((c) => c.tabId !== tabId) }));
  });
}

export function cycleLittleSolaraProfile(windowId: string, delta: 1 | -1) {
  const s = store();
  const w = s.windows[windowId];
  if (!w || s.profileOrder.length < 2) return;
  const i = s.profileOrder.indexOf(w.profileId);
  moveLittleSolaraToProfile(windowId, s.profileOrder[(i + delta + s.profileOrder.length) % s.profileOrder.length]!);
}

export async function openLittleSolaraProfileMenu(windowId: string) {
  const s = store();
  const current = s.windows[windowId]?.profileId;
  const choice = await showMenu(
    s.profileOrder.map((id) => ({
      id,
      title: s.profiles[id]!.name,
      checked: id === current,
      swatch: profileAccent(s.profiles[id]),
      ...menuShortcut(`switchProfile:${id}`, s),
    })),
  );
  if (choice) moveLittleSolaraToProfile(windowId, choice);
}

export function closeLittleSolara(windowId: string) {
  if (isSmall(store(), windowId)) closeWindowAnimated(windowId, null);
}

export function closeLittleSolaraOnEscape(tabId: string) {
  const s = store();
  const tab = s.tabs[tabId];
  if (!tab || !isSmall(s, tab.windowId) || s.find[tabId]?.open || s.windowUi[tab.windowId]?.panel.open) return;
  closeLittleSolara(tab.windowId);
}
