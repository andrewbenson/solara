import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("./browser.ts");
const { viewTabIds } = await import("./model.ts");
await import("../test-native/index.ts");

const S = () => useBrowser.getState();

function windowWith(...hosts) {
  S().hydrate({});
  const w = S().createWindow({ url: `https://${hosts[0]}.com/` });
  const ids = [S().windows[w].tabIds[0]];
  for (const h of hosts.slice(1)) ids.push(S().newTab(w, { url: `https://${h}.com/` }));
  return { w, ids };
}

const regular = (w) => viewTabIds(S(), w).filter((id) => !S().tabs[id].pinned && !Object.values(S().groups).some((g) => g.pinned && g.tabIds.includes(id)));

function closeLastTabTwice(w) {
  S().closeTab(regular(w)[0]);
  assert.ok(S().windows[w], "closing the last tab leaves the window");
  const [blank] = regular(w);
  assert.equal(S().tabs[blank].url, "");
  S().closeTab(blank);
}

test("closing the New Tab left by the last tab keeps a window that has a sleeping pinned tile", () => {
  const { w, ids: [pin, last] } = windowWith("pin", "last");
  S().pinTabs([pin], true);
  S().closeTab(pin);
  assert.equal(S().tabs[pin].unloaded, true);
  closeLastTabTwice(w);
  assert.ok(S().windows[w]);
  assert.equal(S().tabs[pin].unloaded, true);
  assert.equal(S().tabs[last], undefined);
  assert.equal(regular(w).length, 1);
  assert.equal(S().tabs[regular(w)[0]].url, "");
});

test("closing the New Tab left by the last tab keeps a window that has a sleeping pinned group", () => {
  const { w, ids: [member] } = windowWith("member", "last");
  S().groupTabs([member], { pinned: true, name: "Pinned" });
  S().closeTab(member);
  assert.equal(S().tabs[member].unloaded, true);
  closeLastTabTwice(w);
  assert.ok(S().windows[w]);
  assert.equal(S().tabs[member].unloaded, true);
});

test("without pins, closing the New Tab left by the last tab still closes the window", () => {
  const { w } = windowWith("last");
  closeLastTabTwice(w);
  assert.equal(S().windows[w], undefined);
});
