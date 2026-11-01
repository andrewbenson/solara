import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = readFileSync(new URL("./native-bench.mjs", import.meta.url), "utf8");
const between = (start, end) => source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start)));

const context = vm.createContext({ frameRows: () => [] });
vm.runInContext([
  between("const median = (xs) =>", "const toolDir ="),
  between("function summary(", "function printTable("),
  "globalThis.framedRow = framedRow; globalThis.summary = summary;",
].join("\n"), context);
const framedRow = (...args) => context.framedRow(...args);
const row = (rows, name) => rows.find((r) => r.name === name);

const run = (switches, display) => ({ tabSwitch: switches, display });
const awake = { before: { locked: false, asleep: false }, after: { locked: false, asleep: false } };
const locked = { before: { locked: true, asleep: false }, after: { locked: true, asleep: false } };
const lockedAfter = { before: { locked: false, asleep: false }, after: { locked: true, asleep: false } };
const asleep = { before: { locked: false, asleep: true }, after: { locked: false, asleep: false } };
const shown = (r) => r.tabSwitch[0];

test("a paint row takes every run when the display stayed awake and unlocked", () => {
  const row = framedRow("tab switch → shown", [run([30], awake), run([40], awake), run([35], awake)], shown, "ms");
  assert.equal(row.pending, undefined);
  assert.equal(row.median, 35);
  assert.equal(row.n, 3);
  assert.equal(row.leftOut, undefined);
});

test("a paint row reads pending when every run had the screen locked", () => {
  const row = framedRow("tab switch → shown", [run([900], locked), run([1000], locked)], shown, "ms");
  assert.match(row.pending, /^pending: the screen was locked/);
  assert.equal(row.n, 0);
  assert.ok(Number.isNaN(row.median));
});

test("a run that locks partway, or with the display asleep, is left out and counted", () => {
  const row = framedRow("tab switch → shown", [run([30], awake), run([900], lockedAfter), run([950], asleep)], shown, "ms");
  assert.equal(row.pending, undefined);
  assert.equal(row.median, 30);
  assert.equal(row.n, 1);
  assert.equal(row.leftOut, 2);
});

test("a run without a display reading counts as awake, as before this check existed", () => {
  const row = framedRow("tab switch → shown", [run([30], undefined), run([34], {})], shown, "ms");
  assert.equal(row.pending, undefined);
  assert.equal(row.n, 2);
});

test("a phase that wasn't run stays an empty row, not pending", () => {
  const row = framedRow("tab switch → shown", [], shown, "ms");
  assert.equal(row.pending, undefined);
  assert.equal(row.n, 0);
});

const launch = (firstPaint, display) => ({ window: 400, withContent: 450, js: 300, firstPaint, firstFrame: firstPaint - 20, display });
const session = (display) => ({
  idle: {}, memory: {}, throttled: { tabSwitch: 0, newTab: 0 }, display,
  tabSwitch: [30], tabVisible: [20], newTab: [100], newTabFrame: [90], newTabDom: [60],
  newWindow: [{ window: 60, withContent: 70, firstPaint: 120, firstFrame: 110 }],
});
const windows = (display) => ({ newWindow: [{ window: 65, withContent: 75, firstPaint: 130, firstFrame: 115 }], display });
const report = (display) => context.summary({ launch: [launch(500, display), launch(520, display)], session: [session(display)], windows: [windows(display)], journeys: [] });

const LAUNCH_ROWS = ["launch → first page painted", "launch → first page's first frame"];
const SESSION_ROWS = ["tab switch → shown (median of 16 per run)", "new tab → first paint (median of 5 per run)", "new tab → its page's first frame (median of 5 per run)"];
const WINDOW_ROWS = ["new window → first paint (median per run)", "new window → its page's first frame (median per run)"];
const FRAME_FREE = ["launch → window shown", "launch → JS running", "new window → on screen (median per run)",
  "tab switch → visible, no frame needed (informational; median of 16 per run)", "new tab → DOM ready, no frame needed (informational; median of 5 per run)"];

for (const [family, names] of [["launch", LAUNCH_ROWS], ["session", SESSION_ROWS], ["new window", WINDOW_ROWS]]) {
  test(`the ${family} paint and frame rows read pending when every run was locked`, () => {
    const rows = report(locked);
    for (const name of names) assert.match(row(rows, name)?.pending ?? "", /^pending: the screen was locked/, name);
  });

  test(`the ${family} paint and frame rows are numbers when the display was awake`, () => {
    const rows = report(awake);
    for (const name of names) {
      assert.equal(row(rows, name)?.pending, undefined, name);
      assert.ok(Number.isFinite(row(rows, name).median), name);
    }
  });
}

test("rows that don't wait on a frame stay numbers on a locked screen", () => {
  const rows = report(locked);
  for (const name of FRAME_FREE) {
    assert.equal(row(rows, name)?.pending, undefined, name);
    assert.ok(Number.isFinite(row(rows, name).median), name);
  }
});

test("the new window rows pool session and windows runs and leave out only the locked ones", () => {
  const rows = context.summary({ launch: [], session: [session(awake)], windows: [windows(locked)], journeys: [] });
  const paint = row(rows, "new window → first paint (median per run)");
  assert.equal(paint.median, 120);
  assert.equal(paint.n, 1);
  assert.equal(paint.leftOut, 1);
});
