import "../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
const { startProfileConfirmation } = await import('../test-native/profileConfirmation.mjs');
import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("./browser.ts");
await startProfileConfirmation();
const model = await import("./model.ts");
const { cleanedTabsFor } = await import("./organize.ts");
const stub = await import("../test-native/index.ts");

const S = () => useBrowser.getState();
const HOUR = 3_600_000;
const OLD = () => Date.now() - 13 * HOUR;

function privateWindowWith(...urls) {
  const w = S().createWindow({ incognito: true, url: urls[0] });
  const ids = [model.viewTabIds(S(), w)[0]];
  for (const url of urls.slice(1)) ids.push(S().newTab(w, { url }));
  return { w, ids };
}

test("incognito window: own profile, closing records nothing, history ignored", () => {
  S().hydrate({});
  const w = S().createWindow({ incognito: true, url: "secret.com" });
  const tab = S().tabs[model.activeTabId(S(), w)];
  assert.equal(tab.profileId, `incognito:${w}@default`);
  stub.historyDbs.clear();
  assert.equal(S().importHistory(tab.profileId, [{ url: "https://secret.com/", title: "S", visits: 1, lastVisit: Date.now() }]), 0);
  S().removeHistory(tab.profileId, ["https://secret.com/"]);
  assert.equal(S().history[tab.profileId], undefined);
  assert.equal(stub.historyDbs.size, 0, "nothing reaches Chrome's history, not even the default profile's");
  const extra = S().newTab(w, { url: "x.com" });
  S().closeTab(extra);
  assert.equal(S().closedTabs.length, 1);
  S().closeWindow(w);
  assert.equal(S().closedTabs.length, 0);
  assert.equal(S().closedWindows.length, 0);
});

test("cleaning up a private window keeps its tabs in memory and in that window", () => {
  S().hydrate({});
  const normal = S().createWindow({ url: "https://public.example/" });
  const { w, ids: [current, stale, dupe] } = privateWindowWith("https://secret.example/a", "https://secret.example/old", "https://secret.example/a");
  S().activate(current);
  S().updateTab(stale, { lastActiveAt: OLD() });
  S().updateTab(dupe, { lastActiveAt: Date.now() - 2 * HOUR });
  assert.equal(S().cleanUpTabs(w), 2);
  assert.ok(!S().tabs[stale] && !S().tabs[dupe]);

  assert.equal(S().cleanedTabs.length, 0, "the saved list never sees private tabs");
  assert.equal(cleanedTabsFor(S(), w).length, 2);
  assert.equal(cleanedTabsFor(S(), normal).length, 0, "a regular window doesn't list them");

  S().restoreCleaned(undefined, normal);
  S().restoreCleaned(cleanedTabsFor(S(), w)[0].id, normal);
  assert.equal(model.viewTabIds(S(), normal).length, 1);
  assert.equal(cleanedTabsFor(S(), w).length, 1, "an entry id alone still restores into its own window");
  S().restoreCleaned(undefined, w);
  assert.equal(cleanedTabsFor(S(), w).length, 0);
  assert.equal(model.viewTabIds(S(), w).length, 3);
  assert.ok(model.viewTabIds(S(), w).every((id) => model.isIncognitoProfile(S().tabs[id].profileId)));

  const restored = model.viewTabIds(S(), w).find((id) => S().tabs[id].url === "https://secret.example/old");
  S().activate(current);
  S().updateTab(restored, { lastActiveAt: OLD() });
  S().cleanUpTabs(w);
  assert.equal(cleanedTabsFor(S(), w).length, 1);
  S().closeWindow(w);
  assert.deepEqual(S().privateCleanedTabs, {}, "closing the window forgets them");
});

