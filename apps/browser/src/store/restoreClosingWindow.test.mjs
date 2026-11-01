import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("./browser.ts");
const { pinnedAreaAdapters } = await import("../sync/pinned.ts");
const { deviceTabsAdapter } = await import("../sync/adapters.ts");
const { newTileFolder } = await import("./tileFolders.ts");
const { workspaceFromPatch, workspaceFromSnapshot } = await import("./nativeWorkspace.ts");
const { restoredNativeClosingLocals, pruneClosingLocals, nativeClosingLiveAtApply, nativeClosingUndo } = await import("./closingWindowRestore.ts");
await import("../test-native/index.ts");
const { IDLE_LIVE } = await import("./model.ts");

const S = () => useBrowser.getState();
const snapshot = (w) => ({
  window: S().windows[w],
  tabs: S().windows[w].tabIds.map((id) => S().tabs[id]),
  groups: Object.values(S().groups).filter((g) => g.windowId === w),
  splits: Object.values(S().splits).filter((v) => v.windowId === w),
});

function fixture(options = {}) {
  S().hydrate({});
  const w = S().createWindow({ url: "https://tile.example/", ...options });
  const open = (name) => S().newTab(w, { url: `https://${name}.example/`, background: true });
  const tile = S().windows[w].tabIds[0];
  const [row, member, a, b] = ["row", "member", "a", "b"].map(open);
  if (!options.small) {
    S().pinTabs([tile], true);
    S().pinTabs([row], true, true);
    S().groupTabs([member], { pinned: true, name: "Pinned" });
    S().groupTabs([a, b], { pinned: false, name: "Regular" });
    S().createSplit([a, b], "vertical");
  }
  S().setDownloadsOpen(w, true);
  S().setFind(a, { open: true, query: "needle", count: 3, active: 2 });
  S().setSelection(w, [a, b]);
  useBrowser.setState({ selectionAnchors: { [w]: a } });
  S().updateLive(a, { playingAudio: true, canGoBack: true });
  return { w, saved: snapshot(w), before: S() };
}

function assertRestored({ w, saved, before }, restored) {
  assert.ok(restored);
  assert.notEqual(restored, w);
  const remap = (id) => id === w ? restored : id;
  assert.deepEqual(S().windows[restored], { ...saved.window, id: restored, chromeWindow: "chrome-stay" });
  assert.deepEqual(S().windowOrder, before.windowOrder.map(remap));
  assert.deepEqual(S().ui, { ...before.ui, focusedWindowId: before.ui.focusedWindowId && remap(before.ui.focusedWindowId), focusOrder: before.ui.focusOrder.map(remap) });
  assert.deepEqual(S().windowUi[restored], before.windowUi[w]);
  assert.deepEqual(S().selection[restored], before.selection[w]);
  assert.deepEqual(S().selectionAnchors[restored], before.selectionAnchors[w]);
  for (const tab of saved.tabs) {
    assert.deepEqual(S().tabs[tab.id], { ...tab, windowId: restored });
    assert.deepEqual(S().live[tab.id], before.live[tab.id]);
    assert.deepEqual(S().find[tab.id], before.find[tab.id]);
    assert.equal(Object.values(S().windows).flatMap((x) => x.tabIds).filter((id) => id === tab.id).length, 1);
    assert.ok(!Object.values(S().parkedPins).some((p) => p.tabs.some((t) => t.id === (tab.pinKey ?? tab.id))));
  }
  for (const group of saved.groups) {
    assert.deepEqual(S().groups[group.id], { ...group, windowId: restored });
    assert.ok(!Object.values(S().parkedPins).some((p) => p.groups.some((g) => g.id === (group.pinKey ?? group.id))));
  }
  for (const split of saved.splits) assert.deepEqual(S().splits[split.id], { ...split, windowId: restored });
  assert.deepEqual(S().parkedPins, before.parkedPins);
  assert.deepEqual(S().closedTabs, before.closedTabs);
  assert.deepEqual(S().closedWindows, before.closedWindows);
}

