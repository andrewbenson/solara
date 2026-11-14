import assert from "node:assert/strict";
import { test } from "node:test";
import { NativeLayoutFeed } from "./nativeLayoutFeed.ts";

test("a reloaded publisher rejects queued updates and cleanup from its predecessor", () => {
  let windows;
  const feed = new NativeLayoutFeed((value) => { windows = value; });
  const old = {}, current = {};
  feed.begin("w", old, 7);
  feed.update("w", old, { state: "old" });
  feed.begin("w", current, 7);
  feed.update("w", current, { state: "new" });
  feed.update("w", old, { state: "late" });
  feed.end("w", old);
  assert.deepEqual(windows, { w: { state: "new", generation: 7 } });
  feed.end("w", current);
  feed.update("w", current, { state: "after stop" });
  assert.deepEqual(windows, {});
});

test("unadmitted windows cannot publish and independent window generations remain intact", () => {
  let windows = {};
  const feed = new NativeLayoutFeed((value) => { windows = value; });
  const one = {}, two = {};
  feed.begin("missing", one, 0);
  feed.update("missing", one, { state: "ignored" });
  assert.deepEqual(windows, {});
  feed.begin("one", one, 3);
  feed.begin("two", two, 4);
  feed.update("one", one, { state: "a" });
  feed.update("two", two, { state: "b" });
  feed.end("one", one);
  assert.deepEqual(windows, { two: { state: "b", generation: 4 } });
});
