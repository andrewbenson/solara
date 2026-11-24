import { test } from "node:test";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

globalThis.__DEV__ = false;

const here = dirname(fileURLToPath(import.meta.url));
const src = join(here, "../../src");
const { useBrowser } = await import(join(src, "store/browser.ts"));
const { docs } = await import(join(src, "test-native/shell.ts"));
const S = () => useBrowser.getState();

const runs = Number(process.env.FUZZ_RUNS ?? "24");
const steps = Number(process.env.FUZZ_STEPS ?? "60");
const firstSeed = Number(process.env.FUZZ_FROM ?? "1");
const fixtures = JSON.parse(readFileSync(join(here, "session-fixtures.json"), "utf8"));
const starts = process.env.FUZZ_START ? [process.env.FUZZ_START] : ["perf-seed", "nested-groups-folders-rows", "broken-splits", "absent-and-unknown-fields", null];

function prng(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function start(name) {
  docs.clear();
  if (!name) return S().hydrate({});
  const fixture = fixtures.find((entry) => name.startsWith("/") ? entry.inputs["session.json"] === readFileSync(name, "utf8") : entry.name === name);
  if (!fixture?.expected) throw new Error(`no fixed session expectation for ${name}`);
  const data = structuredClone(fixture.expected.session);
  for (const key of ["windows", "tabs", "groups", "splits"]) data[key] = Object.fromEntries((data[key] ?? []).map((row) => [row.id, row]));
  data.downloads = structuredClone(fixture.expected.downloads.downloads);
  S().hydrate(data);
}

function scenario(seed) {
  const rand = prng(seed);
  const pick = (list) => (list.length ? list[Math.floor(rand() * list.length)] : undefined);
  const some = (list, most = 3) => {
    const n = 1 + Math.floor(rand() * Math.min(most, Math.max(list.length, 1)));
    return [...new Set(Array.from({ length: n }, () => pick(list)).filter(Boolean))];
  };
  const coin = (p = 0.5) => rand() < p;
  const url = () => pick(["https://a.example/", "https://b.example/x", "https://a.example/#h", "b.example", "search words", "solara://settings", "https://www.c.example/"]);

  start(starts[seed % starts.length]);
  for (let step = 0; step < steps; step++) {
    const s = S();
    const windows = Object.keys(s.windows);
    const tabs = Object.keys(s.tabs);
    const groups = Object.keys(s.groups);
    const splits = Object.keys(s.splits);
    const profiles = s.profileOrder;
    const w = pick(windows);
    const windowTabs = w ? s.windows[w].tabIds : [];
    const t = pick(windowTabs.length ? windowTabs : tabs);
    const g = pick(groups);
    const actions = [
      () => w && S().newTab(w, { url: coin() ? url() : undefined, background: coin(0.3), openerId: coin(0.3) ? t : undefined, newTabCommand: coin(0.3), pinned: coin(0.1) }),
      () => t && S().closeTab(t),
      () => w && S().closeTabs(some(windowTabs), { lastClosesWindow: coin() }),
      () => t && S().activate(t),
      () => t && S().navigate(t, url(), { userInitiated: coin(0.7) }),
      () => t && S().updateTab(t, { title: `T${step}`, ...(coin(0.3) ? { url: url() } : {}), ...(coin(0.2) ? { favicon: null } : {}) }),
      () => t && S().pinTabs(some(windowTabs), coin(0.6), coin(0.5)),
      () => t && S().togglePin(t),
      () => w && S().createGroup(some(windowTabs), { name: coin() ? "G" : undefined }),
      () => w && S().groupTabs(some(windowTabs), { pinned: coin(0.4) }),
      () => g && S().addTabsToGroup(g, some(windowTabs)),
      () => w && S().removeTabsFromGroup(some(windowTabs, 2)),
      () => g && S().ungroup(g),
      () => g && S().updateGroup(g, coin() ? { collapsed: coin() } : coin() ? { pinned: coin() } : { name: "N", color: "red" }),
      () => g && S().moveGroup(g, { pinned: coin(), parentId: coin(0.3) ? pick(groups) : null, beforeId: coin() ? pick(windowTabs) : null }),
      () => w && S().createSplit(some(windowTabs, 3), coin() ? "vertical" : "horizontal"),
      () => w && S().openSplitPane(w, { url: coin() ? url() : undefined, side: pick(["left", "right", "top", "bottom"]), tabId: coin(0.3) ? t : undefined }),
      () => t && S().removeTabFromSplit(t),
      () => splits.length && S().separateSplit(pick(splits)),
      () => S().createWindow({ url: coin() ? url() : undefined, incognito: coin(0.15), profileId: coin(0.3) ? pick(profiles) : undefined, tabIds: coin(0.2) ? some(tabs, 2) : undefined, small: coin(0.1) }),
      () => w && windows.length > 1 && S().closeWindow(w),
      () => t && S().moveTabsToWindow(some(windowTabs, 2), coin(0.3) ? null : pick(windows)),
      () => t && profiles.length > 1 && S().moveTabToProfile(t, pick(profiles)),
      () => w && S().switchProfile(w, pick(profiles)),
      () => profiles.length < 4 && S().createProfile({ name: "P", shareWith: coin(0.3) ? pick(profiles) : undefined }),
      () => profiles.length > 1 && coin(0.3) && S().deleteProfile(pick(profiles)),
      () => S().reopenClosed(w),
      () => s.closedTabs.length && S().restoreClosed(pick(s.closedTabs).id, w),
      () => t && S().duplicateTab(t),
      () => g && S().duplicateGroup(g),
      () => g && S().newTabInGroup(g),
      () => g && S().newNestedGroup(g),
      () => t && S().placeTabs(some(windowTabs, 2), { pinned: coin(0.4), row: coin(), beforeId: coin() ? pick(windowTabs) : null, groupId: coin(0.3) ? pick(groups) : null, last: coin(0.2) }),
      () => t && S().dropTabs([t], { type: "onto", targetId: pick(windowTabs) }),
      () => t && S().moveTab(t, Math.floor(rand() * 6)),
      () => t && S().moveTabBy(t, coin() ? 1 : -1),
      () => t && S().setMuted(some(windowTabs), coin()),
      () => t && S().setSiteMuted(t, coin()),
      () => t && S().openPeek(t, url(), null),
      () => w && S().peekToTab(w, { activate: coin() }),
      () => w && S().closePeek(w),
      () => w && S().cleanUpTabs(w, { inactiveForMs: coin() ? 0 : 10 ** 10 }),
      () => w && S().clearUnpinnedTabs(w),
      () => S().updateSettings(coin() ? { shareTabsAcrossWindows: coin() } : { newTabPosition: pick(["top", "bottom", "nextToCurrent"]) }),
      () => w && S().setFocusedWindow(w),
      () => w && S().mergeAllWindows(w),
      () => w && S().toggleSidebar(w),
      () => w && S().setWindowFrame(w, [rand() * 100, rand() * 100, 800 + rand() * 400, 600]),
      () => t && S().returnToPinnedUrl(t),
      () => t && S().setPinnedUrl(t, coin() ? url() : undefined),
      () => w && S().toggleTabLayout(w),
      () => S().closeAbandonedNewTabs(),
    ];
    try {
      pick(actions)();
    } catch {}
  }
}

for (let run = 0; run < runs; run++) {
  test(`fuzz seed ${run + firstSeed - 1}`, () => scenario(run + firstSeed));
}
