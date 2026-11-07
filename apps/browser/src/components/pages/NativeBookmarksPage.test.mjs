import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";
import vm from "node:vm";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const source = readFileSync(new URL("./NativeBookmarksPage.tsx", import.meta.url), "utf8");

function harness() {
  const folder = (id, children = []) => ({ kind: "folder", id, parentId: null, title: id, children, addedAt: 0 });
  const bookmarks = { nodes: { bar: folder("bar", ["a", "b", "c"]), other: folder("other"), a: { kind: "url", id: "a", parentId: "bar" }, b: { kind: "url", id: "b", parentId: "bar" }, c: { kind: "url", id: "c", parentId: "bar" } }, roots: { one: { bar: "bar", other: "other" } } };
  const direct = () => {
    throw new Error("the page wrote to the store directly");
  };
  const state = { tabs: { t: { windowId: "w" } }, bookmarks, removeBookmarks: direct, restoreBookmarks: direct, moveBookmark: direct };
  const useBrowser = Object.assign((selector) => selector(state), { getState: () => state });
  const h = { submissions: [], failures: [], pending: [], props: null };
  const writer = (profileId, mutations) => {
    h.submissions.push([profileId, mutations]);
    let settle;
    const promise = new Promise((resolve, reject) => (settle = { resolve, reject }));
    h.pending.push(settle);
    return promise;
  };
  const cells = [];
  let cursor = 0;
  const react = {
    useState: (initial) => {
      const slot = cursor++;
      if (!(slot in cells)) cells[slot] = initial;
      return [cells[slot], (next) => (cells[slot] = typeof next === "function" ? next(cells[slot]) : next)];
    },
    useRef: (initial) => {
      const slot = cursor++;
      if (!(slot in cells)) cells[slot] = { current: initial };
      return cells[slot];
    },
    useMemo: (make) => (cursor++, make()),
    useEffect: (effect, deps) => {
      const slot = cursor++;
      const last = cells[slot];
      if (last && deps.every((dep, i) => Object.is(dep, last.deps[i]))) return;
      effects.push(() => {
        last?.cleanup?.();
        cells[slot] = { deps, cleanup: effect() };
      });
    },
  };
  const effects = [];
  const timers = new Map();
  let timerIds = 0;
  const clock = {
    setTimeout: (run) => (timers.set(++timerIds, run), timerIds),
    clearTimeout: (id) => timers.delete(id),
  };
  const mocks = {
    react,
    "react/jsx-runtime": { jsx: (_type, props) => (h.props = props), jsxs: (_type, props) => (h.props = props) },
    "react-native": { StyleSheet: { absoluteFill: {} } },
    "@solara/settings": { NativePage: () => null },
    "../../lib/bookmarkGroups": { addFolderToSidebar() {}, makesGroup: () => false, restorableArcHolder: () => false, restoreArcFolders() {} },
    "../../lib/bookmarkWriter": {
      submitBookmarks: writer,
      bookmarkWriter: {
        removeBookmarks: (profileId, ids) => writer(profileId, [{ method: "removeBookmarks", args: [ids] }]),
        restoreBookmarks: (profileId, removed) => writer(profileId, [{ method: "restoreBookmarks", args: [removed] }]),
      },
      reportBookmarkFailure: (error) => h.failures.push(String(error)),
    },
    "../../lib/theme": { useTheme: () => ({}) },
    "../../store/browser": { useBrowser },
    "../../store/model": { engineProfile: (id) => id },
    "../bookmarks/actions": { openFolder() {}, openUrl() {} },
    "../bookmarks/edit": { editBookmark() {} },
    "../settings/windows": { openImport() {} },
    "./nativePageTheme": { pageThemeState: () => ({}) },
  };
  const module = { exports: {} };
  const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } }).outputText;
  new vm.Script(code).runInNewContext({ exports: module.exports, module, require: (id) => mocks[id] ?? {}, ...clock });
  const { NativeBookmarksPage } = module.exports;
  h.render = () => {
    cursor = 0;
    NativeBookmarksPage({ tabId: "t", profileId: "one" });
    effects.splice(0).forEach((run) => run());
    return JSON.parse(h.props.state);
  };
  h.send = (event) => {
    h.render();
    h.props.onPageEvent({ nativeEvent: event });
  };
  h.settle = async (index, value, error) => {
    if (error) h.pending[index].reject(error);
    else h.pending[index].resolve(value);
    await new Promise((resolve) => setTimeout(resolve, 0));
  };
  h.expire = () => {
    h.render();
    const due = [...timers.values()];
    timers.clear();
    due.forEach((run) => run());
  };
  return h;
}

