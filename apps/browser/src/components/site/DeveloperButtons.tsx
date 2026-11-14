import { showMenu } from "@solara/shell";
import { withLivePage } from "../../lib/livePage";
import { webviews } from "../../lib/webviews";
import { developerReloadFor, setDeveloperReload } from "./developerMode";

export function developerReload(tabId: string) {
  const force = developerReloadFor(tabId) === "forceReload";
  void withLivePage(tabId, (page) => (force ? page.forceReload() : page.reload()));
}

export async function showDeveloperReloadMenu(tabId: string) {
  const current = developerReloadFor(tabId);
  const choice = await showMenu([
    { id: "reload", title: "Refresh page", checked: current === "reload" },
    { id: "forceReload", title: "Refresh (Ignore Cache)", checked: current === "forceReload" },
    { id: "clearCookies", title: "Clear Cookies and Refresh" },
  ]);
  if (choice) await runDeveloperReloadChoice(tabId, choice);
}

export async function runDeveloperReloadChoice(tabId: string, choice: string) {
  if (choice === "reload" || choice === "forceReload") {
    setDeveloperReload(tabId, choice);
    return developerReload(tabId);
  }
  if (choice !== "clearCookies") return;
  await webviews.get(tabId)?.clearSiteData();
  void withLivePage(tabId, (page) => page.reload());
}