for (const [kind, options] of [["normal", {}], ["private", { incognito: true }], ["small", { small: true }]]) {
  test(`${kind} close then Stay restores the original ids and close side effects`, () => {
    const f = fixture(options);
    S().closeWindow(f.w);
    assert.equal(S().windows[f.w], undefined);
    if (kind === "normal") assert.ok(Object.values(S().parkedPins).some((p) => p.tabs.length));
    if (kind === "small") assert.ok(S().closedTabs.some((c) => c.windowId === f.w));
    assertRestored(f, S().restoreClosingWindow(f.saved, "chrome-stay", f.saved.tabs.map((t) => t.id)));
  });
}

for (const [where, collide] of [
  ["tabs", (f) => useBrowser.setState({ tabs: { ...S().tabs, [f.saved.tabs[0].id]: f.saved.tabs[0] } })],
  ["window membership", (f) => {
    const w = S().createWindow({ incognito: true, url: "https://other.example/" });
    useBrowser.setState({ windows: { ...S().windows, [w]: { ...S().windows[w], tabIds: [...S().windows[w].tabIds, f.saved.tabs[0].id] } } });
  }],
  ["group membership", (f) => useBrowser.setState({ groups: { foreign: { ...f.saved.groups[0], id: "foreign", windowId: "elsewhere", tabIds: [f.saved.tabs[0].id] } } })],
  ["parked pins", () => {
    const p = S().parkedPins.default;
    useBrowser.setState({ parkedPins: { ...S().parkedPins, default: { ...p, tabs: [...p.tabs, { ...p.tabs[0], id: "newer-pin" }] } } });
  }],
]) {
  test(`Stay refuses a collision in ${where} without changing state`, () => {
    const f = fixture();
    S().closeWindow(f.w);
    collide(f);
    const before = S();
    assert.equal(S().restoreClosingWindow(f.saved, "chrome-stay", f.saved.tabs.map((t) => t.id)), null);
    assert.equal(S(), before);
  });
}

test("Stay refuses after a shared pin's original page id moves to another window", () => {
  S().hydrate({});
  const w = S().createWindow({ url: "https://mail.example/" });
  const tile = S().windows[w].tabIds[0];
  S().newTab(w, { url: "https://regular.example/" });
  S().pinTabs([tile], true);
  S().activate(tile);
  const other = S().createWindow({ url: "https://other.example/" });
  const copy = S().windows[other].tabIds.find((id) => S().tabs[id].pinnedUrl === "https://mail.example/");
  S().activate(copy);
  const f = { w: other, saved: snapshot(other) };
  S().closeWindow(f.w);
  assert.ok(f.saved.tabs.some((t) => S().tabs[t.id]));
  const before = S();
  assert.equal(S().restoreClosingWindow(f.saved, "chrome-stay", f.saved.tabs.map((t) => t.id)), null);
  assert.equal(S(), before);
});

test("all pin adapters extract the same records before close, parked, and after Stay", () => {
  const f = fixture();
  const tile = f.saved.tabs.find((t) => t.pinned && !t.pinnedAsRow);
  useBrowser.setState(newTileFolder(S(), [tile.id], "Folder").state);
  S().updateGroup(f.saved.groups.find((g) => g.pinned).id, { color: "none" });
  f.saved = snapshot(f.w);
  const extract = () => new Map(pinnedAreaAdapters("default").flatMap((a) => [...a.extract(() => undefined, () => false, 1000, () => false, () => undefined, () => undefined).values]));
  const before = extract();
  for (const prefix of ["pin:t:", "pin:g:", "pinrow:", "tilefold:", "pord:", "pgh:", "pgc:"]) assert.ok([...before.keys()].some((key) => key.startsWith(prefix)), prefix);
  S().closeWindow(f.w);
  assert.deepEqual(extract(), before);
  assert.ok(S().restoreClosingWindow(f.saved, "chrome-stay", f.saved.tabs.map((t) => t.id)));
  assert.deepEqual(extract(), before);
  const regular = deviceTabsAdapter("default", "device", () => "Mac").extract().values;
  assert.ok(regular.has("tabs:device"));
  const withPrivate = [...regular];
  S().createWindow({ incognito: true, url: "https://private.example/" });
  assert.deepEqual([...deviceTabsAdapter("default", "device", () => "Mac").extract().values], withPrivate);
});

