import assert from "node:assert/strict";
import { fork } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const scenarioPath = fileURLToPath(new URL("../../scripts/native/engineScenario.mjs", import.meta.url));
const run = (steps) => new Promise((resolve, reject) => {
  const child = fork(scenarioPath, ["--role", "local"], { execArgv: ["--no-warnings"], stdio: ["ignore", "ignore", "inherit", "ipc"] });
  const deadline = setTimeout(() => { child.kill("SIGKILL"); reject(new Error("scenario did not complete")); }, 60_000);
  child.once("message", ({ trace }) => { clearTimeout(deadline); child.kill(); resolve(trace.steps); });
  child.once("error", reject);
  child.once("exit", (code) => { if (code) { clearTimeout(deadline); reject(new Error(`scenario exited ${code}`)); } });
  child.send({ script: { name: "creation admission", steps: steps.map((step) => ({ mac: "local", ...step })) } });
});
const start = { op: "start" };
const turnOn = { op: "turnOn", folder: "/sync" };
const nativeCalls = (step) => step.calls.filter((call) => call.n);

test("scenario creation uses native createSync and enables after admission", async () => {
  const steps = await run([start, turnOn]);
  assert.equal(steps[1].after.memory.doc.enabled, true);
  assert.deepEqual(nativeCalls(steps[1]), [{ n: "createSync", a: ["/sync", null], r: "dev1" }]);
});

test("scenario createSync hold prevents allocation and enabling until release", async () => {
  const steps = await run([start, { op: "holdNative", names: ["createSync"] }, turnOn, { op: "releaseNative" }]);
  assert.equal(steps[2].after.heldNatives, 1);
  assert.equal(steps[2].after.memory.doc.enabled, false);
  assert.deepEqual(nativeCalls(steps[2]), []);
  assert.equal(steps[3].after.memory.doc.enabled, true);
  assert.deepEqual(nativeCalls(steps[3]), [{ n: "createSync", a: ["/sync", null], r: "dev1" }]);
});

test("scenario native key creation refusal remains off and retry succeeds", async () => {
  const steps = await run([start, { op: "mode", key: "phrase", value: false }, turnOn, { op: "mode", key: "phrase", value: true }, turnOn]);
  assert.equal(steps[2].after.memory.doc.enabled, false);
  assert.deepEqual(nativeCalls(steps[2]), [{ n: "createSync", a: ["/sync", null], r: null }]);
  assert.equal(steps[4].after.memory.doc.enabled, true);
});

test("scenario native admission failure after a hold remains off and retry succeeds", async () => {
  const steps = await run([start, { op: "holdNative", names: ["createSync"] }, turnOn, { op: "mode", key: "creation", value: false }, { op: "releaseNative" }, { op: "mode", key: "creation", value: true }, turnOn]);
  assert.equal(steps[2].after.heldNatives, 1);
  assert.equal(steps[4].after.memory.doc.enabled, false);
  assert.deepEqual(nativeCalls(steps[4]), [{ n: "createSync", a: ["/sync", null], r: { error: "creation refused" } }]);
  assert.equal(steps[6].after.memory.doc.enabled, true);
});
