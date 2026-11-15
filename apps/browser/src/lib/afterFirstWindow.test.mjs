import assert from "node:assert/strict";
import test from "node:test";
import { AfterFirstWindowQueue } from "./afterFirstWindow.ts";

test("optional tasks wait indefinitely for native admission and register individually", async () => {
  const queue = new AfterFirstWindowQueue();
  let runs = 0;
  queue.add(() => runs++);
  queue.add(() => runs++);
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(runs, 0);
  const admitted = [];
  queue.install((task) => { admitted.push(task); return () => {}; });
  assert.equal(admitted.length, 2);
  admitted[0]();
  assert.equal(runs, 1);
  admitted[1]();
  assert.equal(runs, 2);
  queue.add(() => runs++);
  assert.equal(admitted.length, 3);
  assert.equal(runs, 2);
  admitted[2]();
  assert.equal(runs, 3);
});

test("cancellation fences callbacks already admitted by an ended native generation", () => {
  const queue = new AfterFirstWindowQueue();
  let callback;
  let cancelled = 0;
  queue.install((task) => { callback = task; return () => cancelled++; });
  let runs = 0;
  const cancel = queue.add(() => runs++);
  cancel();
  callback();
  assert.equal(runs, 0);
  assert.equal(cancelled, 1);
});

test("one failed task cannot block a later opportunity", () => {
  const queue = new AfterFirstWindowQueue();
  const admitted = [];
  queue.install((task) => { admitted.push(task); return () => {}; });
  let runs = 0;
  queue.add(() => { throw new Error("optional"); });
  queue.add(() => runs++);
  const warn = console.warn;
  console.warn = () => {};
  try { admitted[0](); } finally { console.warn = warn; }
  admitted[1]();
  admitted[1]();
  assert.equal(runs, 1);
});

test("native cancellation removes pending work before a scheduler reinstall", () => {
  const queue = new AfterFirstWindowQueue();
  let cancelNative;
  queue.install((_task, cancelled) => { cancelNative = cancelled; return () => {}; });
  let runs = 0;
  queue.add(() => runs++);
  assert.equal(typeof cancelNative, "function");
  cancelNative();
  let registered = 0;
  queue.install(() => { registered++; return () => {}; });
  assert.equal(registered, 0);
  assert.equal(runs, 0);
});