test("cleaned tabs leave Recently Cleaned a week after their clean-up", () => {
  const DAY = 24 * HOUR;
  const entry = (id, url, closedAt) => ({
    kind: "tab", id, windowId: "w-gone", index: 0, group: null, closedAt,
    tab: { url, title: id, favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, profileId: "default" },
  });
  const stale = entry("ct-stale", "https://stale.example/", Date.now() - 8 * DAY);
  const recent = entry("ct-recent", "https://recent.example/", Date.now() - HOUR);
  S().hydrate({ cleanedTabs: [recent] });
  const w = S().createWindow({ url: "https://public.example/" });
  assert.deepEqual(cleanedTabsFor(S(), w).map((c) => c.id), ["ct-recent"]);

  useBrowser.setState({ cleanedTabs: [stale, recent] });
  assert.deepEqual(cleanedTabsFor(S(), w).map((c) => c.id), ["ct-recent"], "the list and its count read only the last 7 days");
  S().restoreCleaned(undefined, w);
  const urls = model.viewTabIds(S(), w).map((id) => S().tabs[id].url);
  assert.ok(urls.some((url) => url === "https://recent.example/"));
  assert.ok(!urls.some((url) => url === "https://stale.example/"), "Restore All brings back only the recent one");

  useBrowser.setState({ cleanedTabs: [stale] });
  const old = S().newTab(w, { url: "https://idle.example/" });
  S().activate(model.viewTabIds(S(), w).find((id) => id !== old));
  S().updateTab(old, { lastActiveAt: OLD() });
  S().cleanUpTabs(w);
  assert.ok(!S().cleanedTabs.some((c) => c.id === "ct-stale"), "the next clean-up drops the expired entry");
  assert.ok(S().cleanedTabs.some((c) => c.tab.url === "https://idle.example/"));
});

test("favicons: incognito icons stay in memory and in their own profile", async () => {
  const { noteFavicon, resolveFavicon, useFavicons, startFavicons } = await import("../lib/favicons.ts");
  const { webviews } = await import("../lib/webviews.ts");
  const stop = startFavicons();
  const normal = S().createWindow({ url: "https://site.example/a" });
  const incognito = S().createWindow({ incognito: true, url: "https://secret.example/x" });
  const [normalTab] = S().windows[normal].tabIds;
  const [privateTab] = S().windows[incognito].tabIds;
  const privateProfile = S().windows[incognito].profileId;
  const handle = (uri) => ({ downloadFavicon: () => Promise.resolve({ uri, width: 32, height: 32 }) });
  webviews.set(normalTab, handle("data:image/png;base64,SITE"));
  webviews.set(privateTab, handle("data:image/png;base64,AAAA"));

  noteFavicon(normalTab, "https://site.example/favicon.ico");
  noteFavicon(privateTab, "https://secret.example/favicon.ico");
  await new Promise((r) => setTimeout(r, 50));

  assert.equal(resolveFavicon("https://site.example/a")?.uri, "data:image/png;base64,SITE");
  assert.equal(resolveFavicon("https://secret.example/x"), null);
  assert.equal(resolveFavicon("https://secret.example/x", null, "default"), null);
  assert.equal(resolveFavicon("https://secret.example/x", null, privateProfile)?.uri, "data:image/png;base64,AAAA");
  assert.equal(resolveFavicon("https://site.example/a", null, privateProfile)?.uri, "data:image/png;base64,SITE");

  S().closeWindow(incognito);
  assert.equal(useFavicons.getState().profiles[privateProfile], undefined);
  webviews.clear();
  stop();
});

test("clearing a time range removes visits, not pages", () => {
  S().hydrate({});
  const t0 = 1_700_000_000_000;
  const entry = (url, times) => ({ url, title: url, favicon: null, visits: times.length, lastVisit: times.at(-1), visitTimes: times });
  S().hydrate({ history: { default: [entry("https://b.com/", [t0 - 5 * 60_000]), entry("https://a.com/", [t0 - 5 * HOUR, t0 - 10 * 60_000])] } });
  assert.deepEqual(S().history.default.map((h) => [h.url, h.visits]), [["https://b.com/", 1], ["https://a.com/", 2]]);

  S().clearHistory("default", t0 - HOUR);
  const [a, ...rest] = S().history.default;
  assert.equal(rest.length, 0, "b.com was only visited in the last hour");
  assert.equal(a.url, "https://a.com/");
  assert.equal(a.visits, 1);
  assert.equal(a.lastVisit, t0 - 5 * HOUR);
  assert.deepEqual(a.visitTimes, [t0 - 5 * HOUR]);

  S().clearHistory("default");
  assert.deepEqual(S().history.default, []);
});

test("deleting the original profile queues Chrome's default profile for deletion", () => {
  S().hydrate({});
  const work = S().createProfile({ name: "Work" });
  S().deleteProfile("default");
  assert.deepEqual(S().orphanedProfileData, [""]);
  S().deleteProfile(work);
  assert.deepEqual(S().orphanedProfileData, [""], "the last profile can't be deleted");
});

