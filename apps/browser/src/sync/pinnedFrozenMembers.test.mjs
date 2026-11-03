import assert from "node:assert/strict";
import { test } from "node:test";
const { useBrowser } = await import("../store/browser.ts");
const { Clock, emptyScope, syncScope } = await import("@solara/sync");
const pinnedArea = await import("./pinned.ts");
const { syncRedesign } = await import("./redesignSwitch.ts");

const S = () => useBrowser.getState();

class Folder {
  files = new Map();
  counter = 0;
  transport() {
    return {
      write: async (scope, payload) => {
        const id = `f${++this.counter}`;
        this.files.set(id, { scope, payload });
        return id;
      },
      read: async (scope, known) => {
        const shown = [...this.files].filter(([, f]) => f.scope === scope);
        const files = shown.filter(([id]) => !known.includes(id)).map(([id, f]) => ({ id, payload: f.payload }));
        return { files, pending: [], damaged: [], present: shown.map(([id]) => id) };
      },
      remove: async (_scope, ids) => ids.forEach((id) => this.files.delete(id)),
    };
  }
}

class Device {
  constructor(id, folder) {
    this.id = id;
    this.folder = folder;
    this.beforePinApply = null;
    this.rewriteView = null;
    S().hydrate({});
    this.browser = S();
    this.scope = emptyScope();
    this.clock = new Clock(id);
  }
  with(fn) {
    useBrowser.setState(this.browser, true);
    try {
      return fn();
    } finally {
      this.browser = S();
    }
  }
  adapters() {
    return pinnedArea.pinnedAreaAdapters("default").map((adapter) => {
      if (adapter.prefix !== "pin") return adapter;
      return {
        ...adapter,
        apply: (visible, changed, base, records) => {
          const local = this.beforePinApply;
          this.beforePinApply = null;
          const remote = this.rewriteView;
          this.rewriteView = null;
          remote?.(visible, changed);
          local?.();
          return adapter.apply(visible, changed, base, records);
        },
      };
    });
  }
  async sync() {
    useBrowser.setState(this.browser, true);
    try {
      return await syncScope({ scope: "p", state: this.scope, transport: this.folder.transport(), adapters: this.adapters(), clock: this.clock, device: this.id, options: { writtenKeysOnly: syncRedesign.on } });
    } finally {
      this.browser = S();
    }
  }
}

async function syncAll(devices, rounds = 2) {
  for (let i = 0; i < rounds; i++) for (const d of devices) await d.sync();
}

const urlOf = (t) => t.pinnedUrl || t.url;

function setUp() {
  const folder = new Folder();
  const a = new Device("devA", folder);
  const b = new Device("devB", folder);
  const made = a.with(() => {
    const w = S().createWindow({ url: "https://home.example/" });
    const work = S().createProfile({ name: "Work" });
    const other = S().createWindow({ url: "https://other.example/", profileId: work });
    const u = S().newTab(w, { url: "https://tile.example/", background: true });
    S().pinTabs([u], true);
    const m = S().newTab(w, { url: "https://member.example/", background: true });
    const g = S().groupTabs([m], { pinned: true, name: "Reading" });
    return { w, other, u, m, g };
  });
  b.with(() => S().createWindow({ url: "https://b-home.example/" }));
  return { folder, a, b, ...made };
}

for (const on of [false, true]) {
  test(`a tab added to a pinned group after the pull's view was frozen survives that apply and the window's close, redesign ${on}`, async () => {
    syncRedesign.on = on;
    const { a, b, w, u, g } = setUp();
    await syncAll([a, b]);
    b.with(() => S().updateTab(Object.values(S().tabs).find((t) => urlOf(t) === "https://tile.example/").id, { customTitle: "Renamed" }));
    await b.sync();
    let n;
    a.beforePinApply = () => {
      n = S().newTab(w, { url: "https://new-member.example/", background: true });
      S().addTabsToGroup(g, [n]);
      S().closeWindow(w);
    };
    await a.sync();
    assert.ok(n, "the local edits ran between extraction and apply");
    const parked = a.with(() => S().parkedPins.default);
    const urls = (parked?.tabs ?? []).filter((t) => t.groupId === g).map(urlOf).sort();
    assert.deepEqual(urls, ["https://member.example/", "https://new-member.example/"], "n is parked with the group");
    assert.deepEqual((parked?.tabs ?? []).filter((t) => t.id === u).map((t) => t.customTitle), ["Renamed"], "the tile parked with B's title");
  });

  test(`a tab added to a pinned group after the pull's view was frozen keeps its membership, redesign ${on}`, async () => {
    syncRedesign.on = on;
    const { a, b, w, g } = setUp();
    await syncAll([a, b]);
    b.with(() => S().updateTab(Object.values(S().tabs).find((t) => urlOf(t) === "https://tile.example/").id, { customTitle: "Renamed" }));
    await b.sync();
    let n;
    a.beforePinApply = () => {
      n = S().newTab(w, { url: "https://new-member.example/", background: true });
      S().addTabsToGroup(g, [n]);
    };
    await a.sync();
    assert.ok(n);
    assert.deepEqual(a.with(() => S().groups[g]?.tabIds.map((id) => urlOf(S().tabs[id])).sort()), ["https://member.example/", "https://new-member.example/"]);
  });
}

