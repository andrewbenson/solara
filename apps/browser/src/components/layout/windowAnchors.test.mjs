import assert from "node:assert/strict";
import { test } from "node:test";
import { WindowLayoutAnchorFeed } from "../../../../../packages/settings/src/windowShell.ts";

const batch = (windowGeneration, generation, storeRevision = generation) => ({ windowId: "w", windowGeneration, generation, storeRevision, anchors: { content: [10, 6, 500, 700] }, sidebar: false, profileTitle: "Personal", profileNameWidth: 52, stripAvailableWidth: 900 });

test("the initial read cannot overwrite a newer anchor event", () => {
  const feed = new WindowLayoutAnchorFeed();
  const owner = {};
  feed.begin("w", owner);
  assert.equal(feed.event("w", batch(1, 5)), undefined);
  assert.deepEqual(feed.initial("w", owner, { windowGeneration: 1, batch: batch(1, 3) }), batch(1, 5));
  assert.equal(feed.event("w", batch(1, 4)), undefined);
  assert.equal(feed.current("w").generation, 5);
});

test("initial admission rejects an old host event even before its first batch exists", () => {
  const feed = new WindowLayoutAnchorFeed();
  const owner = {};
  feed.begin("w", owner);
  feed.event("w", batch(1, 99));
  assert.equal(feed.initial("w", owner, { windowGeneration: 2, batch: null }), undefined);
  assert.equal(feed.current("w"), undefined);
  assert.equal(feed.event("w", batch(1, 100)), undefined);
  assert.deepEqual(feed.event("w", batch(2, 1)), batch(2, 1));
});

test("old cleanup and a late read cannot erase a replacement adapter", () => {
  const feed = new WindowLayoutAnchorFeed();
  const old = {}, fresh = {};
  feed.begin("w", old);
  feed.initial("w", old, { windowGeneration: 1, batch: batch(1, 5) });
  feed.begin("w", fresh);
  feed.initial("w", fresh, { windowGeneration: 2, batch: batch(2, 1) });
  assert.equal(feed.end("w", old), undefined);
  assert.equal(feed.initial("w", old, { windowGeneration: 1, batch: batch(1, 6) }), undefined);
  assert.equal(feed.event("w", batch(1, 999)), undefined);
  assert.equal(feed.current("w").windowGeneration, 2);
  assert.equal(feed.end("w", fresh), 2);
  assert.equal(feed.current("w"), undefined);
});

test("a delayed initial read from a retired hook cannot close a new hook on the same host", () => {
  const feed = new WindowLayoutAnchorFeed();
  const old = {}, fresh = {};
  feed.begin("w", old);
  assert.equal(feed.end("w", old), null);
  feed.begin("w", fresh);
  feed.initial("w", fresh, { windowGeneration: 1, batch: batch(1, 2) });
  assert.equal(feed.initial("w", old, { windowGeneration: 1, batch: batch(1, 1) }), undefined);
  assert.equal(feed.end("w", old), undefined);
  assert.equal(feed.current("w").generation, 2);
});

test("a late legacy card writer cannot replace native authority while its read is pending", async () => {
  const layout = await import("./windowLayout.ts");
  const owner = {};
  layout.setCardAnchor("late", { left: 1, top: 2, width: 3, height: 4 });
  layout.nativeWindowAnchorFeed.begin("late", owner);
  layout.applyNativeWindowAnchors({ ...batch(1, 1), windowId: "late" });
  layout.setCardAnchor("late", { left: 100, top: 200, width: 300, height: 400 });
  assert.deepEqual(layout.useCardAnchors.getState().late, { left: 10, top: 6, width: 500, height: 700 });
  layout.nativeWindowAnchorFeed.end("late", owner);
  layout.dropNativeWindowAnchors("late");
  layout.setCardAnchor("late", { left: 1, top: 2, width: 3, height: 4 });
  assert.equal(layout.useCardAnchors.getState().late.left, 1);
});

test("late toolbar and sidebar writers cannot replace a native URL batch", async () => {
  const layout = await import("./windowLayout.ts");
  const owner = {};
  layout.nativeWindowAnchorFeed.begin("late-url", owner);
  layout.applyNativeWindowAnchors({ ...batch(1, 1), windowId: "late-url", anchors: { content: [10, 6, 500, 700], url: [229, 6, 1032, 41] } });
  layout.setUrlAnchor("late-url", { left: 100, top: 200, width: 300, sidebar: { height: 34 } });
  assert.deepEqual(layout.useUrlAnchors.getState()["late-url"], { left: 229, top: 6, width: 1032 });
  layout.applyNativeWindowAnchors({ ...batch(1, 2), windowId: "late-url", sidebar: true, anchors: { content: [10, 6, 500, 700], url: [6, 46, 178, 34] } });
  assert.deepEqual(layout.useUrlAnchors.getState()["late-url"], { left: 6, top: 46, width: 178, sidebar: { height: 34 } });
  layout.applyNativeWindowAnchors({ ...batch(1, 3), windowId: "late-url" });
  assert.equal(layout.useUrlAnchors.getState()["late-url"], undefined);
  layout.nativeWindowAnchorFeed.end("late-url", owner);
  layout.dropNativeWindowAnchors("late-url");
});

test("native intrinsic widths reject late RN measurements and unchanged publications stay quiet", async () => {
  const layout = await import("./windowLayout.ts");
  const measured = await import("./measuredWidths.ts");
  const profile = "Native Width Fixture";
  const sample = { ...batch(1, 1), windowId: "native-width", profileTitle: profile, profileNameWidth: 71, stripAvailableWidth: 908 };
  layout.applyNativeWindowAnchors(sample);
  measured.setMeasuredWidth(`profile-name|${profile}`, 99);
  assert.equal(measured.useWidths.getState()[`profile-name|${profile}`], 71);
  assert.equal(measured.useWidths.getState()["window-strip|native-width"], 908);
  let changes = 0;
  const stop = measured.useWidths.subscribe(() => changes++);
  layout.applyNativeWindowAnchors(sample);
  assert.equal(changes, 0);
  layout.applyNativeWindowAnchors({ ...sample, stripAvailableWidth: 907 });
  assert.equal(changes, 1);
  stop();
  layout.dropNativeWindowAnchors("native-width");
  assert.equal(measured.useWidths.getState()["window-strip|native-width"], undefined);
});
