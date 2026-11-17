import assert from "node:assert/strict";
import test from "node:test";
import { analyzeResults, analyzeSample, intervalUnion } from "./layout-trace.mjs";

const event = (stage, phase, at, id = 0, detail = "") => ({ stage, phase, at, id, detail });
const span = (stage, start, end, id, detail = "") => [event(stage, "begin", start, id, detail), event(stage, "end", end, id, detail)];
const sample = (extra = {}) => ({
  action: "switch", commandAt: 1000, tabId: "tab-1", windowId: "window-1", shownAt: 1050, marks: [],
  events: [event("command", "event", 1000, 0, "command switch:tab-1"), ...span("storeDispatch", 1001, 1005, 1, "activate"), event("storeCommit", "event", 1004, 0, "17"), ...span("layout", 1010, 1020, 2, "window-1 17"), ...span("reconcile", 1015, 1030, 3), ...span("paneAttach", 1021, 1023, 4, "tab-1")],
  ...extra,
});
const run = (samples, display = { before: { locked: false, asleep: false }, after: { locked: false, asleep: false } }) => ({ layoutTrace: samples, display });

test("overlapping scopes use their union rather than adding nested work", () => {
  assert.equal(intervalUnion([[0, 10], [2, 5], [7, 12], [15, 17]]), 14);
  const result = analyzeSample(sample());
  assert.equal(result.metrics["command → store commit"], 4);
  assert.equal(result.metrics["store commit → active layout end"], 16);
  assert.equal(result.metrics["target attach end → shown/paint"], 27);
  assert.equal(result.metrics["all instrumented scopes (union, excluding delayed draw)"], 24);
  assert.equal(result.metrics["outside instrumented scopes"], 26);
});

test("target correlation ignores another window's layout and another tab's attach", () => {
  const value = sample();
  value.events.push(...span("layout", 1005, 1006, 10, "other-window 17"), ...span("paneAttach", 1007, 1008, 11, "other-tab"));
  assert.equal(analyzeSample(value).metrics["command → shell layout/projection end"], 20);
  assert.equal(analyzeSample(value).metrics["command → target attach end"], 23);
});

test("an absent stage remains unavailable, while RN layout supplies the fallback boundary", () => {
  const value = sample();
  value.events = value.events.filter(event => !["layout", "paneAttach"].includes(event.stage));
  value.marks = [{ signpost: "rnLayoutBegin", at: 1008, id: "rn-1", window: 0 }, { signpost: "rnLayoutEnd", at: 1018, id: "rn-1", window: 0 }];
  const result = analyzeSample(value, { nativeLayout: false });
  assert.equal(result.metrics["command → shell layout/projection end"], null);
  assert.equal(result.metrics["command → global RN shadow layout end"], 18);
  assert.equal(result.metrics["store commit → active layout end"], 14);
  assert.equal(result.metrics["target attach end → shown/paint"], null);
});

test("signed milestone deltas expose overlapping ordering instead of clamping it away", () => {
  const value = sample();
  value.events = value.events.filter(event => event.stage !== "layout");
  value.events.push(...span("layout", 1010, 1040, 8, "window-1 17"));
  assert.equal(analyzeSample(value).metrics["active layout end → target attach end (signed)"], -17);
});

test("new windows retain distinct on-screen and first-paint boundaries", () => {
  const value = sample({ action: "newwindow", shownAt: 1040, paintAt: 1060 });
  value.events = value.events.map(event => ({ ...event, detail: event.stage === "command" ? "command newwindow:w0" : event.stage === "storeDispatch" ? "createWindow" : event.detail }));
  const result = analyzeSample(value);
  assert.equal(result.metrics["command → on screen"], 40);
  assert.equal(result.metrics["command → shown/paint"], 60);
});

test("results use equal-weight per-run medians and report locked/throttled exclusions", () => {
  const result = analyzeResults({ meta: { label: "native" }, session: [run([sample(), sample({ shownAt: 1070 })]), run([sample({ shownAt: 1100 })]), run([sample()], { before: { locked: true }, after: { locked: false } }), run([sample({ excluded: true })])] });
  const row = result.rows.find(row => row.metric === "command → shown/paint");
  assert.equal(row.median, 80);
  assert.equal(row.n, 2);
  assert.equal(row.samples, 3);
  assert.deepEqual(result.excluded, { displayRuns: 1, throttledSamples: 1 });
});

test("missing trace and missing action correlation fail instead of producing zero", () => {
  assert.throws(() => analyzeResults({ session: [{}] }), /no layout traces/);
  assert.throws(() => analyzeSample(sample({ tabId: null })), /correlation/);
  assert.throws(() => analyzeSample(sample({ events: [] })), /missing layout trace/);
  const value = sample();
  value.events = value.events.filter(event => event.stage !== "storeCommit");
  assert.throws(() => analyzeSample(value), /missing store commit/);
});

test("a late draw callback from a previous action is counted as orphaned, not mispaired", () => {
  const value = sample();
  value.events.push(event("firstDraw", "end", 1030, 100, "other-tab"));
  const result = analyzeSample(value);
  assert.equal(result.orphanEnds, 1);
  assert.equal(result.metrics["scoped firstDraw (inclusive union)"], undefined);
});