const memberUrls = (device, g) => device.with(() => (S().groups[g]?.tabIds ?? []).map((id) => urlOf(S().tabs[id])).sort());
const addLocalMember = (device, w, g) => {
  let n;
  device.beforePinApply = () => {
    n = S().newTab(w, { url: "https://new-member.example/", background: true });
    S().addTabsToGroup(g, [n]);
  };
  return () => n;
};

for (const on of [false, true]) {
  test(`a member unpinned on another Mac still leaves the group while a local member joins it, redesign ${on}`, async () => {
    syncRedesign.on = on;
    const { a, b, w, m, g } = setUp();
    a.with(() => S().addTabsToGroup(g, [S().newTab(w, { url: "https://stays.example/", background: true })]));
    await syncAll([a, b]);
    b.with(() => S().removeTabsFromGroup([m]));
    await b.sync();
    const n = addLocalMember(a, w, g);
    await a.sync();
    assert.ok(n());
    assert.deepEqual(memberUrls(a, g), ["https://new-member.example/", "https://stays.example/"]);
  });

  test(`a member moved to another pinned group on another Mac lands there while a local member joins the old one, redesign ${on}`, async () => {
    syncRedesign.on = on;
    const { a, b, w, m, g } = setUp();
    a.with(() => S().addTabsToGroup(g, [S().newTab(w, { url: "https://stays.example/", background: true })]));
    await syncAll([a, b]);
    const h = b.with(() => {
      const bw = Object.values(S().windows).find((x) => x.tabIds.includes(m)).id;
      const other = S().newTab(bw, { url: "https://other-member.example/", background: true });
      const made = S().groupTabs([other], { pinned: true, name: "Other" });
      S().placeTabs([m], { pinned: false, groupId: made });
      return made;
    });
    await b.sync();
    const n = addLocalMember(a, w, g);
    await a.sync();
    assert.ok(n());
    assert.deepEqual(memberUrls(a, g), ["https://new-member.example/", "https://stays.example/"]);
    assert.ok(memberUrls(a, h).some((url) => url === "https://member.example/"), "m is in h");
  });

  test(`a pinned group deleted on another Mac leaves a member added locally after the view froze as a pinned tile, redesign ${on}`, async () => {
    syncRedesign.on = on;
    const { a, b, w, g } = setUp();
    await syncAll([a, b]);
    b.with(() => S().deleteGroup(g));
    await b.sync();
    const n = addLocalMember(a, w, g);
    await a.sync();
    assert.ok(n());
    const tile = a.with(() => S().tabs[n()]);
    assert.equal(tile?.pinned, true, "n stays in the pinned area as a tile");
    assert.equal(tile?.pinnedUrl, "https://new-member.example/");
    assert.equal(a.with(() => S().groups[g]), undefined, "the other Mac's delete stands");
    await syncAll([a, b]);
    assert.ok(b.with(() => Object.values(S().tabs).some((t) => t.pinned && urlOf(t) === "https://new-member.example/")), "the tile reaches the other Mac");
    assert.equal(b.with(() => S().groups[g]), undefined, "and the group stays deleted there");
  });
}

