import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";

const { useBrowser } = await import("../../store/browser.ts");
const { applyResult, applySafari, emptyCounts } = await import("./apply.ts");
const { isBookmarkConditionFailure, projectNativeBookmarks } = await import("../../lib/bookmarkWriter.ts");

const S = () => useBrowser.getState();
const folder = (id, title, children = []) => ({ kind: "folder", id, parentId: null, title, children, addedAt: 0 });
let engines = 0;

class FakeOwner {
  constructor() {
    this.engine = `import-${++engines}`;
    this.revision = 1;
    this.bar = `bar@${this.engine}`;
    this.other = `other@${this.engine}`;
    this.document = { nodes: { [this.bar]: folder(this.bar, "Bookmarks Bar"), [this.other]: folder(this.other, "Other Bookmarks") }, roots: { default: { bar: this.bar, other: this.other } } };
    this.submitted = [];
    this.refuse = null;
    this.ids = 0;
  }
  state() {
    return { state: "owned", generation: "1" };
  }
  snapshot() {
    return { engine: this.engine, generation: "1", revision: String(this.revision), ready: true, document: JSON.stringify(this.document) };
  }
  async submit(_profileId, mutationsJSON) {
    const mutations = JSON.parse(mutationsJSON);
    this.submitted.push(mutations);
    if (this.refuse) throw this.refuse;
    this.beforeAccept?.();
    const nodes = this.document.nodes;
    for (const { method, args } of mutations) {
      if (method !== "expectChildren") continue;
      const [, folderId, children] = args;
      if (JSON.stringify(nodes[folderId]?.children) !== JSON.stringify(children)) throw new Error(`bookmark replacement refused: conditionFailed("${folderId}")`);
    }
    const build = (draft, parentId) => {
      const id = `n${++this.ids}`;
      nodes[id] = draft.children ? { ...folder(id, draft.title), parentId } : { kind: "url", id, parentId, title: draft.title, url: draft.url, favicon: null, addedAt: 1 };
      if (draft.children) nodes[id].children = draft.children.map((child) => build(child, id));
      return id;
    };
    const results = mutations.map(({ method, args }) => {
      if (method === "expectChildren") return true;
      assert.equal(method, "addBookmarkTree");
      const [, drafts, parentId = this.bar] = args;
      const ids = drafts.map((draft) => build(draft, parentId));
      nodes[parentId].children.push(...ids);
      return ids;
    });
    this.revision += 1;
    return { engine: this.engine, revision: String(this.revision), results: JSON.stringify(results), document: JSON.stringify(this.document) };
  }
}

const imported = {
  type: "folder",
  title: "",
  children: [
    { type: "folder", role: "toolbar", title: "Bookmarks Bar", children: [{ type: "url", title: "Bar link", url: "https://bar.example/" }] },
    { type: "folder", role: "other", title: "Other", children: [{ type: "folder", title: "Reading", children: [{ type: "url", title: "Article", url: "https://read.example/" }] }] },
  ],
};
const result = { bookmarks: imported, favorites: [], tabs: [], spaces: [], history: [], credentials: [], favicons: [], failed: [], warnings: [] };
const safari = { bookmarks: imported, profiles: [], tabs: [], credentials: [] };

const own = () => {
  useBrowser.setState({ bookmarks: { nodes: {}, roots: {} } });
  const owner = (globalThis.acTestBookmarkWriter = new FakeOwner());
  const snapshot = owner.snapshot();
  projectNativeBookmarks(snapshot.engine, snapshot.revision, snapshot.document);
  return owner;
};
const titles = (ids) => ids.map((id) => S().bookmarks.nodes[id]?.title);

beforeEach(() => {
  delete globalThis.acTestBookmarkWriter;
  S().hydrate({ bookmarks: { nodes: {}, roots: {} } });
});
afterEach(() => {
  delete globalThis.acTestBookmarkWriter;
});

test("an owned import is one submission, and the accepted tree is what the store shows", async () => {
  const owner = own();
  const counts = await applyResult("default", result, "Chrome", ["bookmarks"]);
  assert.equal(counts.bookmarks, 2);
  assert.deepEqual(owner.submitted.map((batch) => batch.map((m) => [m.method, m.method === "expectChildren" ? m.args[1] : m.args[2]])), [[["expectChildren", owner.bar], ["expectChildren", owner.other], ["addBookmarkTree", owner.bar], ["addBookmarkTree", owner.other]]]);
  assert.deepEqual(titles(S().bookmarks.nodes[owner.bar].children), ["Bar link"]);
  assert.deepEqual(titles(S().bookmarks.nodes[owner.other].children), ["Reading"]);
});

