import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("./browser.ts");
const { loadSession, startPersistence, flushPersistence } = await import("../lib/persist.ts");
const { docs } = await import("../test-native/index.ts");
const { launchTab } = await import("./launchTab.ts");
const { createWindowSync } = await import("../lib/windowSync.ts");
const S = () => useBrowser.getState();
function fixture() {
  S().hydrate({});
  const id = S().createWindow({ url: "https://example.com/a" });
  const a = S().windows[id].tabIds[0];
  const b = S().newTab(id, { url: "https://example.com/b" });
  const pin = S().newTab(id, { url: "https://example.com/pin", pinned: true });
  S().createGroup([a, b], { name: "Reading" });
  S().createSplit([a, b], "vertical");
  S().activate(a);
  S().setSelection(id, [a, b]);
  return { id, a, b, pin };
}
function saved() {
  const before = S();
  docs.clear();
  const stop = startPersistence();
  S().hydrate(before);
  flushPersistence();
  stop();
  return JSON.parse(docs.get("session.json"));
}
function hydrate(session) { S().hydrate(loadSession({ contents: JSON.stringify(session) }, null)); }

test("retaining leaves tabs, pins, groups, splits and selection untouched without closed records", () => {
  const { id } = fixture();
  const before = S();
  S().setWindowKeptOnClose(id, true);
  const after = S();
  assert.equal(after.windows[id].keptOnClose, true);
  for (const key of ["tabs", "live", "groups", "splits", "selection", "selectionAnchors", "closedTabs", "closedWindows", "parkedPins"]) assert.equal(after[key], before[key], key);
  assert.deepEqual(after.windows[id].tabIds, before.windows[id].tabIds);
  assert.deepEqual(after.windows[id].activeTabIds, before.windows[id].activeTabIds);
  assert.equal(after.ui.focusedWindowId, id);
  S().setWindowKeptOnClose(id, false);
  assert.ok(!("keptOnClose" in S().windows[id]));
});

test("kept windows save open and visibly restore the same IDs and active tab", () => {
  const { id, a, b, pin } = fixture();
  S().setWindowKeptOnClose(id, true);
  const session = saved();
  assert.equal(session.windows.find((w) => w.id === id).keptOnClose, true);
  assert.deepEqual(session.closedWindows, []);
  assert.deepEqual(session.parkedPins, {});
  hydrate(session);
  assert.deepEqual(S().windows[id].tabIds, session.windows[0].tabIds);
  assert.equal(S().windows[id].activeTabIds.default, a);
  assert.ok(S().tabs[b] && S().tabs[pin]);
  assert.deepEqual(Object.values(S().groups), session.groups);
  assert.deepEqual(Object.values(S().splits), session.splits);
  assert.ok(!S().windows[id].keptOnClose);
});

test("Start Fresh restores the kept window and archives only ordinary windows", () => {
  const { id, a, b, pin } = fixture();
  S().updateSettings({ restoreSession: false });
  S().setWindowKeptOnClose(id, true);
  const other = S().createWindow({ url: "https://other.example/" });
  hydrate(saved());
  assert.deepEqual(S().windowOrder, [id]);
  assert.equal(S().windows[id].activeTabIds.default, a);
  assert.ok(S().tabs[b] && S().tabs[pin]);
  assert.ok(!S().windows[id].keptOnClose);
  assert.ok(!S().windows[other]);
  assert.equal(S().closedWindows.length, 1);
  assert.equal(S().closedWindows[0].tabs[0].url, "https://other.example/");
});

test("a revealed window follows Start Fresh again", () => {
  const { id } = fixture();
  S().updateSettings({ restoreSession: false });
  S().setWindowKeptOnClose(id, true);
  S().setWindowKeptOnClose(id, false);
  hydrate(saved());
  assert.deepEqual(S().windowOrder, []);
  assert.equal(S().closedWindows.length, 1);
});

test("private and Little windows cannot acquire a retained marker", () => {
  fixture();
  for (const options of [{ incognito: true }, { small: true }]) {
    const id = S().createWindow(options);
    const before = S().windows[id];
    S().setWindowKeptOnClose(id, true);
    assert.equal(S().windows[id], before);
  }
  S().setWindowKeptOnClose("missing", true);
});

test("New Window leaves the kept window intact and physical close acknowledges destruction", () => {
  const { id, a } = fixture();
  S().setWindowKeptOnClose(id, true);
  const other = S().createWindow({ url: "https://other.example/" });
  assert.notEqual(id, other);
  assert.equal(S().windows[id].keptOnClose, true);
  assert.equal(S().windows[id].activeTabIds.default, a);
  S().closeWindow(other);
  assert.ok(S().windows[id]);
  assert.ok(!S().windows[other]);
  assert.equal(S().closedWindows.length, 1);
});

test("native retained events change persistence without removing or reopening the window", () => {
  const { id } = fixture();
  let emit;
  const effects = [];
  const sync = createWindowSync({
    port: {
      open: (...args) => effects.push(["open", ...args]), close: (...args) => effects.push(["close", ...args]),
      setTitle: () => {}, windowIds: async () => [id], restoreFullScreen: () => {},
      onEvent: (callback) => { emit = callback; }, releaseProfile: () => {},
    },
    getState: S, isQuitting: () => false, lightsCenter: () => null, isUtilityWindow: () => false,
  });
  sync.listen();
  sync.sync(S());
  const before = S();
  emit({ type: "keptOnClose", id, on: true });
  sync.sync(S(), before);
  assert.equal(S().windows[id].keptOnClose, true);
  assert.equal(effects.length, 1);
  emit({ type: "keptOnClose", id, on: false });
  assert.ok(!S().windows[id].keptOnClose);
});

test("a kept window can prewarm its active page even when ordinary restore is disabled", () => {
  const { id, a } = fixture();
  S().updateSettings({ restoreSession: false });
  S().setWindowKeptOnClose(id, true);
  assert.equal(launchTab(S(), id)?.id, a);
  S().setWindowKeptOnClose(id, false);
  assert.equal(launchTab(S(), id), null);
});
