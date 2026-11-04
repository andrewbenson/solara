import assert from "node:assert/strict";
import test from "node:test";
import { matchQuickCreate } from "./quickCreate.ts";

const ids = (query: string, limit?: number) => matchQuickCreate(query, limit).map((c) => c.id);

test("new and create need a space before what to make", () => {
  assert.deepEqual(ids("new"), []);
  assert.deepEqual(ids("create"), []);
  assert.deepEqual(ids("newdoc"), []);
  assert.deepEqual(ids("renew doc"), []);
  assert.deepEqual(ids("new doc"), ["doc"]);
  assert.deepEqual(ids("  Create  Google   Doc "), ["doc"]);
  assert.deepEqual(ids("new\tsheet"), ["sheet"]);
});

test("a bare new or create with spaces offers the first ones", () => {
  assert.deepEqual(ids("new "), ["doc", "sheet", "slides"]);
  assert.deepEqual(ids("create   ", 2), ["doc", "sheet"]);
  assert.deepEqual(ids("new \n"), ["doc", "sheet", "slides"]);
});

test("exact aliases come before prefixes, in list order", () => {
  assert.deepEqual(ids("new figma"), ["figma"]);
  assert.deepEqual(ids("new fig"), ["figma", "figjam"]);
  assert.deepEqual(ids("new nothing-like-this"), []);
});

test("a line break after what to make matches nothing, as before", () => {
  assert.deepEqual(ids("new doc\nmore"), []);
  assert.deepEqual(ids("new doc\r"), []);
  assert.deepEqual(ids("new doc\u2028"), []);
  assert.deepEqual(ids("new\ndoc"), ["doc"]);
});

test("a long run of spaces before a line break parses quickly", () => {
  for (const crafted of ["new" + " ".repeat(40_000) + "x\ny", "create" + "\t ".repeat(20_000) + "!\u2029!"]) {
    const started = performance.now();
    assert.deepEqual(ids(crafted), []);
    const took = performance.now() - started;
    assert.ok(took < 50, `${took.toFixed(1)} ms for ${crafted.length} characters`);
  }
});
