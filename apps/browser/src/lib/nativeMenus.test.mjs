import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import ts from "typescript";
const { folderChildren } = await import("../store/bookmarks.ts");
const source = readFileSync(new URL("./native.ts", import.meta.url), "utf8");
const section = source.slice(source.indexOf("function menuBookmarks("), source.indexOf("export function menuState(")) + source.slice(source.indexOf("function isInTree("));
const compiled = ts.transpileModule(section, { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText;
const menus = (capable) => new Function("folderChildren", "nativeBookmarkMenuSourceAvailable", `${compiled}; return bookmarkMenus;`)(folderChildren, () => capable);
const fixture = () => ({ nodes: { bar: { id: "bar", kind: "folder", title: "Bar", children: ["web"] }, other: { id: "other", kind: "folder", title: "Other", children: [] }, web: { id: "web", kind: "url", title: "Web", url: "https://fixture.example", parentId: "bar", addedAt: 1 } }, roots: { default: { bar: "bar", other: "other" } } });

test("capable menu hosts receive only profile and revision while bookmark edits invalidate metadata", () => {
  const bookmarkMenus = menus(true);
  const bookmarks = fixture();
  bookmarks.nodes = new Proxy(bookmarks.nodes, { ownKeys() { throw new Error("native menu source must not enumerate the JS tree"); } });
  const first = bookmarkMenus(bookmarks, "default");
  assert.deepEqual(first.bookmarksBar, []);
  assert.deepEqual(first.otherBookmarks, []);
  assert.deepEqual(first.recentBookmarks, []);
  assert.equal(first.bookmarkNative.profileId, "default");
  assert.equal(bookmarkMenus(bookmarks, "default"), first);
  assert.ok(bookmarkMenus(fixture(), "default").bookmarkNative.revision > first.bookmarkNative.revision);
});

test("older native menu hosts retain complete bookmark data", () => {
  const next = menus(false)(fixture(), "default");
  assert.equal(next.bookmarkNative, undefined);
  assert.deepEqual(next.bookmarksBar, [{ id: "web", title: "Web", url: "https://fixture.example" }]);
  assert.deepEqual(next.recentBookmarks, [{ id: "web", title: "Web", url: "https://fixture.example" }]);
});