for (const on of [false, true]) {
  test(`a pinned group deleted on another Mac parks a member added locally after the view froze as a pinned tile when its window then closed, redesign ${on}`, async () => {
    syncRedesign.on = on;
    const { a, b, w, g } = setUp();
    await syncAll([a, b]);
    b.with(() => S().deleteGroup(g));
    await b.sync();
    let n;
    a.beforePinApply = () => {
      n = S().newTab(w, { url: "https://new-member.example/", background: true });
      S().addTabsToGroup(g, [n]);
      S().closeWindow(w);
    };
    await a.sync();
    assert.ok(n);
    const parked = a.with(() => S().parkedPins.default);
    const tile = (parked?.tabs ?? []).find((t) => urlOf(t) === "https://new-member.example/");
    assert.equal(tile?.pinned, true, "n is parked as a pinned tile");
    assert.equal(tile?.groupId ?? null, null);
    assert.equal((parked?.groups ?? []).some((x) => x.id === g), false, "the other Mac's delete stands");
  });
}

const groupNamed = (device, name) => device.with(() => Object.values(S().groups).find((x) => x.pinned && x.name === name));
const urlsIn = (device, name) => device.with(() => (groupNamed(device, name)?.tabIds ?? []).map((id) => urlOf(S().tabs[id])).sort());

function nestedSetUp() {
  const folder = new Folder();
  const a = new Device("devA", folder);
  const b = new Device("devB", folder);
  const made = a.with(() => {
    const w = S().createWindow({ url: "https://home.example/" });
    const work = S().createProfile({ name: "Work" });
    S().createWindow({ url: "https://other.example/", profileId: work });
    const open = (h) => S().newTab(w, { url: `https://${h}.example/`, background: true });
    const [o1, i1] = ["outer", "inner"].map(open);
    const outer = S().groupTabs([o1, i1], { pinned: true, name: "Outer" });
    const inner = S().groupTabs([i1], { name: "Inner" });
    return { w, outer, inner };
  });
  b.with(() => S().createWindow({ url: "https://b-home.example/" }));
  return { folder, a, b, ...made };
}

function addToInner(device, w, inner) {
  let n;
  device.beforePinApply = () => {
    n = S().newTab(w, { url: "https://new-member.example/", background: true });
    S().addTabsToGroup(inner, [n]);
  };
  return () => n;
}

