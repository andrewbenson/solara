import { showMenu, type MenuItem } from "@solara/shell";
import { useBrowser } from "../../store/browser";
import { isIncognitoProfile } from "../../store/model";
import { defaultTarget, isNeverTranslated, languageName, otherLanguages, revertPage, setNeverTranslate, translatePage, translateStateOf } from "./translate";

export async function chooseLanguage(tabId: string) {
  const languages = await otherLanguages();
  const current = translateStateOf(tabId).target;
  const items: MenuItem[] = languages.map((l) => ({ id: l.id, title: l.name, checked: l.id === current }));
  const choice = await showMenu(items);
  if (choice) void translatePage(tabId, choice);
}

export async function showTranslateMenu(tabId: string) {
  const tab = useBrowser.getState().tabs[tabId];
  if (!tab) return;
  const translated = translateStateOf(tabId).status !== "idle";
  const items: MenuItem[] = [
    translated ? { id: "original", title: "Show Original", symbol: "arrow.uturn.backward" } : { id: "translate", title: `Translate to ${languageName(defaultTarget())}`, symbol: "translate" },
    { id: "choose", title: "Choose Another Language…", symbol: "globe" },
  ];
  if (!isIncognitoProfile(tab.profileId)) {
    items.push({ separator: true }, { id: "never", title: "Never Translate This Site", checked: isNeverTranslated(tab.profileId, tab.url) });
  }
  const choice = await showMenu(items);
  if (choice === "original") void revertPage(tabId);
  else if (choice === "translate") void translatePage(tabId);
  else if (choice === "choose") void chooseLanguage(tabId);
  else if (choice === "never") setNeverTranslate(tabId, !isNeverTranslated(tab.profileId, tab.url));
}
