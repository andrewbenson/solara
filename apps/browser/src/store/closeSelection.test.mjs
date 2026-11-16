import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("./browser.ts");
const { multiSelection } = await import("./organize.ts");
const { viewTabIds } = await import("./model.ts");
const { closeTogether, reopenClosedTogether } = await import("./closedTogether.ts");
await import("../test-native/index.ts");

const S = () => useBrowser.getState();

function windowWith(...hosts) {
  S().hydrate({});
  const w = S().createWindow({ url: `https://${hosts[0]}.com/` });
  const ids = [S().windows[w].tabIds[0]];
  for (const h of hosts.slice(1)) ids.push(S().newTab(w, { index: S().windows[w].tabIds.length, url: `https://${h}.com/` }));
  return { w, ids };
}
const urls = (w) => viewTabIds(S(), w).map((id) => S().tabs[id].url.slice(8, 9));

test("a selection of two or more is what ⌘W closes, in sidebar order", () => {
  const { w, ids: [a, b, , d] } = windowWith("a", "b", "c", "d");
  assert.deepEqual(multiSelection(S(), w), []);
  S().setSelection(w, [b]);
  assert.deepEqual(multiSelection(S(), w), []);
  S().setSelection(w, [d, b, a]);
  assert.deepEqual(multiSelection(S(), w), [a, b, d]);
});

test("closing a selection closes it in one go, and one reopen brings it all back in place", () => {
  const { w, ids: [, b, c, , e] } = windowWith("a", "b", "c", "d", "e");
  S().setSelection(w, [b, c, e]);
  closeTogether(multiSelection(S(), w));
  assert.deepEqual(urls(w), ["a", "d"]);
  assert.equal(reopenClosedTogether(w), true);
  assert.deepEqual(urls(w), ["a", "b", "c", "d", "e"]);
  assert.equal(S().closedTabs.length, 0);
  assert.equal(reopenClosedTogether(w), false);
});

test("a later close takes over from the selection, so reopen goes back to one at a time", () => {
  const { w, ids: [a, b, c] } = windowWith("a", "b", "c", "d");
  closeTogether([b, c]);
  S().closeTab(a);
  assert.equal(reopenClosedTogether(w), false);
  S().reopenClosed(w);
  assert.deepEqual(urls(w), ["a", "d"]);
});
