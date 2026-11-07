import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { after, afterEach, beforeEach, test } from "node:test";

const actionsURL = new URL("../../lib/actions.ts", import.meta.url).href;
const formsURL = new URL("./NativeBookmarkForms.tsx", import.meta.url).href;
const browserURL = new URL("../../store/browser.ts", import.meta.url).href;
const fake = (source) => ({ url: `data:text/javascript,${encodeURIComponent(source)}`, shortCircuit: true });
const hooks = registerHooks({
  resolve(specifier, context, next) {
    const resolved = next(specifier, context);
    if (resolved.url === actionsURL) return fake(`import { useBrowser } from ${JSON.stringify(browserURL)}; export const focus = (id) => useBrowser.getState().setFocusedWindow(id); export const openWindow = (options) => useBrowser.getState().createWindow(options);`);
    if (resolved.url === formsURL) return fake("export const NativeBookmarkDialog = () => null; export const NativeBookmarkEditor = () => null;");
    return resolved;
  },
});
after(() => hooks.deregister());
const { useBrowser } = await import("../../store/browser.ts");
const { bookmarkWriter } = await import("../../lib/bookmarkWriter.ts");
const { finishBookmarkDialog, removeDialogBookmark } = await import("./BookmarkDialog.tsx");
const { saveBookmarkEditor } = await import("./EditBookmarkDialog.tsx");
const { bookmarkTab, useBookmarkDialog } = await import("./actions.ts");
const { useBookmarkEditor } = await import("./edit.ts");
const { bookmarkTabs } = await import("../sidebar/actions.ts");

const S = () => useBrowser.getState();
const folder = (id, title, children = []) => ({ kind: "folder", id, parentId: null, title, children, addedAt: 0 });
let engines = 0;

class FakeOwner {
  constructor() {
    this.engine = `forms-${++engines}`;
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
  useBrowser.setState({ bookmarks: { nodes: {}, roots: {} } });
  S().hydrate({ groups: {}, windows: {}, tabs: {}, splits: {} });
  useBrowser.setState({ bookmarksReady: { default: true } });
  windowId = S().createWindow();
  useBookmarkDialog.getState().set(null);
  useBookmarkEditor.getState().set(null);
});
afterEach(() => {
  delete globalThis.acTestBookmarkWriter;
});

const own = () => {
  useBrowser.setState({ bookmarks: { nodes: {}, roots: {} } });
  return (globalThis.acTestBookmarkWriter = new FakeOwner());
};

test("a refused edit keeps the editor open with its draft, and a later save closes it", async () => {
  const owner = own();
  const id = await bookmarkWriter.addBookmark({ profileId: "default", title: "Page", url: "https://page.example/" });
  const editor = { windowId, bookmarkId: id, folder: false, profileId: "default" };
  useBookmarkEditor.getState().set(editor);
  owner.refuse = new Error("journal write failed");
  await assert.rejects(saveBookmarkEditor(editor, "Renamed", "https://page.example/", null), /journal/);
  assert.deepEqual(useBookmarkEditor.getState().open, editor, "the form stays open");
  assert.equal(S().bookmarks.nodes[id].title, "Page");
  owner.refuse = null;
  await saveBookmarkEditor(editor, "Renamed", "https://page.example/", null);
  assert.equal(useBookmarkEditor.getState().open, null);
  assert.equal(S().bookmarks.nodes[id].title, "Renamed");
});

test("a title change and a move from one form are one submission", async () => {
  const owner = own();
  const id = await bookmarkWriter.addBookmark({ profileId: "default", title: "Page", url: "https://page.example/" });
  const target = await bookmarkWriter.addBookmarkFolder({ profileId: "default", title: "Folder" });
  owner.submitted = [];
  await saveBookmarkEditor({ windowId, bookmarkId: id, folder: false, profileId: "default" }, "Renamed", "https://page.example/", target);
  assert.deepEqual(owner.submitted.map((batch) => batch.map((m) => m.method)), [["updateBookmark", "moveBookmark"]]);
  assert.equal(S().bookmarks.nodes[id].parentId, target);
  owner.submitted = [];
  useBookmarkDialog.getState().set({ kind: "page", windowId, bookmarkId: id });
  await finishBookmarkDialog({ kind: "page", windowId, bookmarkId: id }, "Again", owner.bar);
  assert.deepEqual(owner.submitted.map((batch) => batch.map((m) => m.method)), [["updateBookmark", "moveBookmark"]]);
  assert.equal(useBookmarkDialog.getState().open, null);
});