test("the native workspace close undo contains only JS-owned live state", () => {
  const { w, saved, before } = fixture();
  const removed = workspaceFromPatch(before, {
    rev: 1,
    windows: { upsert: [], remove: [w] },
    tabs: { upsert: [], remove: saved.tabs.map((t) => t.id) },
    find: { upsert: [], remove: saved.tabs.map((t) => t.id) },
    selection: { upsert: [], remove: [w] },
    selectionAnchors: { upsert: [], remove: [w] },
    windowUi: { upsert: [], remove: [w] },
  });
  const closed = { ...before, ...removed };
  assert.equal(closed.live[saved.tabs[0].id], undefined);
  assert.equal(closed.windowUi[w], undefined);
  const locals = restoredNativeClosingLocals(closed, w);
  assert.ok(locals);
  const restored = pruneClosingLocals(locals);
  assert.deepEqual(restored.live, before.live);
  assert.equal("find" in restored, false);
  assert.equal("ui" in restored, false);
  assert.deepEqual(Object.keys(restored), ["live"]);
  assert.ok(restoredNativeClosingLocals({ ...closed, find: before.find }, w));
  assert.equal(restoredNativeClosingLocals({ ...closed, live: before.live }, w), null);
});

test("the native live undo applies per entry only while it still holds the post-close value", () => {
  const { w, saved, before } = fixture();
  const removed = workspaceFromPatch(before, {
    rev: 1,
    windows: { upsert: [], remove: [w] },
    tabs: { upsert: [], remove: saved.tabs.map((t) => t.id) },
    find: { upsert: [], remove: saved.tabs.map((t) => t.id) },
    selection: { upsert: [], remove: [w] },
    selectionAnchors: { upsert: [], remove: [w] },
    windowUi: { upsert: [], remove: [w] },
  });
  const closed = { ...before, ...removed };
  const a = Object.keys(before.live).find((id) => saved.tabs.some((t) => t.id === id));
  assert.ok(a);
  assert.deepEqual(nativeClosingLiveAtApply(closed, nativeClosingUndo(w)).live[a], before.live[a]);
  assert.deepEqual(nativeClosingLiveAtApply({ ...closed, live: { ...closed.live, [a]: IDLE_LIVE } }, nativeClosingUndo(w)).live[a], before.live[a]);
  const newer = { ...before.live[a], playingAudio: false };
  const edited = { ...closed, live: { ...closed.live, [a]: newer, other: { playingAudio: true } } };
  const applied = nativeClosingLiveAtApply(edited, nativeClosingUndo(w)).live;
  assert.deepEqual(applied[a], newer);
  assert.deepEqual(applied.other, { playingAudio: true });
});

test("Stay takes back pin keys and leaves unrelated preexisting parked pins alone", () => {
  const f = fixture();
  const pin = f.saved.tabs.find((t) => t.pinned);
  S().updateTab(pin.id, { pinKey: "canonical-pin" });
  const parked = { ...pin, id: "unrelated", url: "https://parked.example/", pinnedUrl: "https://parked.example/", groupId: null };
  useBrowser.setState({ parkedPins: { default: { tabs: [parked], groups: [] } } });
  f.saved = snapshot(f.w);
  S().closeWindow(f.w);
  assert.ok(S().parkedPins.default.tabs.some((t) => t.id === "canonical-pin"));
  assert.ok(S().restoreClosingWindow(f.saved, "chrome-stay", f.saved.tabs.map((t) => t.id)));
  assert.equal(S().tabs[pin.id].pinKey, "canonical-pin");
  assert.deepEqual(S().parkedPins, { default: { tabs: [parked], groups: [] } });
});