test("an owned import into a bar that has bookmarks goes in an Imported folder", async () => {
  globalThis.acTestBookmarkWriter = undefined;
  const owner = new FakeOwner();
  owner.document.nodes.seed = { kind: "url", id: "seed", parentId: owner.bar, title: "Seed", url: "https://seed.example/", favicon: null, addedAt: 0 };
  owner.document.nodes[owner.bar].children.push("seed");
  useBrowser.setState({ bookmarks: { nodes: {}, roots: {} } });
  globalThis.acTestBookmarkWriter = owner;
  projectNativeBookmarks(owner.engine, String(owner.revision), JSON.stringify(owner.document));
  await applySafari("default", safari, false);
  assert.deepEqual(titles(S().bookmarks.nodes[owner.bar].children), ["Seed", "Imported from Safari"]);
  assert.equal(owner.submitted.length, 1, "through the writer");
});

test("a refused import counts nothing, changes nothing and reports bookmarks as failed", async () => {
  const owner = own();
  owner.refuse = new Error("journal write failed");
  const failed = [];
  const counts = await applyResult("default", result, "Chrome", ["bookmarks"], (kind) => failed.push(kind));
  assert.equal(counts.bookmarks, 0);
  assert.deepEqual(failed, ["bookmarks"]);
  assert.deepEqual(S().bookmarks.nodes[owner.bar]?.children ?? [], []);
  const safariFailed = [];
  const safariCounts = await applySafari("default", safari, false, (kind) => safariFailed.push(kind));
  assert.deepEqual([safariCounts.bookmarks, safariFailed], [0, ["bookmarks"]]);
});

test("a legacy import still fills empty roots directly and counts every link", async () => {
  const counts = await applyResult("default", result, "Chrome", ["bookmarks"]);
  assert.deepEqual({ ...emptyCounts(), bookmarks: 2 }, { ...counts, history: 0 });
  const roots = S().bookmarks.roots.default;
  assert.deepEqual(titles(S().bookmarks.nodes[roots.bar].children), ["Bar link"]);
  assert.deepEqual(titles(S().bookmarks.nodes[roots.other].children), ["Reading"]);
  await applyResult("default", result, "Chrome", ["bookmarks"]);
  assert.deepEqual(titles(S().bookmarks.nodes[roots.bar].children), ["Bar link", "Imported from Chrome"]);
});

test("two owned imports started together still put the second in an Imported folder", async () => {
  const owner = own();
  let release;
  const gate = new Promise((resolve) => (release = resolve));
  const submit = owner.submit.bind(owner);
  owner.submit = async (...args) => {
    await gate;
    return submit(...args);
  };
  const first = applyResult("default", result, "Chrome", ["bookmarks"]);
  const second = applySafari("default", safari, false);
  await new Promise((resolve) => setTimeout(resolve, 10));
  release();
  await Promise.all([first, second]);
  assert.deepEqual(titles(S().bookmarks.nodes[owner.bar].children), ["Bar link", "Imported from Safari"]);
});

test("a native edit landing between the choice and acceptance sends the import into an Imported folder", async () => {
  const owner = own();
  owner.beforeAccept = () => {
    owner.beforeAccept = null;
    owner.document.nodes.seed = { kind: "url", id: "seed", parentId: owner.bar, title: "Seed", url: "https://seed.example/", favicon: null, addedAt: 0 };
    owner.document.nodes[owner.bar].children.push("seed");
    owner.revision += 1;
  };
  const counts = await applyResult("default", result, "Chrome", ["bookmarks"]);
  assert.equal(counts.bookmarks, 2);
  assert.deepEqual(titles(S().bookmarks.nodes[owner.bar].children), ["Seed", "Imported from Chrome"]);
  assert.deepEqual(titles(S().bookmarks.nodes[owner.other].children), ["Reading"]);
  assert.equal(owner.submitted.length, 2, "refused once, then re-planned");
  assert.deepEqual(owner.submitted[0].filter((m) => m.method === "expectChildren").map((m) => m.args.slice(1)), [[owner.bar, []], [owner.other, []]]);
});


test("the writer recognises exactly the pod's wording of a failed condition", () => {
  assert.equal(isBookmarkConditionFailure(new Error('bookmark replacement refused: conditionFailed("bar@default")')), true);
  assert.equal(isBookmarkConditionFailure(new Error("Call to function 'SolaraBookmarks.submit' has been rejected.\n→ Caused by: bookmark replacement refused: conditionFailed(\"bar@default\")")), true);
  assert.equal(isBookmarkConditionFailure(new Error("bookmark replacement refused: staleRevision")), false);
  assert.equal(isBookmarkConditionFailure(new Error('bookmark replacement refused: invalidOperation("conditionFailed")')), false);
  assert.equal(isBookmarkConditionFailure(new Error("the bookmark owner changed since this binding was taken")), false);
});
