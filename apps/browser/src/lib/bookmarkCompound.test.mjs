import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";

const { useBrowser } = await import("../store/browser.ts");
const { bookmarkWriter, projectNativeBookmarks } = await import("./bookmarkWriter.ts");
const { moveGroupToBookmarksBar, restoreArcFolders } = await import("./bookmarkGroups.ts");

const { seedBookmarkProjection, nextBookmarkProjectionOwner } = await import("../test-native/bookmarkProjection.ts");
const S = () => useBrowser.getState();
const folder = (id, title, children = [], parentId = null) => ({ kind: "folder", id, parentId, title, children, addedAt: 0 });
let engines = 0;

class FakeOwner {
  projectionOwner = nextBookmarkProjectionOwner();
  constructor() {
    this.engine = `compound-${++engines}`;
    this.revision = 1;
    this.bar = `bar@${this.engine}`;
    this.other = `other@${this.engine}`;
    this.document = { nodes: { [this.bar]: folder(this.bar, "Bookmarks Bar"), [this.other]: folder(this.other, "Other Bookmarks") }, roots: { default: { bar: this.bar, other: this.other } } };
    this.submitted = [];
    this.refuse = null;
    this.hold = null;
    this.ids = 0;
  }
  projection() {
    const snapshot = this.snapshot();
    return { owner: this.projectionOwner, generation: snapshot.generation, profiles: { default: { engine: snapshot.engine, generation: snapshot.generation } }, views: { [snapshot.engine]: { revision: snapshot.revision, hasView: true, readyForSync: snapshot.ready, document: JSON.parse(snapshot.document) } } };
  }
  state() {
    return { state: "owned", generation: "1" };
  }
  snapshot() {
    return { engine: this.engine, generation: "1", revision: String(this.revision), ready: true, document: JSON.stringify(this.document) };
  }
  detach(id) {
    const node = this.document.nodes[id];
    const parent = this.document.nodes[node.parentId];
    parent.children = parent.children.filter((c) => c !== id);
    const drop = (n) => {
      if (n.kind === "folder") n.children.forEach((c) => drop(this.document.nodes[c]));
      delete this.document.nodes[n.id];
    };
    drop(node);
  }
  async submit(_profileId, mutationsJSON) {
    const mutations = JSON.parse(mutationsJSON);
    this.submitted.push(mutations);
    if (this.hold) await this.hold;
    if (this.refuse) throw this.refuse;
    const nodes = this.document.nodes;
    const add = (node) => {
      nodes[node.id] = node;
      nodes[node.parentId].children.push(node.id);
      return node.id;
    };
    const build = (draft, parentId) => {
      const id = `n${++this.ids}`;
      nodes[id] = draft.children ? folder(id, draft.title, [], parentId) : { kind: "url", id, parentId, title: draft.title, url: draft.url, favicon: null, addedAt: 1 };
      if (draft.children) nodes[id].children = draft.children.map((child) => build(child, id));
      return id;
    };
    const results = mutations.map(({ method, args }) => {
      if (method === "addBookmarkFolder") return add(folder(`n${++this.ids}`, args[0].title, [], args[0].parentId ?? this.bar));
      if (method === "addBookmark") return add({ kind: "url", id: `n${++this.ids}`, parentId: args[0].parentId ?? this.bar, title: args[0].title, url: args[0].url, favicon: args[0].favicon ?? null, addedAt: 1 });
      if (method === "addBookmarkTree") {
        const parentId = args[2] ?? this.bar;
        const ids = args[1].map((draft) => build(draft, parentId));
        nodes[parentId].children.push(...ids);
        return ids;
      }
      if (method === "updateBookmark") return void Object.assign(nodes[args[0]], args[1]);
      if (method === "removeBookmarks") return void args[0].forEach((id) => nodes[id] && this.detach(id));
      if (method === "removeBookmark") return void this.detach(args[0]);
      throw new Error(`unexpected ${method}`);
    });
    this.revision += 1;
    return { engine: this.engine, revision: String(this.revision), results: JSON.stringify(results), document: JSON.stringify(this.document) };
  }
}

let windowId;
let owner;
beforeEach(() => {
  delete globalThis.acTestBookmarkWriter;
  seedBookmarkProjection(useBrowser);
  S().hydrate({});
  windowId = S().createWindow({ url: "https://home.example/" });
  owner = globalThis.acTestBookmarkWriter = new FakeOwner();
  const snapshot = owner.snapshot();
  projectNativeBookmarks(snapshot.engine, snapshot.revision, snapshot.document);
});
afterEach(() => {
  delete globalThis.acTestBookmarkWriter;
});

const tick = () => new Promise((resolve) => setTimeout(resolve, 5));
const group = () => {
  const a = S().newTab(windowId, { url: "https://one.example/" });
  const b = S().newTab(windowId, { url: "https://two.example/" });
  S().updateTab(a, { favicon: "https://one.example/icon.png" });
  return S().createGroup([a, b], { name: "Saved" });
};
const urls = (id) => {
  const node = S().bookmarks.nodes[id];
  return node?.kind === "url" ? [node.url] : (node?.children ?? []).flatMap(urls);
};

