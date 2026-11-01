import assert from "node:assert/strict";
import { test } from "node:test";
import { parseChecks, retiredEngines, webkitIdentifier, waitFor, pendingRestartLogged, assertRetired, deletionScenario, reportLeftovers, assertPendingCrash, crashBeforeRelaunch, Run } from "./profile-delete-e2e.mjs";

test("check selection rejects mistakes before a launch and keeps independent cases", () => {
  assert.deepEqual(parseChecks([]), ["delete-loaded", "delete-unloaded", "crash-before-relaunch", "crash-after-tombstone", "default"]);
  assert.deepEqual(parseChecks(["delete-unloaded", "delete-unloaded", "delete-loaded"]), ["delete-unloaded", "delete-loaded"]);
  assert.throws(() => parseChecks(["--keep-data"]), /unknown check/);
  assert.throws(() => parseChecks(["delete"]), /unknown check/);
  assert.throws(() => parseChecks(["relaunch"]), /unknown check/);
});

test("WebKit identifiers are scoped by canonical data path and engine, with UUID version and variant", () => {
  assert.equal(webkitIdentifier("/private/tmp/ac-delete/data", ""), "f1e11657-6c6c-5ec6-871e-cb6b35ea11c2");
  assert.notEqual(webkitIdentifier("/private/tmp/ac-delete/data", "a"), webkitIdentifier("/private/tmp/ac-delete/data", "b"));
  assert.notEqual(webkitIdentifier("/private/tmp/ac-delete/data", "a"), webkitIdentifier("/private/tmp/ac-other/data", "a"));
});

test("reserved names retire identities before acknowledgement, including Default", () => {
  assert.deepEqual(retiredEngines({ deleted: ["a", ""], reserved: ["b"] }), ["a", "", "b"]);
  assert.deepEqual(retiredEngines(["old"]), ["old"]);
  assert.throws(() => retiredEngines({ deleted: [], reserved: null }), /ledger/);
});

test("polling fails before touching a dead app and preserves predicate failures", async () => {
  let called = false;
  await assert.rejects(waitFor("dead", async () => { called = true; return true; }, { alive: () => false, timeout: 40 }), /exited/);
  assert.equal(called, false);
  await assert.rejects(waitFor("broken", async () => { throw new Error("native snapshot broken"); }, { timeout: 40 }), /native snapshot broken/);
});

test("polling observes state, returns evidence, and enforces its deadline", async () => {
  let polls = 0;
  assert.deepEqual(await waitFor("queue", async () => ++polls === 2 && { queue: [] }, { timeout: 300 }), { queue: [] });
  await assert.rejects(waitFor("stuck orphan", async () => false, { timeout: 35 }), /stuck orphan.*deadline/);
});

test("polling bounds a pending read and notices a death during that read", async () => {
  await assert.rejects(waitFor("hung snapshot", () => new Promise(() => {}), { timeout: 35 }), /hung snapshot.*deadline/);
  let alive = true;
  const timer = setTimeout(() => { alive = false; }, 15);
  try { await assert.rejects(waitFor("lost app", () => new Promise(() => {}), { timeout: 250, alive: () => alive }), /app exited/); }
  finally { clearTimeout(timer); }
});


test("loaded completion requires the target Chromium pending-restart result and no other failed engine", () => {
  assert.equal(pendingRestartLogged("prefix [store] couldn't delete profile data (a): Chromium deletion pending restart\n", "a"), true);
  assert.equal(pendingRestartLogged("[store] couldn't delete profile data (b): Chromium deletion pending restart", "a"), false);
  assert.equal(pendingRestartLogged("[store] couldn't delete profile data (a): Chromium deletion pending restart, WebKit data", "a"), false);
  assert.equal(pendingRestartLogged("[store] couldn't delete profile data (a): data", "a"), false);
});

test("retirement rejects both resurrected profile ids and reused data ids", () => {
  const record = { profile: { id: "a" }, dirs: { engine: "a-data" } };
  assertRetired({ profiles: { b: { id: "b" } } }, record);
  assert.throws(() => assertRetired({ profiles: { a: { id: "a" } } }, record), /absent/);
  assert.throws(() => assertRetired({ profiles: { b: { id: "b", dataId: "a-data" } } }, record), /reuses/);
});

