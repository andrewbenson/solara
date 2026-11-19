import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("./browser.ts");
const model = await import("./model.ts");
const organize = await import("./organize.ts");
const { backClosesToOpener } = await import("./openers.ts");

const S = () => useBrowser.getState();
const realNow = Date.now;
const check = (name, body) =>
  test(name, () => {
    try {
      body();
    } finally {
      Date.now = realNow;
    }
  });
let clock = 1_000_000;
const tick = () => (clock += 1000);
const short = (id) => S().tabs[id].url.replace(/^https:\/\/|\.com$/g, "");
const shown = (w) => short(model.activeTabId(S(), w));

const reset = () => {
  Date.now = () => clock;
  S().hydrate({});
  S().updateSettings({ cmdClickCreatesTabGroup: false, newTabPosition: "bottom", warnBeforeClosingLastTab: false });
};
const step = (f) => {
  tick();
  return f();
};
const setup = (...urls) => {
  const w = step(() => S().createWindow({ url: `${urls[0]}.com` }));
  const ids = [S().windows[w].tabIds[0], ...urls.slice(1).map((u) => step(() => S().newTab(w, { url: `${u}.com`, background: true })))];
  step(() => S().activate(ids[0]));
  return [w, ...ids];
};
const use = (id) => step(() => S().activate(id));
const close = (id) => step(() => S().closeTab(id));
const link = (w, url, opener, background = true) => step(() => S().newTab(w, { url: `${url}.com`, openerId: opener, background }));

check("closing the shown tab goes back to the tab used before it, not the next one down", () => {
  reset();
  const [w, a, b, c, d] = setup("a", "b", "c", "d");
  use(b);
  use(d);
  use(c);
  close(c);
  assert.equal(shown(w), "d");
  close(d);
  assert.equal(shown(w), "b");
  close(b);
  assert.equal(shown(w), "a");
});

check("tabs opened behind and never shown are skipped", () => {
  reset();
  const [w, a, b] = setup("a", "b");
  link(w, "x", a);
  link(w, "y", a);
  use(b);
  close(b);
  assert.equal(shown(w), "a");
});

check("tabs a page opened behind while it was shown don't take over when it closes", () => {
  reset();
  const [w, a, b] = setup("a", "b");
  use(b);
  link(w, "x", b);
  close(b);
  assert.equal(shown(w), "a");
});

check("a link opened in front and then left behind is still a tab you used", () => {
  reset();
  const [w, a, b] = setup("a", "b");
  link(w, "x", a, false);
  use(b);
  close(b);
  assert.equal(shown(w), "x");
});

check("closing the opener after reading a link it opened in front goes back to that link", () => {
  reset();
  const [w, a] = setup("a", "b");
  link(w, "x", a, false);
  use(a);
  close(a);
  assert.equal(shown(w), "x");
});

check("a tab opened behind without an opener never wins until it has been shown", () => {
  reset();
  const [w, a, b] = setup("a", "b");
  const z = step(() => S().newTab(w, { url: "z.com", background: true }));
  assert.equal(S().tabs[z].shownAt, 0);
  use(b);
  close(b);
  assert.equal(shown(w), "a");
});

check("a tab opened behind counts once it has been shown", () => {
  reset();
  const [w, a, b] = setup("a", "b");
  const x = link(w, "x", a);
  use(x);
  assert.equal(S().tabs[x].shownAt, undefined);
  use(b);
  close(b);
  assert.equal(shown(w), "x");
});

check("a tab shown because the tab above it closed counts as shown", () => {
  reset();
  const [w, a] = setup("a");
  const x = step(() => S().newTab(w, { url: "x.com", background: true }));
  close(a);
  assert.equal(shown(w), "x");
  assert.equal(S().tabs[x].shownAt, clock);
});

check("a sleeping tab can be the one shown, and it wakes", () => {
  reset();
  const [w, a, b, c] = setup("a", "b", "c");
  use(b);
  use(c);
  const tabs = S().tabs;
  useBrowser.setState({ tabs: { ...tabs, [b]: { ...tabs[b], navigation: null, unloaded: true } } });
  close(c);
  assert.equal(shown(w), "b");
  assert.equal(S().tabs[b].unloaded, undefined);
  assert.ok(S().tabs[b].navigation, "it loads again");
});

check("tabs saved before shownAt existed rank by when they were last active", () => {
  reset();
  const [w, a, b, c] = setup("a", "b", "c");
  use(c);
  use(b);
  const saved = Object.fromEntries(Object.entries(S().tabs).map(([id, { shownAt: _, ...t }]) => [id, t]));
  S().hydrate({ windows: S().windows, windowOrder: S().windowOrder, tabs: saved });
  assert.ok(Object.values(S().tabs).every((t) => !("shownAt" in t)), "loaded without the field");
  close(b);
  assert.equal(shown(w), "c");
});

