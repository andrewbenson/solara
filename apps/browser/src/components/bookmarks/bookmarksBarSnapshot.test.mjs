import assert from "node:assert/strict";
import { test } from "node:test";
import { bookmarksBarSnapshot } from "./bookmarksBarSnapshot.ts";

const theme = {
  toolbarHover: "#111111",
  toolbarPressed: "#222222",
  textTab: "#333333",
  textTertiary: "#444444",
  icon: "#555555",
  divider: "#666666",
  dark: true,
  accent: "#777777",
};

const folder = (id, children) => ({ id, kind: "folder", parentId: null, title: id, children, addedAt: 0 });
const link = (id, title, url, favicon = null) => ({ id, kind: "url", parentId: "bar", title, url, favicon, addedAt: 0 });

test("bar snapshots follow the selected profile root order and include its menu subtrees and computed menu metadata", () => {
  const bookmarks = {
    roots: { first: { bar: "bar", other: "other" }, second: { bar: "secondBar", other: "secondOther" } },
    nodes: {
      bar: folder("bar", ["folder", "missing", "link", "untitled"]),
      folder: folder("folder", ["nested"]),
      nested: link("nested", "Nested", "https://nested.example"),
      link: link("link", "Named", "https://example.com", "data:image/png;base64,icon"),
      untitled: link("untitled", "", "https://untitled.example"),
      other: folder("other", ["nested"]),
      secondBar: folder("secondBar", ["second"]),
      second: link("second", "Second", "https://second.example"),
      secondOther: folder("secondOther", []),
    },
  };
  const before = JSON.stringify(bookmarks);
  const state = bookmarksBarSnapshot(bookmarks, "first", false, theme);
  assert.deepEqual(state, {
    profileId: "first",
    barId: "bar",
    bookmarksBar: "always",
    items: [
      { id: "folder", kind: "folder", title: "folder", children: [{ id: "nested", kind: "url", title: "Nested", url: "https://nested.example", cleanUrl: "https://nested.example", favicon: null }], folderLinks: 1, makesGroup: true, restorableArcHolder: false },
      { id: "link", kind: "url", title: "Named", url: "https://example.com", cleanUrl: "https://example.com", favicon: "data:image/png;base64,icon" },
      { id: "untitled", kind: "url", title: "", url: "https://untitled.example", cleanUrl: "https://untitled.example", favicon: null },
    ],
    otherId: "other",
    otherFolder: { id: "other", kind: "folder", title: "other", children: [{ id: "nested", kind: "url", title: "Nested", url: "https://nested.example", cleanUrl: "https://nested.example", favicon: null }], folderLinks: 1, makesGroup: true, restorableArcHolder: false },
    hasOther: true,
    hideBookmarksBarImport: false,
    sidebarEdge: null,
    theme: {
      toolbarHover: "#111111", toolbarPressed: "#222222", textTab: "#333333",
      textTertiary: "#444444", icon: "#555555", divider: "#666666", accent: "#777777",
    },
    dark: true,
  });
  assert.deepEqual(bookmarksBarSnapshot(bookmarks, "second", true, { ...theme, dark: false }).items.map((n) => n.id), ["second"]);
  assert.equal(JSON.stringify(bookmarks), before);
});

test("missing or invalid roots produce an empty bar and no Other Bookmarks button", () => {
  const missing = bookmarksBarSnapshot({ nodes: {}, roots: {} }, "missing", true, { ...theme, dark: false });
  assert.deepEqual(missing.items, []);
  assert.equal(missing.otherId, null);
  assert.equal(missing.hasOther, false);
  assert.equal(missing.hideBookmarksBarImport, true);
  assert.equal(missing.dark, false);
  const invalid = bookmarksBarSnapshot({ nodes: { bar: link("bar", "Bar", "https://example.com"), other: folder("other", []) }, roots: { first: { bar: "bar", other: "other" } } }, "first", false, theme);
  assert.deepEqual(invalid.items, []);
  assert.equal(invalid.otherId, "other");
  assert.equal(invalid.hasOther, false);
});


test("snapshots carry the window-local sidebar boundary without changing bookmark data", () => {
  const bookmarks = { nodes: {}, roots: {} };
  const snapshot = bookmarksBarSnapshot(bookmarks, "first", false, theme, 246);
  assert.equal(snapshot.sidebarEdge, 246);
  assert.equal(snapshot.theme.accent, theme.accent);
  assert.equal(bookmarksBarSnapshot(bookmarks, "first", false, theme, null).sidebarEdge, null);
});


test("folder metadata counts deep links while menu payload truncates at the RN depth boundary", () => {
  const nodes = { bar: folder("bar", ["level0"]), other: folder("other", ["otherLink"]), otherLink: link("otherLink", "Other", "https://other.example/?utm_source=fixture&keep=1") };
  for (let depth = 0; depth < 11; depth++) nodes[`level${depth}`] = folder(`level${depth}`, depth === 10 ? ["deep"] : [`level${depth + 1}`]);
  nodes.deep = link("deep", "Deep", "https://deep.example");
  const snapshot = bookmarksBarSnapshot({ roots: { p: { bar: "bar", other: "other" } }, nodes }, "p", false, theme, null, "newTab");
  assert.equal(snapshot.bookmarksBar, "newTab");
  let item = snapshot.items[0];
  for (let depth = 0; depth <= 9; depth++) {
    assert.equal(item.id, `level${depth}`);
    assert.equal(item.folderLinks, 1);
    assert.equal(item.makesGroup, true);
    if (depth === 9) assert.deepEqual(item.children, []);
    else item = item.children[0];
  }
  assert.equal(snapshot.otherFolder.children[0].cleanUrl, "https://other.example/?keep=1");
  const otherTree = bookmarksBarSnapshot({ roots: { p: { bar: "other", other: "bar" } }, nodes }, "p", false, theme).otherFolder;
  let otherItem = otherTree.children[0];
  for (let depth = 0; depth < 8; depth++) otherItem = otherItem.children[0];
  assert.equal(otherItem.id, "level8");
  assert.deepEqual(otherItem.children, []);
});

test("Arc holder and non-web folder capabilities come from the same JS predicates as RN menus", () => {
  const bookmarks = {
    roots: { p: { bar: "bar", other: "other" } },
    nodes: {
      bar: folder("bar", ["holder", "internal", "empty"]), other: folder("other", []),
      holder: { ...folder("holder", ["group"]), parentId: "bar", title: "Space (Arc)" },
      group: folder("group", ["web"]), web: link("web", "Web", "https://web.example"),
      internal: folder("internal", ["settings"]), settings: link("settings", "Settings", "solara://settings"),
      empty: folder("empty", []),
    },
  };
  const snapshot = bookmarksBarSnapshot(bookmarks, "p", false, theme);
  assert.equal(snapshot.items[0].restorableArcHolder, true);
  assert.equal(snapshot.items[0].children[0].restorableArcHolder, false);
  assert.equal(snapshot.items[1].folderLinks, 1);
  assert.equal(snapshot.items[1].makesGroup, false);
  assert.equal(snapshot.items[2].folderLinks, 0);
  assert.equal(snapshot.items[2].makesGroup, false);
});
