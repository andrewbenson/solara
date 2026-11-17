import test from "node:test";
import assert from "node:assert/strict";
import { placementPreparation, verifyPlacementPreparation, verifyNoPublishedStateReapplication } from "./placement-prepare.mjs";

const span = (stage, detail, start, end, id) => [
  { stage, detail, at: start, id, phase: "begin" },
  { stage, detail, at: end, id, phase: "end" },
];
const sample = (...events) => ({ action: "switch", commandAt: 100, shownAt: 180, events: events.flat() });
const results = value => ({ session: [{ layoutTrace: [value] }] });

test("separates queue wait from reconciliation and duplicate layout bodies", () => {
  const value = sample(span("layout", "window 5", 102, 112, "one"), span("reconcile", "", 130, 155, "two"),
    span("poolPrepareLayouts", "5", 131, 150, "three"), span("layout", "window 5", 132, 149, "four"));
  const measured = placementPreparation(value);
  assert.equal(measured.queuedBeforeReconcile, 30);
  assert.equal(measured.firstReconcileBody, 25);
  assert.equal(measured.preparationBody, 19);
  assert.deepEqual(measured.repeatedLayouts, [{ detail: "window 5", milliseconds: 17 }]);
  assert.throws(() => verifyPlacementPreparation(results(value)), /already-published revision/);
});

test("allows the first layout of a revision during synchronous preparation", () => {
  const value = sample(span("reconcile", "", 130, 155, "one"), span("poolPrepareLayouts", "5", 131, 150, "two"),
    span("layout", "window 5", 132, 149, "three"));
  assert.equal(verifyPlacementPreparation(results(value)), 1);
});

test("allows a different window or revision to finish during preparation", () => {
  const value = sample(span("layout", "first 4", 102, 112, "one"), span("poolPrepareLayouts", "5", 131, 150, "two"),
    span("layout", "first 5", 132, 139, "three"), span("layout", "second 4", 140, 149, "four"));
  assert.equal(verifyPlacementPreparation(results(value)), 1);
});

test("does not call queued work preparation time", () => {
  const value = sample(span("layout", "window 5", 102, 112, "one"), span("reconcile", "", 130, 155, "two"),
    span("poolPrepareLayouts", "5", 131, 132, "three"));
  assert.equal(verifyPlacementPreparation(results(value)), 1);
  assert.equal(placementPreparation(value).preparationBody, 1);
});

test("separates published state reapplication from queued dirty geometry", () => {
  const dirty = sample(span("layout", "window 5", 102, 112, "one"), span("poolPrepareLayouts", "5", 131, 150, "two"),
    span("layout", "window 5", 132, 149, "three"));
  assert.throws(() => verifyPlacementPreparation(results(dirty)), /already-published revision/);
  assert.equal(verifyNoPublishedStateReapplication(results(dirty)), 1);
  const forced = sample(...dirty.events, span("layoutState", "window 5", 131.5, 131.7, "four"));
  assert.deepEqual(placementPreparation(forced).reappliedPublishedState, ["window 5"]);
  assert.throws(() => verifyNoPublishedStateReapplication(results(forced)), /reapplied a published revision/);
});