test("filing a group to the bar is one submission and closes the group only once it is accepted", async () => {
  const groupId = group();
  let release;
  owner.hold = new Promise((resolve) => (release = resolve));
  const pending = moveGroupToBookmarksBar(groupId);
  await tick();
  assert.ok(S().groups[groupId], "the group stays open while the bookmarks are pending");
  void moveGroupToBookmarksBar(groupId);
  await tick();
  assert.equal(owner.submitted.length, 1, "a second tap while pending files nothing");
  owner.hold = null;
  release();
  await pending;
  assert.equal(owner.submitted[0].length, 1);
  assert.equal(owner.submitted[0][0].method, "addBookmarkTree");
  assert.equal(S().groups[groupId], undefined);
  const [filed] = S().bookmarks.nodes[owner.bar].children;
  assert.equal(S().bookmarks.nodes[filed].title, "Saved");
  assert.deepEqual(urls(filed), ["https://one.example/", "https://two.example/"]);
  await tick();
  const first = S().bookmarks.nodes[S().bookmarks.nodes[filed].children[0]];
  assert.equal(first.favicon, "https://one.example/icon.png", "favicons follow once the tree is accepted");
});

test("a refused filing keeps the group and makes no bookmarks", async () => {
  const groupId = group();
  owner.refuse = new Error("journal write failed");
  await assert.rejects(moveGroupToBookmarksBar(groupId), /journal/);
  assert.ok(S().groups[groupId], "the source group is kept");
  assert.deepEqual(S().bookmarks.nodes[owner.bar].children, []);
  owner.refuse = null;
  await moveGroupToBookmarksBar(groupId);
  assert.equal(S().groups[groupId], undefined, "and a retry files it");
});

const arcHolder = async () => {
  const holder = await bookmarkWriter.addBookmarkFolder({ profileId: "default", title: "Home (Arc)", parentId: owner.bar });
  const work = await bookmarkWriter.addBookmarkFolder({ profileId: "default", title: "Work", parentId: holder });
  await bookmarkWriter.addBookmark({ profileId: "default", url: "https://a.example/", title: "A", parentId: work });
  owner.submitted = [];
  return holder;
};

test("restoring Arc folders removes their bookmarks through the writer in one submission", async () => {
  const holder = await arcHolder();
  const made = restoreArcFolders(holder, windowId);
  assert.equal(made.length, 1);
  await tick();
  assert.deepEqual(owner.submitted.map((batch) => batch.map((m) => m.method)), [["removeBookmarks", "removeBookmark"]]);
  assert.equal(S().bookmarks.nodes[holder], undefined);
});

test("a refused Arc removal keeps the bookmarks, reports it, and a later restore can retry", async () => {
  const holder = await arcHolder();
  owner.refuse = new Error("journal write failed");
  const warned = [];
  const warn = console.warn;
  console.warn = (...args) => warned.push(args.map(String).join(" "));
  try {
    restoreArcFolders(holder, windowId);
    await tick();
  } finally {
    console.warn = warn;
  }
  assert.ok(S().bookmarks.nodes[holder], "the source bookmarks are kept");
  assert.equal(warned.length, 1);
  owner.refuse = null;
  restoreArcFolders(holder, windowId);
  await tick();
  assert.equal(S().bookmarks.nodes[holder], undefined);
});

test("a group that changes while its filing is pending is left open", async () => {
  const groupId = group();
  let release;
  owner.hold = new Promise((resolve) => (release = resolve));
  const pending = moveGroupToBookmarksBar(groupId);
  await tick();
  const late = S().newTab(windowId, { url: "https://late.example/" });
  S().addTabsToGroup(groupId, [late]);
  owner.hold = null;
  release();
  await pending;
  assert.ok(S().groups[groupId], "the group keeps the tab that was never filed");
  assert.ok(S().groups[groupId].tabIds.includes(late));
});

test("a retried Arc removal keeps what was added to a carried folder since", async () => {
  const holder = await arcHolder();
  const work = S().bookmarks.nodes[holder].children[0];
  owner.refuse = new Error("journal write failed");
  const warn = console.warn;
  console.warn = () => {};
  try {
    restoreArcFolders(holder, windowId);
    await tick();
  } finally {
    console.warn = warn;
  }
  owner.refuse = null;
  const kept = await bookmarkWriter.addBookmark({ profileId: "default", url: "javascript:void(0)", title: "Bookmarklet", parentId: work });
  restoreArcFolders(holder, windowId);
  await tick();
  assert.deepEqual(S().bookmarks.nodes[work]?.children, [kept], "the carried link goes, the new bookmarklet stays in Work");
});

test("waiting on a restore that is already removing waits for that removal", async () => {
  const { restoreArcFoldersSettled } = await import("./bookmarkGroups.ts");
  const holder = await arcHolder();
  let release;
  owner.hold = new Promise((resolve) => (release = resolve));
  restoreArcFolders(holder, windowId);
  let settled = false;
  const waiting = restoreArcFoldersSettled(holder, windowId).then(() => (settled = true));
  await tick();
  assert.equal(settled, false, "the second caller waits for the pending removal");
  owner.hold = null;
  release();
  await waiting;
  assert.equal(S().bookmarks.nodes[holder], undefined);
});

test("a retried Arc removal keeps a carried link whose URL changed since", async () => {
  const holder = await arcHolder();
  const work = S().bookmarks.nodes[holder].children[0];
  const [link] = S().bookmarks.nodes[work].children;
  owner.refuse = new Error("journal write failed");
  const warn = console.warn;
  console.warn = () => {};
  try {
    restoreArcFolders(holder, windowId);
    await tick();
  } finally {
    console.warn = warn;
  }
  owner.refuse = null;
  await bookmarkWriter.updateBookmark("default", link, { url: "javascript:void(0)" });
  await bookmarkWriter.addBookmark({ profileId: "default", url: "https://b.example/", title: "B", parentId: work });
  restoreArcFolders(holder, windowId);
  await tick();
  assert.ok(S().bookmarks.nodes[link], "the edited link was never carried, so it stays");
});
