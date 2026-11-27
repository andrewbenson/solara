import { showMenu } from "@solara/shell";
import { withLivePage } from "../../lib/livePage";
import { webviews } from "../../lib/webviews";
import { developerReloadFor, setDeveloperReload } from "./developerMode";
import { useBrowser } from "../../store/browser";

function reloadTarget(tabId: string) {
  const tab = useBrowser.getState().tabs[tabId];
  const page = webviews.get(tabId);
  return () => {
    const current = useBrowser.getState().tabs[tabId];
    return page === webviews.get(tabId) && !!tab && current?.windowId === tab.windowId && current.profileId === tab.profileId &&
      current.url === tab.url && current.navigation?.seq === tab.navigation?.seq;
  };
}

export function developerReload(tabId: string) {
  const force = developerReloadFor(tabId) === "forceReload";
  void withLivePage(tabId, (page) => (force ? page.forceReload() : page.reload()));
}

export async function showDeveloperReloadMenu(tabId: string) {
  const current = developerReloadFor(tabId);
  const valid = reloadTarget(tabId);
  const choice = await showMenu([
    { id: "reload", title: "Refresh page", checked: current === "reload" },
    { id: "forceReload", title: "Refresh (Ignore Cache)", checked: current === "forceReload" },
    { id: "clearCookies", title: "Clear Cookies and Refresh" },
  ]);
  if (choice && valid()) await runDeveloperReloadChoice(tabId, choice);
}

export async function runDeveloperReloadChoice(tabId: string, choice: string) {
  if (choice === "reload" || choice === "forceReload") {
    setDeveloperReload(tabId, choice);
    return developerReload(tabId);
  }
  if (choice !== "clearCookies") return;
  const page = webviews.get(tabId);
  if (!page) return;
  const valid = reloadTarget(tabId);
  await page.clearSiteData();
  if (valid()) void page.reload();
}
