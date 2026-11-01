import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = readFileSync(new URL("./native-bench.mjs", import.meta.url), "utf8");
const between = (start, end) => source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start)));

const context = vm.createContext({});
vm.runInContext(`${between("const median = (xs) =>", "const toolDir =")}\nglobalThis.framedRow = framedRow;`, context);
const framedRow = (...args) => context.framedRow(...args);

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
