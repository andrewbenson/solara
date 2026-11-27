import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, afterEach, beforeEach, test } from "node:test";

const actionsURL = new URL("../../lib/actions.ts", import.meta.url).href;
const browserURL = new URL("../../store/browser.ts", import.meta.url).href;
const fake = (source) => ({ url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true });
const hooks = registerHooks({
  resolve(specifier, context, next) {
    const resolved = next(specifier, context);
    if (resolved.url === actionsURL) return fake(`import { useBrowser } from ${JSON.stringify(browserURL)}; export const focus = (id) => useBrowser.getState().setFocusedWindow(id); export const openWindow = (options) => useBrowser.getState().createWindow(options);`);
    return resolved;
  },
});
after(() => hooks.deregister());
const { useBrowser } = await import("../../store/browser.ts");
const { bookmarkWriter } = await import("../../lib/bookmarkWriter.ts");
const { bookmarkTabs } = await import("../sidebar/actions.ts");

const { seedBookmarkProjection, nextBookmarkProjectionOwner } = await import("../../test-native/bookmarkProjection.ts");
const S = () => useBrowser.getState();
const folder = (id, title, children = []) => ({ kind: "folder", id, parentId: null, title, children, addedAt: 0 });
let engines = 0;

class FakeOwner {
  constructor() {
    this.engine = `forms-${++engines}`;
    this.projectionOwner = nextBookmarkProjectionOwner();
    this.generation = "1";
    this.revision = 1;
    this.document = { nodes: { [`bar@${this.engine}`]: folder(`bar@${this.engine}`, "Bookmarks Bar"), [`other@${this.engine}`]: folder(`other@${this.engine}`, "Other Bookmarks") }, roots: { default: { bar: `bar@${this.engine}`, other: `other@${this.engine}` } } };
    this.submitted = [];
    this.refuse = null;
    this.hold = null;
    this.ids = 0;
  }
  get bar() {
    return `bar@${this.engine}`;
  }
  projection() {
    const snapshot = this.snapshot();
    return { owner: this.projectionOwner, generation: snapshot.generation, profiles: { default: { engine: snapshot.engine, generation: snapshot.generation } }, views: { [snapshot.engine]: { revision: snapshot.revision, hasView: true, readyForSync: snapshot.ready, document: JSON.parse(snapshot.document) } } };
  }
  state() {
    return { state: "owned", generation: this.generation };
  }
  snapshot() {
    return { engine: this.engine, generation: this.generation, revision: String(this.revision), ready: true, document: JSON.stringify(this.document) };
  }
  async submit(profileId, mutationsJSON) {
    const mutations = JSON.parse(mutationsJSON);
    this.submitted.push(mutations);
    if (this.hold) await this.hold;
    if (this.refuse) throw this.refuse;
    const nodes = this.document.nodes;
    const results = mutations.map(({ method, args }) => {
      if (method === "addBookmark" || method === "addBookmarkFolder") {
        const id = `n${++this.ids}`;
        const parent = args[0].parentId ?? this.bar;
        nodes[id] = method === "addBookmark" ? { kind: "url", id, parentId: parent, title: args[0].title, url: args[0].url, favicon: null, addedAt: 1 } : folder(id, args[0].title);
        if (method === "addBookmarkFolder") nodes[id].parentId = parent;
        nodes[parent].children.push(id);
        return id;
      }
      if (method === "updateBookmark") Object.assign(nodes[args[0]], args[1]);
      if (method === "moveBookmark") {
        const node = nodes[args[0]];
        nodes[node.parentId].children = nodes[node.parentId].children.filter((id) => id !== node.id);
        node.parentId = args[1];
        nodes[args[1]].children.push(node.id);
      }
      if (method === "removeBookmark") {
        const node = nodes[args[0]];
        nodes[node.parentId].children = nodes[node.parentId].children.filter((id) => id !== node.id);
        delete nodes[args[0]];
      }
      return null;
    });
    this.revision += 1;
    return { engine: this.engine, revision: String(this.revision), results: JSON.stringify(results), document: JSON.stringify(this.document) };
  }
}