for (const on of [false, true]) {
  test(`a tab added to a nested group after the view froze stays in it and its parent, redesign ${on}`, async () => {
    syncRedesign.on = on;
    const { a, b, w, inner } = nestedSetUp();
    await syncAll([a, b]);
    b.with(() => S().updateGroup(groupNamed(b, "Outer").id, { name: "Outer renamed" }));
    await b.sync();
    const n = addToInner(a, w, inner);
    await a.sync();
    assert.ok(n());
    assert.deepEqual(urlsIn(a, "Inner"), ["https://inner.example/", "https://new-member.example/"]);
    assert.deepEqual(urlsIn(a, "Outer renamed"), ["https://inner.example/", "https://new-member.example/", "https://outer.example/"]);
  });

  test(`a tab added to a nested group another Mac detached stays only in that group, and deleting the old parent leaves it, redesign ${on}`, async () => {
    syncRedesign.on = on;
    const { a, b, w, inner } = nestedSetUp();
    await syncAll([a, b]);
    b.with(() => S().moveGroup(groupNamed(b, "Inner").id, { pinned: true, parentId: null }));
    await b.sync();
    const n = addToInner(a, w, inner);
    await a.sync();
    assert.ok(n());
    assert.equal(groupNamed(a, "Inner").parentId, undefined, "the detach arrived");
    assert.deepEqual(urlsIn(a, "Inner"), ["https://inner.example/", "https://new-member.example/"]);
    assert.deepEqual(urlsIn(a, "Outer"), ["https://outer.example/"], "not kept in the old parent");
    a.with(() => S().deleteGroup(groupNamed(a, "Outer").id));
    assert.deepEqual(urlsIn(a, "Inner"), ["https://inner.example/", "https://new-member.example/"]);
  });

  test(`a parent deleted on another Mac that kept its detached child leaves a tab added to the child in the child, redesign ${on}`, async () => {
    syncRedesign.on = on;
    const { a, b, w, inner } = nestedSetUp();
    await syncAll([a, b]);
    b.with(() => {
      S().moveGroup(groupNamed(b, "Inner").id, { pinned: true, parentId: null });
      S().ungroup(groupNamed(b, "Outer").id);
    });
    await b.sync();
    const n = addToInner(a, w, inner);
    await a.sync();
    assert.ok(n());
    assert.equal(groupNamed(a, "Outer"), undefined, "the delete stands");
    assert.deepEqual(urlsIn(a, "Inner"), ["https://inner.example/", "https://new-member.example/"]);
    assert.equal(a.with(() => S().tabs[n()].pinned), false, "not turned into a tile");
  });

  test(`a tab placed before or between a pinned group's members after the view froze keeps its place, redesign ${on}`, async () => {
    syncRedesign.on = on;
    const { a, b, w, m, g } = setUp();
    let k;
    a.with(() => {
      k = S().newTab(w, { url: "https://last.example/", background: true });
      S().addTabsToGroup(g, [k]);
    });
    await syncAll([a, b]);
    b.with(() => S().updateTab(Object.values(S().tabs).find((t) => urlOf(t) === "https://tile.example/").id, { customTitle: "Renamed" }));
    await b.sync();
    let first, between;
    a.beforePinApply = () => {
      first = S().newTab(w, { url: "https://first.example/", background: true });
      between = S().newTab(w, { url: "https://between.example/", background: true });
      S().placeTabs([first], { pinned: false, groupId: g, beforeId: m });
      S().placeTabs([between], { pinned: false, groupId: g, beforeId: k });
    };
    await a.sync();
    assert.ok(first && between);
    assert.deepEqual(a.with(() => S().groups[g].tabIds), [first, m, between, k]);
  });

  test(`a member added after the view froze to a group deleted elsewhere keeps its pinned page, not the page it shows, as the tile's home, redesign ${on}`, async () => {
    syncRedesign.on = on;
    const { a, b, w, g } = setUp();
    await syncAll([a, b]);
    b.with(() => S().deleteGroup(g));
    await b.sync();
    let n;
    a.beforePinApply = () => {
      n = S().newTab(w, { url: "https://new-member.example/", background: true });
      S().addTabsToGroup(g, [n]);
      useBrowser.setState((s) => ({ tabs: { ...s.tabs, [n]: { ...s.tabs[n], url: "https://elsewhere.example/" } } }));
    };
    await a.sync();
    assert.equal(a.with(() => S().tabs[n].url), "https://elsewhere.example/");
    assert.equal(a.with(() => S().tabs[n].pinnedUrl), "https://new-member.example/");
    assert.equal(a.with(() => S().tabs[n].pinned), true);
  });

  for (const edit of ["removal", "move"]) {
    test(`known residual: a member's local ${edit} after the view froze is undone by a view that lists it, redesign ${on}`, { todo: "the frozen view's placement of a key it already knows still wins over a later local edit (docs/sync.md)" }, async () => {
      syncRedesign.on = on;
      const { a, b, w, m, g } = setUp();
      let h;
      a.with(() => {
        const other = S().newTab(w, { url: "https://other-group.example/", background: true });
        h = S().groupTabs([other], { pinned: true, name: "H" });
      });
      await syncAll([a, b]);
      b.with(() => S().updateTab(Object.values(S().tabs).find((t) => urlOf(t) === "https://tile.example/").id, { customTitle: "Renamed" }));
      await b.sync();
      a.beforePinApply = () => (edit === "move" ? S().placeTabs([m], { pinned: false, groupId: h }) : S().removeTabsFromGroup([m]));
      await a.sync();
      assert.equal(a.with(() => S().groups[g]?.tabIds.includes(m)), false);
      if (edit === "move") assert.equal(a.with(() => S().groups[h]?.tabIds.includes(m)), true);
    });
  }
}