check("closing the last tab of a group goes back to the tab used before it, outside the group", () => {
  reset();
  const [w, a, b, c] = setup("a", "b", "c");
  const [next] = organize.withGroup(S(), [c]);
  useBrowser.setState(next);
  use(a);
  use(c);
  close(c);
  assert.equal(shown(w), "a");
});

check("a tab inside a collapsed group is passed over", () => {
  reset();
  const [w, a, b, c] = setup("a", "b", "c");
  const [next, g] = organize.withGroup(S(), [b]);
  useBrowser.setState(next);
  use(b);
  use(a);
  use(c);
  step(() => S().updateGroup(g, { collapsed: true }));
  close(c);
  assert.equal(shown(w), "a");
});

check("closing one pane of a split shows the other pane", () => {
  reset();
  const [w, a, b, c] = setup("a", "b", "c");
  step(() => S().createSplit([b, c]));
  use(a);
  use(b);
  close(b);
  assert.equal(shown(w), "c");
});

check("closing one pane of a three-pane split stays in the split, even when its panes tie", () => {
  reset();
  const [w, a, b, c, d] = setup("a", "b", "c", "d");
  step(() => S().createSplit([b, c, d]));
  use(a);
  use(b);
  const tabs = S().tabs;
  useBrowser.setState({ tabs: { ...tabs, [c]: { ...tabs[c], shownAt: 5 }, [d]: { ...tabs[d], shownAt: 5 } } });
  close(b);
  assert.equal(shown(w), "c");
});

check("closing one pane of a three-pane split with tied panes on both sides goes to the nearer one below", () => {
  reset();
  const [w, a, b, c, d] = setup("a", "b", "c", "d", "e");
  step(() => S().createSplit([b, c, d]));
  use(a);
  use(c);
  const tabs = S().tabs;
  useBrowser.setState({ tabs: { ...tabs, [b]: { ...tabs[b], shownAt: 5 }, [d]: { ...tabs[d], shownAt: 5 } } });
  close(c);
  assert.equal(shown(w), "d");
});

check("an open Peek is never the tab shown next", () => {
  reset();
  const [w, a, b, c] = setup("a", "b", "c");
  use(c);
  step(() => S().openPeek(c, "https://peek.com/"));
  use(b);
  close(b);
  assert.notEqual(shown(w), "peek");
  assert.equal(shown(w), "c");
});

check("closing with the opener as successor goes straight to it and leaves every other tab as it was", () => {
  reset();
  const [w, a, b, c] = setup("a", "b", "c");
  const x = link(w, "x", a, false);
  use(b);
  use(x);
  const tabs = S().tabs;
  useBrowser.setState({ tabs: { ...tabs, [b]: { ...tabs[b], navigation: null, unloaded: true } } });
  const before = { b: S().tabs[b], c: S().tabs[c] };
  step(() => S().closeTab(x, a));
  assert.equal(shown(w), "a");
  assert.deepEqual(S().tabs[b], before.b, "b is not shown, woken or stamped");
  assert.deepEqual(S().tabs[c], before.c);
  assert.equal(S().tabs[a].lastActiveAt, clock, "the opener is activated");
  assert.equal(S().closedTabs.at(-1).tabId, x);
});

check("a successor outside the window and profile is ignored", () => {
  reset();
  const [w, a, b] = setup("a", "b");
  const other = step(() => S().createWindow({ url: "o.com" }));
  const o = S().windows[other].tabIds[0];
  step(() => S().activate(b));
  use(a);
  use(b);
  step(() => S().closeTab(b, o));
  assert.equal(shown(w), "a");
});

check("reopening a closed window keeps when each tab was last shown", () => {
  reset();
  const [w, a, b, c] = setup("a", "b", "c");
  use(c);
  use(a);
  const keptC = S().tabs[c].lastActiveAt;
  const other = step(() => S().createWindow({ url: "o.com" }));
  step(() => S().closeWindow(w));
  step(() => S().reopenClosedWindow());
  const back = Object.values(S().tabs).filter((t) => t.windowId !== other);
  const byUrl = (u) => back.find((t) => t.url === `https://${u}.com/` || t.url === `${u}.com` || t.url.includes(`${u}.com`));
  assert.equal(byUrl("b").shownAt, 0, "never shown stays never shown");
  assert.equal(byUrl("c").shownAt, keptC);
});

