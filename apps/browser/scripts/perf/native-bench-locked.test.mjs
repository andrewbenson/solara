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

const j2 = { js: 5, commit: 20, shown: 30, typeable: 40, suggest: 70, appTypeable: 38, t0Skew: 0, postGap: 1, delivery: 2, suggestDelivery: 2 };
const j4 = (fcp) => ({ request: 10, start: 15, commit: 60, fcp, pageFcp: fcp + 2, engine: fcp - 10, delivery: 2 });
const journey = (display, fcp = 200) => ({ j2: [j2, j2], j4new: [j4(fcp)], j4page: [j4(fcp + 50)], lost: { j2: [], j4new: [], j4page: [] }, load: [3, 3], display });
const journeys = (...runs) => context.summary({ launch: [], session: [], windows: [], journeys: runs });

const J2_FRAMED = ["J2 keystroke → its suggestions on screen"];
const J4_FRAMED = ["new tab's bar (⌘T)", "page's panel (⌘L)"].flatMap((from) => [
  `J4 ${from}: Enter → first contentful paint (the app's mark)`,
  `J4 ${from}: Enter → first contentful paint (the page's own, CDP)`,
  `J4 ${from}: request → first contentful paint (engine and network)`,
]);
const JOURNEY_FRAME_FREE = ["J2 ⌘T key → its command bar committed", "J2 ⌘T key → that commit on screen", "J2 ⌘T key → bar focused and on screen (typeable)",
  "J4 new tab's bar (⌘T): Enter → document committed", "J4 page's panel (⌘L): Enter → engine asked to load (our side)"];

for (const [family, names] of [["J2", J2_FRAMED], ["J4", J4_FRAMED]]) {
  test(`the ${family} frame and paint rows read pending when every journey run was locked`, () => {
    const rows = journeys(journey(locked), journey(locked));
    for (const name of names) assert.match(row(rows, name)?.pending ?? "", /^pending: the screen was locked/, name);
  });

  test(`the ${family} frame and paint rows pool only the awake journey runs and count the locked ones`, () => {
    const rows = journeys(journey(awake, 200), journey(lockedAfter, 900));
    for (const name of names) {
      const r = row(rows, name);
      assert.equal(r?.pending, undefined, name);
      assert.equal(r.leftOut, 1, name);
    }
    assert.equal(row(rows, "J4 new tab's bar (⌘T): Enter → first contentful paint (the app's mark)").median, 200);
  });
}

test("the journey commit rows stay numbers on a locked screen and pool every run", () => {
  const rows = journeys(journey(locked), journey(locked));
  for (const name of JOURNEY_FRAME_FREE) {
    assert.equal(row(rows, name)?.pending, undefined, name);
    assert.equal(row(rows, name).leftOut, undefined, name);
    assert.ok(Number.isFinite(row(rows, name).median), name);
  }
});

test("a journey family that wasn't run adds no pending row", () => {
  const rows = journeys({ ...journey(locked), j4new: [], j4page: [] });
  for (const name of J4_FRAMED) assert.equal(row(rows, name), undefined, name);
  assert.match(row(rows, J2_FRAMED[0]).pending, /^pending/);
});