test("a profile sharing another's data leaves nothing to delete until the last one goes", () => {
  S().hydrate({});
  const shared = S().createProfile({ name: "Shared", shareWith: "default" });
  const other = S().createProfile({ name: "Other" });
  S().deleteProfile("default");
  assert.deepEqual(S().orphanedProfileData, []);
  S().deleteProfile(shared);
  assert.deepEqual(S().orphanedProfileData, [""]);
  S().createProfile({ name: "New" });
  S().deleteProfile(other);
  assert.deepEqual(S().orphanedProfileData, ["", other]);
});

test("imported history of any age is shown and written, untitled rows included", () => {
  S().hydrate({});
  stub.historyDbs.clear();
  const DAY = 24 * HOUR;
  const now = Date.now();
  const added = S().importHistory("default", [
    { url: "https://recent.example/", title: "Recent", visits: 3, lastVisit: now - 89 * DAY },
    { url: "https://old.example/", title: "Old", visits: 9, lastVisit: now - 400 * DAY },
    { url: "https://untitled.example/", title: "", visits: 1, lastVisit: now - HOUR },
  ]);
  assert.equal(added, 3);
  const kept = ["https://old.example/", "https://recent.example/", "https://untitled.example/"];
  assert.deepEqual(S().history.default.map((h) => h.url).sort(), kept);
  assert.deepEqual([...stub.chromeHistory("").keys()].sort(), kept);
});

test("deleting a profile keeps the data others share", () => {
  S().hydrate({});
  const a = S().createProfile({ name: "A" });
  S().importHistory(a, [{ url: "https://a.com/", title: "A", visits: 1, lastVisit: Date.now() - 2 * HOUR }]);
  const bookmark = S().addBookmark({ profileId: a, url: "https://b.com/", title: "B" });
  const b = S().createProfile({ name: "B", shareWith: a });
  S().deleteProfile(a);
  assert.equal(S().profiles[a], undefined);
  assert.equal(model.engineProfile(b), a, "still on A's engine context");
  assert.ok(S().bookmarks.nodes[bookmark], "shared bookmarks stay");
  assert.deepEqual(S().history[b].map((h) => h.url), ["https://a.com/"]);
  S().importHistory(b, [{ url: "https://c.com/", title: "C", visits: 1, lastVisit: Date.now() - HOUR }]);
  assert.equal(S().history[b].length, 2);
  S().deleteProfile(b);
  assert.equal(S().bookmarks.nodes[bookmark], undefined);
});

test("adopting imported history keeps rows of any age", () => {
  S().hydrate({});
  const old = Date.now() - 400 * 86_400_000;
  assert.equal(S().adoptImportedHistory("default", [{ url: "https://old.test/", title: "Old", visits: 1, lastVisit: old }]), 1);
  assert.deepEqual(S().history.default.map((h) => h.url), ["https://old.test/"]);
});

test("adopting imported history counts new URLs once, keeps http(s) and file rows, and writes nothing to the engine", async () => {
  S().hydrate({});
  stub.historyDbs.clear();
  S().importHistory("default", [{ url: "https://seen.test/", title: "Seen", visits: 1, lastVisit: Date.now() - 1 }]);
  await new Promise((resolve) => setTimeout(resolve, 40));
  const engineRows = () => [...(stub.historyDbs.get(null)?.values() ?? [])].reduce((n, db) => n + db.size, 0);
  const before = engineRows();
  const added = S().adoptImportedHistory("default", [
    { url: "https://seen.test/", title: "Seen", visits: 1, lastVisit: Date.now() - 5 },
    { url: "https://new.test/", title: "New", visits: 0, lastVisit: Date.now() - 4 },
    { url: "https://new.test/", title: "New again", visits: 2, lastVisit: Date.now() - 3 },
    { url: "HTTPS://upper.test/", title: "Upper", visits: 1, lastVisit: Date.now() - 2 },
    { url: "ftp://files.test/", title: "Ftp", visits: 1, lastVisit: Date.now() - 2 },
    { url: "file:///tmp/page.html", title: "File", visits: 1, lastVisit: Date.now() - 1 },
  ]);
  assert.equal(added, 2);
  assert.deepEqual(S().history.default.map((h) => h.url).sort(), ["file:///tmp/page.html", "https://new.test/", "https://seen.test/"]);
  assert.equal(S().history.default.find((h) => h.url === "https://new.test/").visits, 1);
  await new Promise((resolve) => setTimeout(resolve, 40));
  assert.equal(engineRows(), before);
  assert.equal(S().adoptImportedHistory("incognito:w@default", [{ url: "https://x.test/", title: "X", visits: 1, lastVisit: Date.now() - 1 }]), 0);
});
