import assert from "node:assert/strict";
import { test } from "node:test";
await import("../test-native/index.ts");
const { lastPicture, parsePicture } = await import("./tabPictures.ts");

const good = { data: "AAAA", frame: [0, 42, 800, 600] };

test("a native picture parses to its data and four-number frame", () => {
  assert.deepEqual(parsePicture(JSON.stringify(good)), good);
});

test("no native picture stays null, whether nil or the string null", () => {
  assert.equal(parsePicture(null), null);
  assert.equal(parsePicture(undefined), null);
  assert.equal(parsePicture("null"), null);
});

test("a malformed native picture is null instead of throwing", () => {
  assert.equal(parsePicture("{"), null);
  assert.equal(parsePicture("[]"), null);
  assert.equal(parsePicture(JSON.stringify({ data: 1, frame: [0, 0, 1, 1] })), null);
});

test("a frame that is not four finite numbers is rejected", () => {
  for (const frame of [[0, 0, 1], [0, 0, 1, 1, 1], [0, 0, "1", 1], null, "0,0,1,1"]) assert.equal(parsePicture(JSON.stringify({ data: "A", frame })), null, JSON.stringify(frame));
  assert.equal(parsePicture('{"data":"A","frame":[0,0,1e999,1]}'), null);
});

test("lastPicture resolves null for a native rejection, bad JSON or a missing picture", async () => {
  assert.equal(await lastPicture("t", { lastTabPicture: () => Promise.reject(new Error("gone")) }), null);
  assert.equal(await lastPicture("t", { lastTabPicture: () => Promise.resolve("not json") }), null);
  assert.equal(await lastPicture("t", { lastTabPicture: () => Promise.resolve(null) }), null);
  assert.deepEqual(await lastPicture("t", { lastTabPicture: () => Promise.resolve(JSON.stringify(good)) }), good);
});
