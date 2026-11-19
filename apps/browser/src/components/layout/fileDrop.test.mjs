import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("../../store/browser.ts");
const { openDroppedItems } = await import("./fileDrop.tsx");
await import("../../test-native/index.ts");

const S = () => useBrowser.getState();
const urls = ["https://x.com/", "https://y.com/", "https://z.com/"];
const items = urls.map((url) => ({ kind: "url", url }));
const order = (w, ids) => S().windows[w].tabIds.filter((id) => ids.includes(id)).map((id) => S().tabs[id].url);
const contiguous = (w, ids) => {
  const at = ids.map((id) => S().windows[w].tabIds.indexOf(id)).sort((a, b) => a - b);
  return at.every((index, i) => i === 0 || index === at[i - 1] + 1);
};

function windowWith(count, activeIndex) {
  S().hydrate({});
  const w = S().createWindow({ url: "https://t0.com/" });
  for (let i = 1; i < count; i++) S().newTab(w, { index: S().windows[w].tabIds.length, url: `https://t${i}.com/` });
  S().activate(S().windows[w].tabIds[activeIndex]);
  return w;
}

for (const [label, count, active] of [["one tab", 1, 0], ["first of several", 4, 0], ["middle of several", 4, 2], ["last of several", 4, 3]]) {
  test(`a multi-link drop opens its tabs together in drop order (${label})`, () => {
    const w = windowWith(count, active);
    const ids = openDroppedItems(w, items, null);
    assert.equal(ids.length, 3);
    assert.deepEqual(order(w, ids), urls);
    assert.ok(contiguous(w, ids));
    assert.equal(S().windows[w].activeTabIds[S().windows[w].profileId], ids[0]);
  });
}

test("a multi-link drop into a pinned-tab window keeps drop order", () => {
  const w = windowWith(3, 1);
  S().pinTabs([S().windows[w].tabIds[0]], true);
  const ids = openDroppedItems(w, items, null);
  assert.deepEqual(order(w, ids), urls);
  assert.ok(contiguous(w, ids));
});