test("hydrate invalidates an earlier close undo", () => {
  const f = fixture();
  S().closeWindow(f.w);
  S().hydrate({});
  const before = S();
  assert.equal(S().restoreClosingWindow(f.saved, "chrome-stay", f.saved.tabs.map((t) => t.id)), null);
  assert.equal(S(), before);
});

test("a native snapshot fallback also retains local close undo", () => {
  const { w, saved, before } = fixture();
  const removed = workspaceFromSnapshot(before, { windows: {}, tabs: {}, windowOrder: [] }, { keepLocal: true });
  const local = restoredNativeClosingLocals({ ...before, ...removed }, w);
  assert.ok(local);
  assert.deepEqual(local.live, before.live);
  assert.equal("find" in local, false);
  assert.equal("ui" in local, false);
  assert.deepEqual(Object.keys(local), ["live"]);
  assert.deepEqual(Object.keys(pruneClosingLocals(local)), ["live"]);
  assert.ok(saved.tabs.length);
});

test("a restored id parked under another profile refuses without changing state", () => {
  const f = fixture();
  const tab = f.saved.tabs.find((t) => !t.pinned);
  S().closeWindow(f.w);
  useBrowser.setState({ parkedPins: { ...S().parkedPins, elsewhere: { tabs: [{ ...tab, id: tab.id, groupId: null }], groups: [] } } });
  const before = S();
  assert.equal(S().restoreClosingWindow(f.saved, "chrome-stay", f.saved.tabs.map((t) => t.id)), null);
  assert.equal(S(), before);
});

test("a pinned opener reference refuses without changing state", () => {
  const f = fixture();
  S().closeWindow(f.w);
  useBrowser.setState({ groups: { ...S().groups, foreign: { ...f.saved.groups[0], id: "foreign", windowId: "elsewhere", tabIds: [], pinnedOpenerId: f.saved.tabs[0].id } } });
  const before = S();
  assert.equal(S().restoreClosingWindow(f.saved, "chrome-stay", f.saved.tabs.map((t) => t.id)), null);
  assert.equal(S(), before);
});

for (const alias of [false, true]) {
  test(`a parked group parent reference refuses without changing state (alias: ${alias})`, () => {
    const f = fixture();
    const group = f.saved.groups.find((g) => g.pinned);
    if (alias) S().updateGroup(group.id, { pinKey: "group-key" });
    f.saved = snapshot(f.w);
    S().closeWindow(f.w);
    useBrowser.setState({ parkedPins: { ...S().parkedPins, elsewhere: { tabs: [], groups: [{ id: "foreign-child", name: "Child", icon: null, color: null, collapsed: false, parentId: alias ? "group-key" : group.id }] } } });
    const before = S();
    assert.equal(S().restoreClosingWindow(f.saved, "chrome-stay", f.saved.tabs.map((t) => t.id)), null);
    assert.equal(S(), before);
  });
}


test("Stay restores only the live tab and records the other two as normal closes atomically", () => {
  S().hydrate({});
  const w = S().createWindow({ url: "https://first.example/" });
  const live = S().newTab(w, { url: "https://live.example/", background: true });
  const last = S().newTab(w, { url: "https://last.example/", background: true });
  const first = S().windows[w].tabIds[0];
  S().groupTabs([first, live, last], { pinned: false, name: "Partial" });
  S().createSplit([first, live, last], "vertical");
  S().setSelection(w, [first, live, last]);
  useBrowser.setState({ selectionAnchors: { [w]: first } });
  const closing = snapshot(w);
  S().closeWindow(w);
  const observed = [];
  const unsubscribe = useBrowser.subscribe((s) => observed.push(s));
  const restored = S().restoreClosingWindow(closing, "chrome-stay", [live, "unknown"]);
  unsubscribe();
  assert.ok(restored);
  assert.equal(observed.length, 1);
  assert.deepEqual(S().windows[restored].tabIds, [live]);
  assert.equal(S().windows[restored].activeTabIds.default, live);
  assert.equal(S().tabs[live].windowId, restored);
  assert.equal(S().tabs[first], undefined);
  assert.equal(S().tabs[last], undefined);
  assert.deepEqual(S().closedTabs.map((t) => t.tabId), [first, last]);
  assert.deepEqual(S().closedTabs.map((t) => t.windowId), [restored, restored]);
  assert.ok(S().closedTabs.every((t) => t.group?.name === "Partial"));
  assert.equal(S().closedWindows.length, 0);
  assert.equal(Object.keys(S().splits).length, 0);
  assert.deepEqual(Object.values(S().groups)[0].tabIds, [live]);
  assert.deepEqual(S().selection[restored], [live]);
  assert.equal(S().selectionAnchors[restored], undefined);
  S().reopenClosedTab(restored);
  assert.ok(S().windows[restored].tabIds.some((id) => S().tabs[id].url === "https://last.example/"));
});

