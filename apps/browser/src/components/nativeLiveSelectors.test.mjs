import assert from "node:assert/strict";
import { test } from "node:test";
import { chromeLiveIds, chromeSleeping } from "./nativeHostProps.ts";

const state = {
  windows: { w: { tabIds: ["a", "b", "c"] }, other: { tabIds: ["d"] } },
  live: { a: { isLoading: true }, b: { playingAudio: true }, c: { isLoading: true }, d: { isLoading: true } },
};

test("native-owned chrome does not select changing loading and playing lists", () => {
  for (const key of ["isLoading", "playingAudio"]) {
    assert.equal(chromeLiveIds(state, "w", key, true), "");
    const changed = { ...state, live: { a: { isLoading: false, playingAudio: true } } };
    assert.equal(chromeLiveIds(changed, "w", key, true), "");
  }
});

test("native-owned chrome does not scan JS live or lifecycle state", () => {
  const unavailable = { get windows() { throw new Error("windows read"); }, get live() { throw new Error("live read"); } };
  assert.equal(chromeLiveIds(unavailable, "w", "isLoading", true), "");
  assert.deepEqual(chromeSleeping(new Proxy({}, { ownKeys() { throw new Error("lifecycle read"); } }), true), []);
});

test("JS-owned chrome retains window order and excludes other windows and missing facts", () => {
  assert.equal(chromeLiveIds(state, "w", "isLoading", false), "a,c");
  assert.equal(chromeLiveIds(state, "w", "playingAudio", false), "b");
  assert.equal(chromeLiveIds(state, "missing", "isLoading", false), "");
  assert.equal(chromeLiveIds({ ...state, live: {} }, "w", "isLoading", false), "");
});

test("sleeping selection stays stable under native ownership and resumes JS fallback", () => {
  const before = chromeSleeping({ a: true, b: false }, true);
  const after = chromeSleeping({ b: true }, true);
  assert.strictEqual(before, after);
  assert.deepEqual(before, []);
  assert.deepEqual(chromeSleeping({ a: true, b: false, c: true }, false), ["a", "c"]);
});