const plain = (value) => JSON.parse(JSON.stringify(value));
const removed = (ids) => ({ places: ids.map((id, index) => ({ id, parentId: "bar", index })), nodes: {} });

test("a delete offers Undo only once it is accepted, with the accepted record", async () => {
  const h = harness();
  h.send({ kind: "delete", ids: ["a", "b"] });
  assert.deepEqual(plain(h.submissions), [["one", [{ method: "removeBookmarks", args: [["a", "b"]] }]]]);
  assert.equal(h.render().undoCount, null, "no Undo while the delete is pending");
  const record = removed(["a", "b"]);
  await h.settle(0, record);
  assert.equal(h.render().undoCount, 2);
  h.send({ kind: "undo" });
  assert.equal(h.submissions[1][1][0].args[0], record, "Undo restores what the writer removed");
});

test("a refused delete offers no Undo and reports the failure", async () => {
  const h = harness();
  h.send({ kind: "delete", ids: ["a"] });
  await h.settle(0, null, new Error("journal write failed"));
  assert.equal(h.render().undoCount, null);
  assert.deepEqual(h.failures, ["Error: journal write failed"]);
});

test("a refused Undo stays offered and can be retried; a second tap while pending sends nothing", async () => {
  const h = harness();
  h.send({ kind: "delete", ids: ["a"] });
  await h.settle(0, removed(["a"]));
  h.send({ kind: "undo" });
  h.send({ kind: "undo" });
  assert.equal(h.submissions.length, 2, "one restore in flight at a time");
  await h.settle(1, null, new Error("refused"));
  assert.equal(h.render().undoCount, 1, "Undo is still offered");
  assert.deepEqual(h.failures, ["Error: refused"]);
  h.send({ kind: "undo" });
  assert.equal(h.submissions.length, 3);
  await h.settle(2, undefined);
  assert.equal(h.render().undoCount, null);
});

test("an Undo that lands after a newer delete keeps the newer Undo", async () => {
  const h = harness();
  h.send({ kind: "delete", ids: ["a"] });
  await h.settle(0, removed(["a"]));
  h.send({ kind: "undo" });
  h.send({ kind: "delete", ids: ["b", "c"] });
  await h.settle(2, removed(["b", "c"]));
  await h.settle(1, undefined);
  assert.equal(h.render().undoCount, 2);
});

test("moving several bookmarks is one submission, in order, with the index adjusted", async () => {
  const h = harness();
  h.send({ kind: "move", ids: ["a", "b"], into: "other" });
  h.send({ kind: "move", ids: ["a", "b"], parentId: "bar", index: 3, listed: ["a", "b", "c"] });
  assert.deepEqual(plain(h.submissions), [
    ["one", [{ method: "moveBookmark", args: ["a", "other"] }, { method: "moveBookmark", args: ["b", "other"] }]],
    ["one", [{ method: "moveBookmark", args: ["a", "bar", 1] }, { method: "moveBookmark", args: ["b", "bar", 2] }]],
  ]);
  await h.settle(0, null, new Error("stale"));
  assert.deepEqual(h.failures, ["Error: stale"]);
});

test("Undo outlives its timer while the restore is pending, and a refused restore offers it for a fresh timeout", async () => {
  const h = harness();
  h.send({ kind: "delete", ids: ["a"] });
  await h.settle(0, removed(["a"]));
  h.send({ kind: "undo" });
  h.expire();
  assert.equal(h.render().undoCount, 1, "the timer leaves a pending Undo alone");
  await h.settle(1, null, new Error("refused"));
  assert.equal(h.render().undoCount, 1, "a refused Undo is offered again");
  h.expire();
  assert.equal(h.render().undoCount, null, "and expires on its new timer");
});

test("an older restore finishing never unlocks a second restore of a newer Undo", async () => {
  const h = harness();
  h.send({ kind: "delete", ids: ["a"] });
  await h.settle(0, removed(["a"]));
  h.send({ kind: "delete", ids: ["b"] });
  h.send({ kind: "undo" });
  await h.settle(1, removed(["b"]));
  h.send({ kind: "undo" });
  await h.settle(2, undefined);
  h.send({ kind: "undo" });
  h.send({ kind: "undo" });
  const restoresOfB = plain(h.submissions).filter(([, [m]]) => m.method === "restoreBookmarks" && m.args[0].places[0].id === "b");
  assert.equal(restoresOfB.length, 1);
});