test("⌘D opens the bookmark dialog only once the new bookmark's id is accepted", async () => {
  const owner = own();
  const tabId = S().windows[windowId].activeTabIds.default;
  S().navigate(tabId, "https://tab.example/");
  let release;
  owner.hold = new Promise((resolve) => (release = resolve));
  const pending = bookmarkTab(windowId, tabId);
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(useBookmarkDialog.getState().open, null, "no dialog for an unaccepted bookmark");
  release();
  await pending;
  assert.deepEqual(useBookmarkDialog.getState().open, { kind: "page", windowId, bookmarkId: "n1" });
});

test("Bookmark Tabs into a new folder sends the folder, then every tab in one batch under its accepted id", async () => {
  const owner = own();
  const first = S().windows[windowId].activeTabIds.default;
  S().navigate(first, "https://one.example/");
  const second = S().newTab(windowId, { url: "https://two.example/" });
  const shell = (await import("../../test-native/shell.ts")).shellNativeModules.SolaraShell;
  const prompt = shell.prompt;
  shell.prompt = () => Promise.resolve("Saved");
  try {
    await bookmarkTabs(windowId, [first, second], "new");
  } finally {
    shell.prompt = prompt;
  }
  assert.deepEqual(owner.submitted.map((batch) => batch.map((m) => m.method)), [["addBookmarkFolder"], ["addBookmark", "addBookmark"]]);
  assert.ok(owner.submitted[1].every((m) => m.args[0].parentId === "n1"));
});

test("removing from the dialog goes through the writer before the dialog closes", async () => {
  const owner = own();
  const id = await bookmarkWriter.addBookmark({ profileId: "default", title: "Page", url: "https://page.example/" });
  useBookmarkDialog.getState().set({ kind: "page", windowId, bookmarkId: id });
  owner.refuse = new Error("journal write failed");
  await assert.rejects(removeDialogBookmark({ kind: "page", windowId, bookmarkId: id }), /journal/);
  assert.ok(useBookmarkDialog.getState().open, "a refused removal leaves the dialog open");
  owner.refuse = null;
  await removeDialogBookmark({ kind: "page", windowId, bookmarkId: id });
  assert.equal(S().bookmarks.nodes[id], undefined);
  assert.equal(useBookmarkDialog.getState().open, null);
});

test("without a native owner the forms still edit the JS store", async () => {
  const id = S().addBookmark({ profileId: "default", title: "Page", url: "https://page.example/" });
  await saveBookmarkEditor({ windowId, bookmarkId: id, folder: false, profileId: "default" }, "Renamed", "https://page.example/", null);
  assert.equal(S().bookmarks.nodes[id].title, "Renamed");
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

test("a refused write from ⌘D, Bookmark Tabs or the bar menu is reported, not thrown", async () => {
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
    await bookmarkTab(windowId, tabId);
    assert.equal(useBookmarkDialog.getState().open, null, "no dialog for a refused bookmark");
    await bookmarkTabs(windowId, [tabId], "bar");
    await handleBookmarksBarMenuChoice(windowId, "default", "delete", id);
  } finally {
    console.warn = warn;
  }
  assert.equal(warned.length, 3);
});

test("while a form's save is pending, Cancel and a second Save are ignored", async () => {
  const { formGate } = await import("./formGate.ts");
  const gate = formGate();
  let release;
  const events = [];
  const save = gate(true, () => new Promise((resolve) => (release = () => { events.push("saved"); resolve(); })));
  await gate(false, () => events.push("cancel"));
  await gate(true, () => events.push("second save"));
  release();
  await save;
  await gate(false, () => events.push("cancel after"));
  assert.deepEqual(events, ["saved", "cancel after"]);
});