function scenarioRun(loaded) {
  const fixture = Object.fromEntries(["A", "B", "Default"].map((id) => [id, { profile: { id }, dirs: { engine: id } }]));
  let launch = 1, deleted = false, queue = false, pagesClosed = false, pendingObserved = false;
  const evidence = { restarts: 0, survivorReads: 0, unusedChecks: 0, drainLaunches: [], startupDeletes: 0 };
  const run = {
    async loaded(record) { assert.equal(record, fixture.A); assert.ok(loaded && launch === 1 && !deleted); },
    async closePages(record, fallback) { assert.equal(record, fixture.A); assert.equal(fallback, fixture.B); pagesClosed = true; },
    async flush() {},
    async quit() { if (loaded && launch === 1) assert.ok(pendingObserved && queue, "loaded deletion must remain queued through quit"); },
    async start(crashPoint = "", fresh = false, deleteUnloaded = "") {
      launch++; evidence.restarts++;
      if (deleteUnloaded) {
        assert.equal(deleteUnloaded, "A"); assert.ok(!loaded && pagesClosed && launch === 2 && !crashPoint && !fresh);
        deleted = true; queue = true; evidence.startupDeletes++;
      } else if (deleted) queue = false;
    },
    async startupDeleted(record) { assert.equal(record, fixture.A); assert.ok(!loaded && launch === 2 && deleted); },
    async remove(profile) { assert.equal(profile, fixture.A.profile); assert.ok(loaded && launch === 1); deleted = true; queue = true; },
    async queued() { assert.ok(deleted && queue); },
    async pendingLoaded() { assert.ok(loaded && launch === 1 && queue); pendingObserved = true; },
    async drained(engine) {
      assert.equal(engine, "A");
      assert.ok(!loaded || launch > 1, "loaded A must never wait for acknowledgement before restart");
      if (!loaded) assert.ok(pagesClosed);
      queue = false; evidence.drainLaunches.push(launch);
    },
    async gone() { assert.ok(deleted && !queue, "absence asserted only after automatic acknowledgement"); },
    async intact(record) { assert.notEqual(record, fixture.A, "deleted/unloaded A must never be loaded to read data"); evidence.survivorReads++; },
    async unused() { assert.ok(deleted); evidence.unusedChecks++; },
    ledger() { assert.ok(deleted); return ["A"]; },
  };
  return { fixture, run, evidence };
}

test("loaded deletion checks pending state before quit and automatic drain across two relaunches", async () => {
  const { fixture, run, evidence } = scenarioRun(true);
  await deletionScenario(run, fixture, true);
  assert.equal(evidence.restarts, 2);
  assert.deepEqual(evidence.drainLaunches, [2, 3]);
  assert.equal(evidence.survivorReads, 6);
  assert.equal(evidence.unusedChecks, 3);
  assert.equal(evidence.startupDeletes, 0);
});

test("unloaded deletion materializes before restart and drains before the next quit without touching A", async () => {
  const { fixture, run, evidence } = scenarioRun(false);
  await deletionScenario(run, fixture, false);
  assert.equal(evidence.restarts, 2);
  assert.deepEqual(evidence.drainLaunches, [2, 3]);
  assert.equal(evidence.survivorReads, 4);
  assert.equal(evidence.unusedChecks, 2);
  assert.equal(evidence.startupDeletes, 1);
});


test("leftovers report exact existing absolute paths once, including unseeded identities", () => {
  const paths = ["/Users/test/Library/WebKit/WebsiteDataStore/b", "/Users/test/Library/WebKit/dev.solara/WebsiteDataStore/default", "/Users/test/Library/WebKit/WebsiteDataStore/replacement"];
  const lines = [];
  const existing = new Set(paths);
  assert.deepEqual(reportLeftovers([...paths, paths[0], "/Users/test/Library/WebKit/WebsiteDataStore/deleted"], (line) => lines.push(line), (path) => existing.has(path)), [...paths].sort());
  assert.deepEqual(lines, [...paths].sort().map((path) => `[profile-delete] leftover ${path}`));
  assert.deepEqual(reportLeftovers(paths, () => assert.fail("no leftover should be logged"), () => false), []);
});

test("pending crash evidence rejects another engine, another exit point, missing Chromium and surviving WebKit", () => {
  const record = { dirs: { engine: "a", chromium: "/scratch/Chromium/Profile a", webkit: ["/Library/WebKit/a", "/Library/WebKit/bundle/a"] } };
  const output = "prefix [store] couldn't delete profile data (a): Chromium deletion pending restart\n[profile-delete] point pending-restart a\n";
  const exists = (path) => path === record.dirs.chromium;
  assertPendingCrash(record, output, exists);
  assert.throws(() => assertPendingCrash(record, output.replace("(a)", "(b)"), exists), /target Chromium/);
  assert.throws(() => assertPendingCrash(record, output.replace("pending-restart a", "pending-restart b"), exists), /hook fired/);
  assert.throws(() => assertPendingCrash(record, output.replace("pending-restart a", "after-ledger"), exists), /hook fired/);
  assert.throws(() => assertPendingCrash(record, output, () => false), /still needs deletion/);
  for (const path of record.dirs.webkit) assert.throws(() => assertPendingCrash(record, output, (candidate) => exists(candidate) || candidate === path), /WebKit removed/);
});

