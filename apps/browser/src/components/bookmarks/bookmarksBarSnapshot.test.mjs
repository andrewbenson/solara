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

test("bar snapshots follow the selected profile root order and contain only its immediate children", () => {
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
    items: [
      { id: "folder", kind: "folder", title: "folder" },
      { id: "link", kind: "url", title: "Named", url: "https://example.com", favicon: "data:image/png;base64,icon" },
      { id: "untitled", kind: "url", title: "", url: "https://untitled.example", favicon: null },
    ],
    otherId: "other",
    hasOther: true,
    hideBookmarksBarImport: false,
    theme: {
      toolbarHover: "#111111", toolbarPressed: "#222222", textTab: "#333333",
      textTertiary: "#444444", icon: "#555555", divider: "#666666",
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
