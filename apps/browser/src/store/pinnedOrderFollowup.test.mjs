import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("./browser.ts");
const { sidebarEntries } = await import("../components/sidebar/entries.ts");

const S = () => useBrowser.getState();
const host = (id) => new URL(S().tabs[id].url).hostname.replace(".example", "");

function start(...names) {
  S().hydrate({});
  const w = S().createWindow({ url: "https://home.example/" });
  const ids = Object.fromEntries(names.map((n) => [n, S().newTab(w, { index: S().windows[w].tabIds.length, url: `https://${n}.example/`, background: true })]));
  return { w, ids };
}

const sequence = (w) =>
  sidebarEntries(S(), w).pinned.map((e) => {
    const id = e.slice(e.indexOf(":") + 1);
    if (e.startsWith("g:")) return S().groups[id].name;
    return host(id);
  });

test("a pinned group closed and reopened from Recently Closed comes back where it was among the rows", () => {
  const { w, ids } = start("r1", "m", "r2");
  S().placeTabs([ids.r1], { pinned: true, row: true, beforeId: null });
  const g = S().groupTabs([ids.m], { pinned: true, name: "Group" });
  S().placeTabs([ids.r2], { pinned: true, row: true, beforeId: null, last: true });
  assert.deepEqual(sequence(w), ["r1", "Group", "r2"]);
  S().closeGroup(g);
  S().restoreClosed(S().closedGroups.at(-1).id, w);
  assert.deepEqual(sequence(w), ["r1", "Group", "r2"]);
});

test("collapsing a group in a long pinned list costs the order listener nothing", async () => {
  const { noteOrderChoices } = await import("./pinOrderChoices.ts");
  const { w } = start();
  const ids = [];
  for (let i = 0; i < 3000; i++) ids.push(S().newTab(w, { url: `https://r${i}.example/`, background: true }));
  S().placeTabs(ids, { pinned: true, row: true, beforeId: null });
  const member = S().newTab(w, { url: "https://member.example/", background: true });
  const g = S().groupTabs([member], { pinned: true, name: "Group" });
  const prev = S();
  S().updateGroup(g, { collapsed: true });
  const now = S();
  const t0 = performance.now();
  for (let i = 0; i < 20; i++) noteOrderChoices(now, prev);
  const ms = (performance.now() - t0) / 20;
  assert.ok(ms < 1, `${ms.toFixed(2)} ms`);
});
