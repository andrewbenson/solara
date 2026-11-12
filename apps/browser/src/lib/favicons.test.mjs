import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { test } from "node:test";
import { mount } from "../test-hooks.mjs";

globalThis.__DEV__ = false;

const native = import.meta.resolve("@solara/solaracore");
const stub = `export * from ${JSON.stringify(native)};
export const faviconsFor = (profile, pages) => globalThis.faviconsForTest(profile, pages);
`;
registerHooks({
  resolve(specifier, context, next) {
    if (specifier === "@solara/solaracore" && context.parentURL?.endsWith("/lib/favicons.ts"))
      return { url: `data:text/javascript,${encodeURIComponent(stub)}`, shortCircuit: true };
    if (specifier === "@solara/settings" && context.parentURL?.endsWith("/lib/favicons.ts"))
      return { url: `data:text/javascript,${encodeURIComponent(`export const nativeStoreFavicon = (...args) => (globalThis.storedFavicons.push(args), Promise.resolve());`)}`, shortCircuit: true };
    return next(specifier, context);
  },
});
const { adoptFavicons, adoptIconPage, dropOutlivedFavicon, faviconOutlived, noteIconPage, resolveFavicon, useFavicon } = await import("./favicons.ts");
const { useBrowser } = await import("../store/browser.ts");
const { engineProfile } = await import("../store/model.ts");
const { refreshLoadedProfiles, startProfileLoading } = await import("./lazyProfiles.ts");
const { startFavicons } = await import("./favicons.ts");
const { loadedEngineProfiles, loadEngineProfile, profileLoadRequests } = await import("../test-native/solaracore.ts");
await refreshLoadedProfiles();

const waitFor = async (check) => {
  for (let i = 0; i < 200 && !check(); i++) await new Promise((resolve) => setTimeout(resolve, 5));
  assert.ok(check(), "reached before the deadline");
};

test("an empty lookup that started before an import doesn't wipe the imported icon", async () => {
  useBrowser.getState().hydrate({});
  const page = "https://imported.test/";
  const lookups = [];
  globalThis.storedFavicons = [];
  globalThis.faviconsForTest = (profile, pages) => new Promise((resolve) => lookups.push({ pages, answer: () => resolve({ pages: new Map(), icons: new Map() }) }));
  const row = mount(() => useFavicon(page, null, "default"));
  try {
    await waitFor(() => lookups.some((l) => l.pages.some((p) => p === page)));
    adoptFavicons("default", [{ page, icon: `${page}favicon.png`, png: "AAAA" }]);
    assert.equal(resolveFavicon(page, null, "default")?.uri, "data:image/png;base64,AAAA");
    for (const l of lookups) l.answer();
    await new Promise((resolve) => setTimeout(resolve, 40));
    assert.equal(resolveFavicon(page, null, "default")?.uri, "data:image/png;base64,AAAA");
    await waitFor(() => globalThis.storedFavicons.length === 1);
    assert.deepEqual(globalThis.storedFavicons[0], [engineProfile("default"), page, `${page}favicon.png`, "AAAA"]);
  } finally {
    row.unmount();
    delete globalThis.faviconsForTest;
  }
});

test("a tab's icon outlives its page only once the tab has left the icon's site", () => {
  const netflix = "https://www.netflix.com/browse";
  assert.equal(faviconOutlived(netflix, "http://localhost:4321/"), true);
  assert.equal(faviconOutlived(netflix, "file:///Users/me/page.html"), true);
  assert.equal(faviconOutlived(netflix, "about:blank"), true);
  assert.equal(faviconOutlived(netflix, "https://www.netflix.com/title/80057281"), false);
  assert.equal(faviconOutlived(netflix, "https://WWW.netflix.com/browse#row"), false);
  assert.equal(faviconOutlived("http://localhost:4321/", "http://localhost:5173/"), true);
  assert.equal(faviconOutlived(null, "http://localhost:4321/"), false);
  assert.equal(faviconOutlived(netflix, ""), false);
});

test("an icon remembers its page across an engine switch, so the new engine's view still drops it on another site", () => {
  const S = () => useBrowser.getState();
  S().hydrate({});
  const netflix = "https://www.netflix.com/browse";
  const local = "http://localhost:4321/";
  const windowId = S().createWindow({ url: netflix });
  const tabId = S().windows[windowId].tabIds[0];
  S().updateTab(tabId, { url: netflix });
  adoptIconPage(tabId);
  S().updateTab(tabId, { favicon: "https://assets.nflxext.com/favicon.ico" });
  noteIconPage(tabId);
  S().navigated(tabId, { url: local, title: "" }, { isLoading: true });
  dropOutlivedFavicon(tabId, local, true);
  assert.equal(S().tabs[tabId].favicon, "https://assets.nflxext.com/favicon.ico");
  adoptIconPage(tabId);
  S().navigated(tabId, { url: local, title: "Local" }, { isLoading: false });
  dropOutlivedFavicon(tabId, local, false);
  assert.equal(S().tabs[tabId].favicon, null);
});

test("an icon stays when the tab finishes loading another page on the icon's site", () => {
  const S = () => useBrowser.getState();
  S().hydrate({});
  const page = "https://www.netflix.com/browse";
  const windowId = S().createWindow({ url: page });
  const tabId = S().windows[windowId].tabIds[0];
  S().updateTab(tabId, { url: page, favicon: "https://assets.nflxext.com/favicon.ico" });
  noteIconPage(tabId);
  S().navigated(tabId, { url: "https://www.netflix.com/title/1", title: "" }, { isLoading: false });
  dropOutlivedFavicon(tabId, "https://www.netflix.com/title/1", false);
  assert.equal(S().tabs[tabId].favicon, "https://assets.nflxext.com/favicon.ico");
});


test("passive icons for an unopened profile query only after its load event", async () => {
  const S = () => useBrowser.getState();
  S().hydrate({});
  const id = S().createProfile({ name: "Cold", color: "blue" });
  const page = "https://cold.test/";
  const lookups = [];
  loadedEngineProfiles.delete(engineProfile(id));
  globalThis.faviconsForTest = (profile, pages) => {
    lookups.push({ profile, pages });
    return Promise.resolve({ pages: new Map(), icons: new Map() });
  };
  const stopProfiles = startProfileLoading();
  const stopFavicons = startFavicons();
  const row = mount(() => useFavicon(page, null, id));
  try {
    await new Promise((resolve) => setTimeout(resolve, 40));
    assert.equal(lookups.length, 0);
    loadEngineProfile(engineProfile(id));
    await waitFor(() => lookups.some((lookup) => lookup.profile === engineProfile(id)));
  } finally {
    row.unmount();
    stopFavicons();
    stopProfiles();
    delete globalThis.faviconsForTest;
  }
});


test("explicit favicon import loads its cold target before writing imported image data", async () => {
  useBrowser.getState().hydrate({});
  const id = useBrowser.getState().createProfile({ name: "Import target", color: "green" });
  const key = engineProfile(id);
  loadedEngineProfiles.delete(key);
  profileLoadRequests.length = 0;
  globalThis.storedFavicons = [];
  let pending;
  adoptFavicons(id, [{ page: "https://import-cold.test/", icon: "https://import-cold.test/icon.png", png: "AAAA" }], (write) => { pending = write; });
  await pending;
  assert.deepEqual(profileLoadRequests, [key]);
  assert.equal(loadedEngineProfiles.has(key), true);
  assert.deepEqual(globalThis.storedFavicons, [[key, "https://import-cold.test/", "https://import-cold.test/icon.png", "AAAA"]]);
});
