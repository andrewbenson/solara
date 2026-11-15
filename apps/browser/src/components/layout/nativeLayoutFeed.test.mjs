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

test("pane presentation batches group sibling panes and reject an older window generation", async () => {
  const { nativePaneWindows } = await import("./nativeLayoutFeed.ts");
  assert.deepEqual(nativePaneWindows({
    old: { windowId: "w", tabId: "retired", generation: 3, presentation: { token: 1 } },
    one: { windowId: "w", tabId: "a", generation: 4, presentation: { token: 2 } },
    two: { windowId: "w", tabId: "b", generation: 4, presentation: { token: 3 } },
    clear: { windowId: "other", tabId: "c", generation: 2, presentation: null },
  }), {
    w: { generation: 4, presentations: { a: { token: 2 }, b: { token: 3 } } },
    other: { generation: 2, presentations: {} },
  });
});

test("a delayed publisher from an ended window generation cannot replace the current pane", () => {
  let windows;
  const feed = new NativeLayoutFeed((value) => { windows = value; });
  const current = {}, retired = {};
  feed.begin("w:a", current, 8);
  feed.update("w:a", current, { presentation: "current" });
  feed.begin("w:a", retired, 7);
  feed.update("w:a", retired, { presentation: "retired" });
  feed.end("w:a", retired);
  assert.deepEqual(windows, { "w:a": { presentation: "current", generation: 8 } });
});

test("removing the final pane emits a generation-stamped empty window presentation", async () => {
  const { nativePaneWindows } = await import("./nativeLayoutFeed.ts");
  const previous = { w: { generation: 4, presentations: { a: { token: 2 } } } };
  assert.deepEqual(nativePaneWindows({}, previous), { w: { generation: 4, presentations: {} } });
  assert.deepEqual(nativePaneWindows({ old: { windowId: "w", tabId: "a", generation: 3, presentation: { token: 1 } } }, previous), { w: { generation: 4, presentations: {} } });
});
