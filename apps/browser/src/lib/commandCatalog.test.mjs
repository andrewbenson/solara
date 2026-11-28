import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
const { COMMANDS } = await import("./commandCatalog.ts");
const { PRODUCT } = await import("./productName.ts");

const swift = readFileSync(new URL("../../../../packages/shell/ios/Menus.swift", import.meta.url), "utf8").replaceAll("\\(Bundle.main.productName)", PRODUCT);

const FUNCTION_KEYS = {
  NSF5FunctionKey: "",
  NSF7FunctionKey: "",
  NSF12FunctionKey: "",
  NSUpArrowFunctionKey: "",
  NSDownArrowFunctionKey: "",
  NSLeftArrowFunctionKey: "",
  NSRightArrowFunctionKey: "",
  NSPageUpFunctionKey: "",
  NSPageDownFunctionKey: "",
};
const NAMED_KEYS = { leftArrow: "", rightArrow: "" };
const SWIFT_ESCAPES = { "\\t": "\t", "\\r": "\r", "\\u{8}": "\u0008" };

const section = (from, to) => swift.slice(swift.indexOf(from), swift.indexOf(to));
const menuSource = [
  section("static func build() -> NSMenu", "static func keyEquivalent("),
  section("private static func videoTourItem()", "private static func extensionIcon"),
  section("private static func buildProfileMenus", "private static let modifierNames"),
].join("\n");
const dynamicCommands = new Set([...section("private static let dynamicCommands", "private static func walk").matchAll(/"(\w+)"/g)].map((m) => m[1]));

const ITEM = new RegExp(
  [
    String.raw`(cmd|std|CommandItem)\("((?:[^"\\]|\\.)*)",\s*`,
    String.raw`(?:"(\w+)"|(#selector\([^)]*\)\)|MenuTarget\.undoAction|Selector\(\("[^"]+"\)\)))`,
    String.raw`(?:,\s*arg:\s*"((?:[^"\\]|\\.)*)")?`,
    String.raw`(?:,\s*(?:key:\s*)?("(?:[^"\\]|\\.)*"|functionKey\(\w+\)|leftArrow|rightArrow))?`,
    String.raw`(?:,\s*(\.\w+|\[[^\]]*\]))?\)`,
    String.raw`((?:\.\w+\(\))*)`,
  ].join(""),
  "g",
);

function swiftKey(token) {
  if (!token) return "";
  if (token.startsWith('"')) return token.slice(1, -1).replace(/\\t|\\r|\\u\{8\}/g, (e) => SWIFT_ESCAPES[e]);
  const functionKey = /^functionKey\((\w+)\)$/.exec(token);
  if (functionKey) return FUNCTION_KEYS[functionKey[1]];
  return NAMED_KEYS[token];
}

function swiftModifiers(token) {
  if (token === undefined) return ["command"];
  return [...token.matchAll(/\.(\w+)/g)].map((m) => m[1]);
}

function standardId(selector) {
  if (selector === "MenuTarget.undoAction") return "std:undo:";
  const literal = /Selector\(\("([^"]+)"\)\)/.exec(selector);
  if (literal) return `std:${literal[1]}`;
  const named = /#selector\((?:\w+\.)*(\w+)\((_:)?\)\)/.exec(selector);
  return `std:${named[1]}${named[2] ? ":" : ""}`;
}

function nativeItems() {
  const items = [];
  for (const [, kind, title, command, selector, arg, keyToken, modsToken, suffix] of menuSource.matchAll(ITEM)) {
    const id = kind === "std" ? standardId(selector) : arg ? `${command}:${arg}` : command;
    const key = swiftKey(keyToken);
    const item = { id, title, key, modifiers: key ? swiftModifiers(modsToken) : [], hidden: suffix.includes("hiddenShortcut") };
    if (id === "selectTab:\\($0)") {
      for (let n = 1; n <= 8; n++) items.push({ ...item, id: `selectTab:${n}`, title: `Select Tab ${n}`, key: String(n) });
    } else items.push(item);
  }
  return items;
}

function nativeGroups() {
  const groups = new Map();
  for (const item of nativeItems()) {
    if (!dynamicCommands.has(item.id.split(":")[0])) groups.set(item.id, [...(groups.get(item.id) ?? []), item]);
  }
  return new Map(
    [...groups].map(([id, items]) => {
      const primary = items.find((i) => !i.hidden) ?? items[0];
      return [id, primary.title];
    }),
  );
}

test("every menu bar command has the catalog's title", () => {
  for (const [id, title] of nativeGroups()) {
    if (id.startsWith("std:")) continue;
    const [command, arg] = id.split(":");
    const spec = COMMANDS[command];
    assert.equal((arg ? spec?.variants?.[arg] : spec)?.title, title, `${id} title`);
  }
});
