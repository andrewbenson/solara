import assert from "node:assert/strict";
import { test } from "node:test";
import { escapeRegExp } from "./regExpLiteral.ts";

test("every RegExp metacharacter matches only itself once escaped", () => {
  const metacharacters = "\\^$.*+?()[]{}|/-";
  for (const ch of metacharacters) {
    const pattern = new RegExp(`^${escapeRegExp(`a${ch}b`)}$`);
    assert.ok(pattern.test(`a${ch}b`), ch);
    assert.ok(!pattern.test("axb"), ch);
    assert.ok(!pattern.test("ab"), ch);
  }
});

test("an escaped string stays a literal inside a character class and an alternation", () => {
  const units = ["km/h", "m.s", "a|b", "c+"];
  const pattern = new RegExp(`^(?:${units.map(escapeRegExp).join("|")})$`);
  for (const unit of units) assert.ok(pattern.test(unit), unit);
  for (const other of ["kmxh", "mxs", "a", "b", "cc"]) assert.ok(!pattern.test(other), other);
  assert.ok(new RegExp(`[${escapeRegExp("]^-")}]`).test("-"));
  assert.ok(!new RegExp(`^[${escapeRegExp("]^-")}]$`).test("x"));
});

test("plain text comes back unchanged", () => {
  assert.equal(escapeRegExp("solara"), "solara");
  assert.equal(escapeRegExp(""), "");
});
