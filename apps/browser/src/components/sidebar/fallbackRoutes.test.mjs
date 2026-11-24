import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import ts from "typescript";

const routes = [
  ["./NativeSidebar.tsx", "sidebar.action", ["click", "close", "middleClick", "rename", "backToPinned", "tileDoubleClick", "toggleMute", "groupMenu", "toggleGroup", "closeGroup", "folder", "folderMenu", "scrolled", "renamed"], ["handled", "clicked", "removedPin", "tabMenu", "tabMenuChoice", "tabMenuSelectionChoice", "groupMenuChoice", "sidebarMenu", "overflowMenu", "newTab", "tidy", "clear", "cleanUp", "live"]],
  ["../layout/NativeTopStrip.tsx", "topStrip.action", ["click", "activate", "close", "toggleMute", "groupMenu", "toggleGroup", "closeGroup", "tuck", "folderMenu", "tileFolder", "tileFolderMenu"], ["removedPin", "tabMenu", "tabMenuChoice", "tabMenuSelectionChoice", "groupMenuChoice", "newTab"]],
  ["./NativeSidebar.tsx", "SHELL_TOPIC", ["drop"], ["profileMenu", "manageProfiles", "toggleDownloads", "liveWidth", "commitWidth", "iconsOnly"]],
  ["../layout/NativeTopStrip.tsx", "topStrip.peek.action", ["drop"], ["profileMenu", "toggleDownloads", "live"]],
];

for (const [path, topic, removed, kept] of routes) {
  test(`${topic} refuses retired routes and retains deliberate delegation`, () => {
    const source = ts.createSourceFile(path, readFileSync(new URL(path, import.meta.url), "utf8"), ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
    let handler;
    const find = (node) => {
      if (ts.isPropertyAssignment(node) && (ts.isStringLiteral(node.name) ? node.name.text : node.name.getText(source).replace(/^\[|\]$/g, "")) === topic) handler = node.initializer;
      ts.forEachChild(node, find);
    };
    find(source);
    assert.ok(handler, `${topic} handler exists`);
    const cases = [];
    const collect = (node) => {
      if (ts.isCaseClause(node) && ts.isStringLiteral(node.expression)) cases.push(node.expression.text);
      ts.forEachChild(node, collect);
    };
    collect(handler);
    for (const action of removed) assert.ok(!cases.includes(action), `${topic} must not handle ${action}`);
    for (const action of kept) assert.ok(cases.includes(action), `${topic} must keep ${action}`);
  });
}

test("refusal drivers have valid JavaScript syntax", () => {
  for (const name of ["fallback-refused-test", "folder-panel-test", "tab-menu-move-to-test"]) {
    const path = `../../../scripts/${name}.mjs`;
    const source = ts.createSourceFile(path, readFileSync(new URL(path, import.meta.url), "utf8"), ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
    assert.deepEqual(source.parseDiagnostics.map((diagnostic) => ts.flattenDiagnosticMessageText(diagnostic.messageText, "\n")), [], name);
  }
});