for (const ids of [[], ["unknown"]]) {
  test(`Stay with no live snapshot tabs leaves the close intact (${ids.length})`, () => {
    const f = fixture();
    S().closeWindow(f.w);
    const before = S();
    assert.equal(S().restoreClosingWindow(f.saved, "chrome-stay", ids), null);
    assert.equal(S(), before);
  });
}

test("Stay unloads missing pins without changing their sync records", () => {
  const f = fixture();
  const extract = () => new Map(pinnedAreaAdapters("default").flatMap((a) => [...a.extract(() => undefined, () => false, 1000, () => false, () => undefined, () => undefined).values]));
  const before = extract();
  const live = f.saved.tabs.find((t) => !t.pinned && !f.saved.groups.some((g) => g.pinned && g.tabIds.includes(t.id))).id;
  S().closeWindow(f.w);
  const restored = S().restoreClosingWindow(f.saved, "chrome-stay", [live]);
  assert.ok(restored);
  assert.deepEqual(extract(), before);
  for (const tab of f.saved.tabs.filter((t) => t.id !== live)) {
    const pinned = tab.pinned || f.saved.groups.some((g) => g.pinned && g.tabIds.includes(tab.id));
    if (pinned) {
      assert.equal(S().tabs[tab.id].unloaded, true);
      assert.equal(S().tabs[tab.id].navigation, null);
      assert.equal(S().tabs[tab.id].adoptId, undefined);
    } else assert.equal(S().tabs[tab.id], undefined);
    assert.ok(S().closedTabs.some((c) => c.tabId === tab.id));
  }
  assert.equal(S().windows[restored].activeTabIds.default, live);
});

test("Stay keeps a live pinned split pane loaded when its sibling has closed", () => {
  S().hydrate({});
  const w = S().createWindow({ url: "https://first.example/" });
  const first = S().windows[w].tabIds[0];
  const live = S().newTab(w, { url: "https://live.example/" });
  S().pinTabs([first, live], true, true);
  S().createSplit([first, live], "vertical");
  const saved = snapshot(w);
  S().closeWindow(w);
  const restored = S().restoreClosingWindow(saved, "chrome-stay", [live]);
  assert.ok(restored);
  assert.equal(S().tabs[first].unloaded, true);
  assert.ok(S().tabs[live].navigation);
  assert.equal(S().tabs[live].unloaded, undefined);
  assert.deepEqual(S().windows[restored].tabIds, saved.window.tabIds);
  assert.equal(Object.keys(S().splits).length, 0);
  assert.deepEqual(S().closedTabs.map((c) => c.tabId), [first]);
});