for (const on of [false, true]) {
  for (const closed of [false, true]) {
    test(`a tab added to a nested group the view moved under another group, with no tab record left in it, follows the view's nesting${closed ? " and parks with it" : ""}, redesign ${on}`, async () => {
      syncRedesign.on = on;
      const folder = new Folder();
      const a = new Device("devA", folder);
      const b = new Device("devB", folder);
      const made = a.with(() => {
        const w = S().createWindow({ url: "https://home.example/" });
        const work = S().createProfile({ name: "Work" });
        S().createWindow({ url: "https://other.example/", profileId: work });
        const open = (h) => S().newTab(w, { url: `https://${h}.example/`, background: true });
        const [x, y, c, d] = ["a", "b", "c", "d"].map(open);
        const ga = S().groupTabs([x, y, c], { pinned: true, name: "A" });
        const gb = S().groupTabs([y, c], { name: "B" });
        const gc = S().groupTabs([c], { name: "C" });
        const gd = S().groupTabs([d], { pinned: true, name: "D" });
        return { w, c, ga, gb, gc, gd };
      });
      b.with(() => S().createWindow({ url: "https://b-home.example/" }));
      await syncAll([a, b]);
      b.with(() => S().updateTab(Object.values(S().tabs).find((t) => urlOf(t) === "https://d.example/").id, { customTitle: "Renamed" }));
      await b.sync();
      a.rewriteView = (visible, changed) => {
        for (const k of [`pin:t:${made.c}`, `pinn:t:${made.c}`]) {
          visible.delete(k);
          changed.add(k);
        }
        visible.set(`pinn:g:${made.gc}`, { ...visible.get(`pinn:g:${made.gc}`), p: made.gd });
        changed.add(`pinn:g:${made.gc}`);
      };
      let n;
      a.beforePinApply = () => {
        n = S().newTab(made.w, { url: "https://new-member.example/", background: true });
        S().addTabsToGroup(made.gc, [n]);
        if (closed) S().closeWindow(made.w);
      };
      await a.sync();
      assert.ok(n);
      if (closed) {
        const parked = a.with(() => S().parkedPins.default);
        const tab = parked.tabs.find((t) => urlOf(t) === "https://new-member.example/");
        assert.equal(tab?.groupId, made.gc, "parked in C");
        assert.equal(parked.groups.find((g) => g.id === made.gc)?.parentId, made.gd, "C parked under D");
        return;
      }
      const groupsOf = (id) => a.with(() => Object.values(S().groups).filter((g) => g.tabIds.includes(id)).map((g) => g.name).sort());
      assert.deepEqual(groupsOf(n), ["C", "D"]);
      assert.equal(a.with(() => S().groups[made.gc].parentId), made.gd);
      a.with(() => S().deleteGroup(made.ga));
      assert.ok(a.with(() => S().tabs[n]), "deleting the old ancestor leaves the tab");
      assert.deepEqual(groupsOf(n), ["C", "D"]);
    });
  }
}

for (const on of [false, true]) {
  for (const [where, closed] of [["under the old parent", false], ["under the old parent", true], ["as a new root", false]]) {
    test(`a tab added to a group another Mac detached, after this Mac moved it into a new group ${where}, stays only in the detached group${closed ? " and parks there" : ""}, redesign ${on}`, async () => {
      syncRedesign.on = on;
      const { a, b, w, outer, inner } = nestedSetUp();
      await syncAll([a, b]);
      b.with(() => S().moveGroup(groupNamed(b, "Inner").id, { pinned: true, parentId: null }));
      await b.sync();
      let n, x;
      a.beforePinApply = () => {
        if (where === "as a new root") {
          const seed = S().newTab(w, { url: "https://seed.example/", background: true });
          x = S().groupTabs([seed], { pinned: true, name: "X" });
        } else {
          x = S().newNestedGroup(outer);
          S().updateGroup(x, { name: "X" });
        }
        S().moveGroup(inner, { pinned: true, parentId: x });
        n = S().newTab(w, { url: "https://new-member.example/", background: true });
        S().addTabsToGroup(inner, [n]);
        assert.ok(S().groups[x].tabIds.includes(n), "locally, X holds the tab through Inner");
        if (closed) S().closeWindow(w);
      };
      await a.sync();
      assert.ok(n && x);
      if (closed) {
        const parked = a.with(() => S().parkedPins.default);
        assert.equal(parked.tabs.find((t) => urlOf(t) === "https://new-member.example/")?.groupId, inner, "parked in Inner");
        assert.equal(parked.groups.find((g) => g.id === inner)?.parentId ?? null, null, "Inner parks detached");
        return;
      }
      const groupsOf = () => a.with(() => Object.values(S().groups).filter((g) => g.tabIds.includes(n)).map((g) => g.name).sort());
      assert.deepEqual(groupsOf(), ["Inner"]);
      assert.equal(a.with(() => S().groups[inner].parentId), undefined);
      if (a.with(() => S().groups[x])) a.with(() => S().deleteGroup(x));
      assert.ok(a.with(() => S().tabs[n]), "deleting X leaves the tab");
      assert.deepEqual(groupsOf(), ["Inner"]);
    });
  }
}
