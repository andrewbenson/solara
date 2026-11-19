import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("./browser.ts");
const { numberedTabs } = await import("../components/sidebar/entries.ts");

const S = () => useBrowser.getState();
const host = (id) => new URL(S().tabs[id].url).hostname.replace(".com", "");

function windowWith(...names) {
  S().hydrate({});
  const w = S().createWindow({ url: `https://${names[0]}.com/` });
  const ids = [S().windows[w].tabIds[0]];
  for (const h of names.slice(1)) ids.push(S().newTab(w, { index: S().windows[w].tabIds.length, url: `https://${h}.com/`, background: true }));
  return { w, ids };
}

test("⌘1–9 count a collapsed group as one row, its shown or last used tab", () => {
  const { w, ids } = windowWith("first", "a", "b", "c", "last");
  const [first, a, b, c] = ids;
  const g = S().groupTabs([a, b, c], { name: "Folder" });
  assert.deepEqual(numberedTabs(S(), w).map(host), ["a", "b", "c", "first", "last"], "open: every row");
  S().activate(b);
  S().activate(first);
  S().updateGroup(g, { collapsed: true });
  assert.deepEqual(numberedTabs(S(), w).map(host), ["b", "first", "last"], "collapsed: one row, the tab last used in it");
  S().activate(c);
  assert.deepEqual(numberedTabs(S(), w).map(host), ["c", "first", "last"], "the shown tab when it's inside");
});

test("a collapsed group inside an open one is one row, and an open one inside a collapsed one is hidden with it", () => {
  const { w, ids } = windowWith("a", "b", "c", "d", "e");
  const [a, b, c, d] = ids;
  const outer = S().groupTabs([a, b, c, d], { name: "Outer" });
  const inner = S().groupTabs([b, c], { name: "Inner" });
  S().activate(a);
  S().updateGroup(inner, { collapsed: true });
  assert.equal(numberedTabs(S(), w).length, 4);
  assert.deepEqual(numberedTabs(S(), w).map(host).filter((h) => h === "b" || h === "c").length, 1);
  S().updateGroup(inner, { collapsed: false });
  S().updateGroup(outer, { collapsed: true });
  assert.deepEqual(numberedTabs(S(), w).map(host), ["a", "e"]);
});