test("a delayed first-draw callback is a wall wait, separate from scoped work", () => {
  const value = sample();
  value.events.push(...span("firstDraw", 1023, 1048, 90, "tab-1"));
  const result = analyzeSample(value);
  assert.equal(result.metrics["delayed firstDraw callback (wall)"], 25);
  assert.equal(result.metrics["all instrumented scopes (union, excluding delayed draw)"], 24);
});

test("an unrelated layout completing before the command commit is not the action's layout milestone", () => {
  const value = sample();
  value.events.push(...span("layout", 1000, 1002, 100, "window-1 16"), ...span("layout", 1005, 1006, 101, "window-1 16"));
  assert.equal(analyzeSample(value).metrics["command → shell layout/projection end"], 20);
});

test("painting scopes retain target identity and exclude another page from its milestone", () => {
  const value = sample();
  value.marks.push({ signpost: "paintingBegin", at: 1023, id: "paint-1", tabId: "tab-1", window: 123 }, { signpost: "paintingEnd", at: 1032, id: "paint-1", tabId: "tab-1", window: 123 }, { signpost: "paintingBegin", at: 1008, id: "paint-2", tabId: "other-tab", window: 123 }, { signpost: "paintingEnd", at: 1010, id: "paint-2", tabId: "other-tab", window: 123 });
  const result = analyzeSample(value);
  assert.equal(result.metrics["command → initial target painting end"], 32);
  assert.equal(result.metrics["scoped painting (inclusive union)"], 11);
});

test("hidden target painting before attachment cannot satisfy the visible painting milestone", () => {
  const value = sample();
  value.marks = [
    { signpost: "paintingBegin", at: 1011.608, id: "hidden", tabId: "tab-1" },
    { signpost: "paintingEnd", at: 1011.619, id: "hidden", tabId: "tab-1" },
    { signpost: "visibleOn", at: 1023.02, id: "visible", tabId: "tab-1" },
    { signpost: "paintingBegin", at: 1026.38, id: "shown", tabId: "tab-1" },
    { signpost: "paintingEnd", at: 1026.67, id: "shown", tabId: "tab-1" },
  ];
  const result = analyzeSample(value);
  assert.ok(Math.abs(result.metrics["command → initial target painting end"] - 11.619) < 1e-8);
  assert.ok(Math.abs(result.metrics["command → target visible painting end"] - 26.67) < 1e-8);
  assert.ok(Math.abs(result.metrics["target attach end → target visible painting end"] - 3.67) < 1e-8);
});


test("legacy active layout uses the RN pass while retaining earlier native anchor projection separately", () => {
  const value = sample();
  value.marks.push({ signpost: "rnLayoutBegin", at: 1025, id: "rn", window: 0 }, { signpost: "rnLayoutEnd", at: 1035, id: "rn", window: 0 });
  const result = analyzeSample(value, { nativeLayout: false });
  assert.equal(result.metrics["command → shell layout/projection end"], 20);
  assert.equal(result.metrics["command → global RN shadow layout end"], 35);
  assert.equal(result.metrics["store commit → active layout end"], 31);
});


test("global RN passes from an old window cannot establish a new window's active layout boundary", () => {
  const value = sample({ action: "newwindow", paintAt: 1100 });
  value.events = value.events.map(event => ({ ...event, detail: event.stage === "command" ? "command newwindow:w0" : event.stage === "storeDispatch" ? "createWindow" : event.detail }));
  value.marks.push({ signpost: "rnLayoutBegin", at: 1005, id: "old-window-rn", window: 0 }, { signpost: "rnLayoutEnd", at: 1008, id: "old-window-rn", window: 0 });
  const result = analyzeSample(value, { nativeLayout: false });
  assert.equal(result.metrics["command → global RN shadow layout end"], 8);
  assert.equal(result.metrics["command → shell layout/projection end"], 20);
  assert.equal(result.metrics["store commit → active layout end"], null);
  assert.equal(result.metrics["active layout end → target attach end (signed)"], null);
});

test("new-window readiness milestones correlate to the target window", () => {
  const value = sample({ action: "newwindow", shownAt: 1090, paintAt: 1100 });
  value.events = value.events.map(event => ({ ...event, detail: event.stage === "command" ? "command newwindow:w0" : event.stage === "storeDispatch" ? "createWindow" : event.detail }));
  value.events.push(...span("windowRoot", 1007, 1010, 101, "other-window"), ...span("windowShell", 1010, 1012, 102, "other-window"), event("windowAwaitReady", "event", 1013, 0, "other-window"), event("windowReady", "event", 1014, 0, "other-window"), ...span("windowRoot", 1025, 1030, 103, "window-1"), ...span("windowShell", 1030, 1040, 104, "window-1"), event("windowAwaitReady", "event", 1045, 0, "window-1"), event("windowReady", "event", 1080, 0, "window-1"));
  const result = analyzeSample(value, { nativeLayout: false });
  assert.equal(result.metrics["command → target windowRoot end"], 30);
  assert.equal(result.metrics["command → target windowShell end"], 40);
  assert.equal(result.metrics["command → target windowAwaitReady"], 45);
  assert.equal(result.metrics["command → target windowReady"], 80);
  assert.equal(result.metrics["target windowAwaitReady → windowReady (wall)"], 35);
});