test("native local restoration prunes closed tabs and unloaded pins", () => {
  const f = fixture();
  S().closeWindow(f.w);
  const live = f.saved.tabs.at(-1).id;
  const restored = S().restoreClosingWindow(f.saved, "chrome-stay", [live]);
  const other = S().createWindow({ url: "https://unrelated.example/" });
  const otherTab = S().windows[other].tabIds[0];
  S().pinTabs([otherTab], true);
  S().closeTabs([otherTab]);
  const local = {
    live: { ...f.before.live, [otherTab]: { playingAudio: true } },
  };
  const filtered = pruneClosingLocals(local, S(), f.saved.tabs.map((t) => t.id));
  for (const tab of f.saved.tabs.filter((t) => t.id !== live)) {
    assert.equal(filtered.live[tab.id]?.playingAudio ?? false, false);
    if (!S().tabs[tab.id]) assert.equal(filtered.live[tab.id], undefined);
  }
  assert.deepEqual(filtered.live[live], f.before.live[live]);
  assert.deepEqual(Object.keys(filtered), ["live"]);
  assert.deepEqual(filtered.live[otherTab], local.live[otherTab]);
  assert.equal("find" in filtered, false);
  assert.equal("ui" in filtered, false);
});

test("Stay keeps an already unloaded pin without recording another close", () => {
  S().hydrate({});
  const w = S().createWindow({ url: "https://pin.example/" });
  const pin = S().windows[w].tabIds[0];
  const live = S().newTab(w, { url: "https://live.example/" });
  S().pinTabs([pin], true);
  S().closeTabs([pin]);
  const before = S().closedTabs;
  const saved = snapshot(w);
  S().closeWindow(w);
  const restored = S().restoreClosingWindow(saved, "chrome-stay", [live]);
  assert.ok(restored);
  assert.equal(S().tabs[pin].unloaded, true);
  assert.deepEqual(S().closedTabs, before);
});

test("Stay switches away from a profile with no live pages without waking its pins", () => {
  S().hydrate({});
  const w = S().createWindow({ url: "https://gone.example/" });
  const pin = S().windows[w].tabIds[0];
  S().pinTabs([pin], true);
  const profile = S().createProfile({ name: "Survived" });
  const live = S().newTab(w, { url: "https://live.example/", profileId: profile, background: true });
  const saved = snapshot(w);
  S().closeWindow(w);
  const restored = S().restoreClosingWindow(saved, "chrome-stay", [live]);
  assert.ok(restored);
  assert.deepEqual(S().windows[restored].tabIds, saved.window.tabIds);
  assert.equal(S().windows[restored].profileId, profile);
  assert.deepEqual(S().windows[restored].activeTabIds, { [profile]: live });
  assert.equal(S().ui.lastProfileId, profile);
  assert.equal(S().tabs[pin].unloaded, true);
});

test("Stay preserves a live pin's earlier closed page at another URL", () => {
  S().hydrate({});
  const w = S().createWindow({ url: "https://old-pin.example/" });
  const pin = S().windows[w].tabIds[0];
  const regular = S().newTab(w, { url: "https://regular.example/" });
  S().pinTabs([pin], true);
  S().closeTabs([pin]);
  S().activate(pin);
  S().navigate(pin, "https://new-pin.example/");
  S().navigated(pin, { url: "https://new-pin.example/", title: "New page" }, {});
  const saved = snapshot(w);
  const before = S().closedTabs;
  assert.equal(before.length, 1);
  S().closeWindow(w);
  const restored = S().restoreClosingWindow(saved, "chrome-stay", [pin, regular]);
  assert.ok(restored);
  assert.equal(S().tabs[pin].url, "https://new-pin.example/");
  assert.deepEqual(S().closedTabs, before);
});

test("Stay does not recreate a peek missing from the live snapshot tabs", () => {
  S().hydrate({});
  const w = S().createWindow({ url: "https://source.example/" });
  const source = S().windows[w].tabIds[0];
  const peek = S().openPeek(source, "https://peek.example/");
  const saved = snapshot(w);
  S().closeWindow(w);
  assert.equal(S().tabs[peek], undefined);
  const restored = S().restoreClosingWindow(saved, "chrome-stay", [source]);
  assert.ok(restored);
  assert.equal(S().tabs[peek], undefined);
  assert.equal(S().peeks[restored], undefined);
  assert.equal(S().closedTabs.length, 0);
});
