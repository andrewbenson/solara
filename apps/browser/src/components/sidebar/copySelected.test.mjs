import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("../../store/browser.ts");
const { copiedLinksMessage, copySelectedUrls } = await import("./actions.ts");
const { viewTabIds } = await import("../../store/model.ts");
const S = () => useBrowser.getState();

test("⇧⌘C with several tabs selected copies each one's link, one per line, in sidebar order", () => {
  S().hydrate({});
  const w = S().createWindow({ url: "https://a.com/" });
  const a = S().windows[w].tabIds[0];
  const b = S().newTab(w, { url: "https://b.com/x", background: true });
  const c = S().newTab(w, { url: "https://c.com/", background: true });
  const blank = S().newTab(w, { background: true });
  const inOrder = (...ids) => viewTabIds(S(), w).filter((id) => ids.includes(id)).map((id) => S().tabs[id].url).join("\n");
  S().setSelection(w, [c, blank, a]);
  assert.deepEqual(copySelectedUrls(w, false), { count: 2, text: inOrder(a, c) }, "the New Tab has no link");
  S().setSelection(w, [b, a]);
  assert.deepEqual(copySelectedUrls(w, false), { count: 2, text: inOrder(a, b) });
  S().moveTab(a, viewTabIds(S(), w).length - 1);
  assert.equal(copySelectedUrls(w, false)?.text, inOrder(a, b), "order follows the sidebar, not the selection");
  assert.equal(copySelectedUrls(w, true)?.text.split("\n").length, 2);
});

test("one selected tab, or none, leaves ⇧⌘C to the shown page", () => {
  S().hydrate({});
  const w = S().createWindow({ url: "https://a.com/" });
  const b = S().newTab(w, { url: "https://b.com/", background: true });
  assert.equal(copySelectedUrls(w, false), undefined);
  S().setSelection(w, [b]);
  assert.equal(copySelectedUrls(w, false), undefined);
});

test("a selection without the shown tab leaves ⇧⌘C to the shown page", () => {
  S().hydrate({});
  const w = S().createWindow({ url: "https://a.com/" });
  const b = S().newTab(w, { url: "https://b.com/", background: true });
  const c = S().newTab(w, { url: "https://c.com/", background: true });
  S().setSelection(w, [b, c]);
  assert.equal(copySelectedUrls(w, false), undefined);
});

test("with fewer than two linked tabs selected it copies the links it has, never the shown page instead", () => {
  S().hydrate({});
  const w = S().createWindow({ url: "https://a.com/" });
  const a = S().windows[w].tabIds[0];
  const blank = S().newTab(w, { background: true });
  const other = S().newTab(w, { background: true });
  S().setSelection(w, [a, blank]);
  assert.deepEqual(copySelectedUrls(w, false), { count: 1, text: "https://a.com/" });
  S().activate(blank);
  S().setSelection(w, [blank, other]);
  assert.deepEqual(copySelectedUrls(w, false), { count: 0, text: "" });
});

test("selected tabs inside a collapsed group are copied too, in sidebar order", () => {
  S().hydrate({});
  const w = S().createWindow({ url: "https://a.com/" });
  const a = S().windows[w].tabIds[0];
  const b = S().newTab(w, { url: "https://b.com/", background: true });
  const c = S().newTab(w, { url: "https://c.com/", background: true });
  const g = S().groupTabs([b, c]);
  S().updateGroup(g, { collapsed: true });
  S().setSelection(w, [c, a, b]);
  const order = viewTabIds(S(), w).filter((id) => [a, b, c].includes(id)).map((id) => S().tabs[id].url);
  assert.deepEqual(copySelectedUrls(w, false), { count: 3, text: order.join("\n") });
});

test("the toast says how many links it copied", () => {
  assert.equal(copiedLinksMessage(0, false), "No Links to Copy");
  assert.equal(copiedLinksMessage(1, false), "Copied 1 Link");
  assert.equal(copiedLinksMessage(3, true), "Copied 3 Links as Markdown");
});