check("a window closed before shownAt existed comes back with its other tabs counted as never shown", () => {
  reset();
  const [w, a, b, c] = setup("a", "b", "c");
  use(c);
  use(a);
  const other = step(() => S().createWindow({ url: "o.com" }));
  step(() => S().closeWindow(w));
  const closedWindows = S().closedWindows.map((e) => ({ ...e, tabs: e.tabs.map(({ shownAt: _, ...t }) => t) }));
  useBrowser.setState({ closedWindows });
  step(() => S().reopenClosedWindow());
  const back = Object.values(S().tabs).filter((t) => t.windowId !== other);
  const byUrl = (u) => back.find((t) => t.url.includes(`${u}.com`));
  assert.equal(byUrl("b").shownAt, 0);
  assert.equal(byUrl("c").shownAt, 0);
  assert.equal(byUrl("a").shownAt, undefined, "the shown tab is activated");
});

check("a tab cleared before shownAt existed comes back from Undo Clear as never shown", () => {
  reset();
  const [w, a] = setup("a", "b");
  use(a);
  const cleared = step(() => S().clearUnpinnedTabs(w));
  const old = { ...cleared, entries: cleared.entries.map(({ shownAt: _, ...e }) => e) };
  step(() => S().undoClearTabs(old));
  const back = Object.values(S().tabs).filter((t) => t.windowId === w && t.url.includes("b.com"));
  assert.equal(back.length, 1);
  assert.equal(back[0].shownAt, 0);
  assert.equal(shown(w), "a");
});

check("an opener inside a collapsed group isn't revealed by Back; the usual successor shows instead", () => {
  reset();
  const [w, a, b] = setup("a", "b");
  const x = link(w, "x", a, false);
  use(b);
  use(x);
  const [grouped, g] = organize.withGroup(S(), [a]);
  useBrowser.setState(grouped);
  step(() => S().updateGroup(g, { collapsed: true }));
  step(() => S().closeTab(x, a));
  assert.equal(shown(w), "b");
});

check("another profile's tabs are never picked", () => {
  reset();
  const work = S().createProfile({ name: "Work" });
  const [w, a, b] = setup("a", "b");
  const other = step(() => S().newTab(w, { url: "o.com", profileId: work }));
  use(b);
  use(a);
  use(b);
  close(b);
  assert.equal(shown(w), "a");
  assert.equal(S().tabs[other].profileId, work);
});

check("with no tab used before it, closing falls back to the nearest tab", () => {
  reset();
  const [w, a] = setup("a");
  step(() => S().newTab(w, { url: "x.com", background: true }));
  step(() => S().newTab(w, { url: "y.com", background: true }));
  close(a);
  assert.equal(shown(w), "x");
});

check("when two tabs were last shown at the same moment, the nearest tab decides", () => {
  reset();
  const [w, a, b, c] = setup("a", "b", "c");
  tick();
  S().activate(a);
  S().activate(b);
  S().activate(c);
  close(c);
  assert.equal(shown(w), "b");
});

check("closing a pinned tab goes back to the tab used before it", () => {
  reset();
  const [w, a, b, p] = setup("a", "b", "p");
  step(() => S().togglePin(p));
  use(b);
  use(a);
  use(p);
  close(p);
  assert.equal(shown(w), "a");
});

check("Back closes a tab a link opened when its opener is still here", () => {
  reset();
  const [w, a, b] = setup("a", "b");
  const x = link(w, "x", a, false);
  assert.equal(backClosesToOpener(S(), x), a);
  assert.equal(backClosesToOpener(S(), b), undefined, "no opener");
  step(() => S().activate(a));
  close(x);
  assert.equal(shown(w), "a");
  assert.equal(S().closedTabs.at(-1).tabId, x, "it can be reopened");
});

check("Back doesn't close a pinned tab, a split pane, or a tab whose opener is gone or in another profile", () => {
  reset();
  const work = S().createProfile({ name: "Work" });
  const [w, a, b, c] = setup("a", "b", "c");
  const pinned = link(w, "p", a, false);
  step(() => S().togglePin(pinned));
  assert.equal(backClosesToOpener(S(), pinned), undefined);
  const pane = link(w, "s", a, false);
  step(() => S().createSplit([pane, c]));
  assert.equal(backClosesToOpener(S(), pane), undefined);
  const orphan = link(w, "o", b, false);
  close(b);
  assert.equal(S().tabs[orphan].openerId, null);
  assert.equal(backClosesToOpener(S(), orphan), undefined);
  const foreign = step(() => S().newTab(w, { url: "f.com", profileId: work, openerId: a }));
  assert.equal(backClosesToOpener(S(), foreign), undefined);
});