function crashingRun() {
  const fixture = Object.fromEntries(["A", "B", "Default"].map((id) => [id, { profile: { id }, dirs: { engine: id } }]));
  let launch = 1, deleted = false, queued = false, crashVerified = false;
  const evidence = { starts: [], drains: [], survivorReads: [], reuseChecks: 0 };
  const run = {
    app: { exited: false },
    async flush() { assert.ok(!deleted || launch > 2, "no flush may rescue pending deletion before crash"); },
    async quit() {
      if (launch === 2) assert.ok(run.app.exited && crashVerified, "no graceful quit before verified app crash");
      if (launch === 3) assert.ok(!queued, "first recovery launch must drain before quitting");
    },
    async start(point = "") {
      launch++; run.app.exited = false; evidence.starts.push(point);
      assert.equal(point, launch === 2 ? "pending-restart" : "", "every recovery launch is unarmed");
    },
    async loaded(record) { assert.equal(record, fixture.A); assert.equal(launch, 2); assert.ok(!deleted); },
    async remove(profile) {
      assert.equal(profile, fixture.A.profile); assert.equal(launch, 2);
      deleted = true; queued = true; run.app.exited = true;
      throw Object.assign(new Error("app hook exited"), { appDied: true });
    },
    async crashed(record, point) {
      assert.equal(record, fixture.A); assert.equal(point, "pending-restart");
      assert.ok(run.app.exited && deleted && queued); crashVerified = true;
    },
    ledger() { assert.ok(deleted); return ["A"]; },
    async drained(engine) { assert.equal(engine, "A"); assert.ok(launch >= 3 && crashVerified); queued = false; evidence.drains.push(launch); },
    async gone(record) { assert.equal(record, fixture.A); assert.ok(deleted && !queued); },
    async intact(record) { assert.notEqual(record, fixture.A); evidence.survivorReads.push(launch); },
    async unused(record) { assert.equal(record, fixture.A); assert.ok(!queued); evidence.reuseChecks++; },
  };
  return { fixture, run, evidence };
}

test("pending-restart crash recovers on the first unarmed launch before any quit and preserves survivors", async () => {
  const { fixture, run, evidence } = crashingRun();
  await crashBeforeRelaunch(run, fixture);
  assert.deepEqual(evidence.starts, ["pending-restart", "", ""]);
  assert.deepEqual(evidence.drains, [3, 4]);
  assert.deepEqual(evidence.survivorReads, [2, 2, 3, 3, 4, 4]);
  assert.equal(evidence.reuseChecks, 2);
});

test("pending-restart recovery stops when crash evidence fails or deletion fails while app is alive", async () => {
  const { fixture, run, evidence } = crashingRun();
  run.crashed = async () => { throw new Error("durable orphan missing"); };
  await assert.rejects(crashBeforeRelaunch(run, fixture), /durable orphan missing/);
  assert.deepEqual(evidence.starts, ["pending-restart"]);
  const alive = crashingRun();
  alive.run.remove = async () => { throw new Error("delete command failed"); };
  await assert.rejects(crashBeforeRelaunch(alive.run, alive.fixture), /delete command failed/);
  assert.deepEqual(alive.evidence.starts, ["pending-restart"]);
});


test("native snapshots track Default and newly created identities before profile matching can fail", async () => {
  const run = new Run({}, "/private/tmp/ac-profile-delete/check");
  run.bundleId = "dev.solara";
  let profiles = { default: { id: "default" } };
  run.eval = async () => ({ data: { profiles, orphanedProfileData: [] } });
  await run.native();
  const defaultIdentifier = webkitIdentifier(run.data, "");
  assert.equal([...run.webkitPaths].filter((path) => path.endsWith(`/${defaultIdentifier}`)).length, 2);
  profiles = { ...profiles, replacement: { id: "replacement", name: "Replacement", dataId: "replacement-data" } };
  run.eval = async (body) => body.includes("createProfile") ? "replacement" : { data: { profiles, orphanedProfileData: [] } };
  run.wait = async () => { throw new Error("profile matching failed"); };
  await assert.rejects(run.create("Replacement"), /profile matching failed/);
  const replacementIdentifier = webkitIdentifier(run.data, "replacement-data");
  assert.equal([...run.webkitPaths].filter((path) => path.endsWith(`/${replacementIdentifier}`)).length, 2);
  assert.equal(run.webkitPaths.size, 4, "repeated snapshots deduplicate paths and retain earlier identities");
});