let windowId;
beforeEach(() => {
  delete globalThis.acTestBookmarkWriter;
  seedBookmarkProjection(useBrowser);
  S().hydrate({ groups: {}, windows: {}, tabs: {}, splits: {} });
  windowId = S().createWindow();
});
afterEach(() => {
  delete globalThis.acTestBookmarkWriter;
});

const own = () => {
  seedBookmarkProjection(useBrowser);
  return (globalThis.acTestBookmarkWriter = new FakeOwner());
};

test("Bookmark Tabs into a new folder sends the folder, then every tab in one batch under its accepted id", async () => {
  const owner = own();
  const first = S().windows[windowId].activeTabIds.default;
  S().navigate(first, "https://one.example/");
  const second = S().newTab(windowId, { url: "https://two.example/" });
  const third = S().newTab(windowId, { url: "https://three.example/" });
  const shell = (await import("../../test-native/shell.ts")).shellNativeModules.SolaraShell;
  const prompt = shell.prompt;
  shell.prompt = () => Promise.resolve("Saved");
  try {
    await bookmarkTabs(windowId, [first, second, third], "new");
  } finally {
    shell.prompt = prompt;
  }
  assert.deepEqual(owner.submitted.map((batch) => batch.map((m) => m.method)), [["addBookmarkFolder"], ["addBookmark", "addBookmark", "addBookmark"]]);
  assert.ok(owner.submitted[1].every((m) => m.args[0].parentId === "n1"));
});

test("a second bookmark toggle while the first is pending is the same toggle, not an undo", async () => {
  const { toggleBookmarkFromUI } = await import("../../lib/bookmarkWriter.ts");
  const owner = own();
  owner.submit = async function (profileId, mutationsJSON) {
    this.submitted.push(JSON.parse(mutationsJSON));
    await new Promise((resolve) => setTimeout(resolve, 20));
    this.revision += 1;
    return { engine: this.engine, revision: String(this.revision), results: JSON.stringify([true]), document: JSON.stringify(this.document) };
  };
  const page = { url: "https://page.example/", title: "Page", favicon: null };
  const first = toggleBookmarkFromUI("default", page);
  const second = toggleBookmarkFromUI("default", page);
  assert.equal(await first, true);
  assert.equal(await second, true);
  assert.equal(owner.submitted.length, 1);
  await toggleBookmarkFromUI("default", page);
  assert.equal(owner.submitted.length, 2, "a toggle after the first lands is a new one");
});

test("a refused write from Bookmark Tabs or the bar menu is reported", async () => {
  const { handleBookmarksBarMenuChoice } = await import("./bookmarksBarActions.ts");
  const owner = own();
  const id = await bookmarkWriter.addBookmark({ profileId: "default", title: "Page", url: "https://page.example/" });
  owner.refuse = new Error("journal write failed");
  const warned = [];
  const warn = console.warn;
  console.warn = (...args) => warned.push(args);
  try {
    const tabId = S().windows[windowId].activeTabIds.default;
    S().navigate(tabId, "https://tab.example/");
    await bookmarkTabs(windowId, [tabId], "bar");
    await handleBookmarksBarMenuChoice(windowId, "default", "delete", id);
  } finally {
    console.warn = warn;
  }
  assert.equal(warned.length, 2);
});

test("Bookmark Tabs passes a native folder id through before its JS replica arrives", async () => {
  const owner = own();
  const first = S().windows[windowId].activeTabIds.default;
  S().navigate(first, "https://one.example/");
  const ids = [first, S().newTab(windowId, { url: "https://two.example/" }), S().newTab(windowId, { url: "https://three.example/" })];
  const target = "native-only-folder";
  owner.document.nodes[target] = { ...folder(target, "Arrived in Swift"), parentId: owner.bar };
  owner.document.nodes[owner.bar].children.push(target);
  owner.revision += 1;
  assert.equal(S().bookmarks.nodes[target], undefined);
  await bookmarkTabs(windowId, ids, target);
  assert.deepEqual(owner.submitted.map((batch) => batch.map((mutation) => mutation.method)), [["addBookmark", "addBookmark", "addBookmark"]]);
  assert.ok(owner.submitted[0].every((mutation) => mutation.args[0].parentId === target));
  assert.deepEqual(owner.document.nodes[target].children.map((id) => owner.document.nodes[id].url), ["https://one.example/", "https://two.example/", "https://three.example/"]);
});
