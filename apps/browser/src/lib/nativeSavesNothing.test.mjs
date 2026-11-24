import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const loader = fileURLToPath(new URL("../test-loader.mjs", import.meta.url));
const leg = fileURLToPath(new URL("./fixtures/savesNothingLeg.mjs", import.meta.url));

function run(state, message = "present") {
  const child = spawnSync(process.execPath, ["--no-warnings", "--import", loader, leg, state, message], { encoding: "utf8", timeout: 60_000 });
  assert.equal(child.status, 0, `${state}/${message} exited ${child.status}: ${child.stderr}`);
  return JSON.parse(child.stdout.slice(child.stdout.indexOf("{")));
}

const USER_DATA = /^(write|save|remove) (session\.json|downloads\.json|launch-look\.json|sync|onboarding\.json|release-notes\.json)/;

for (const state of ["inactive", "refused", "safeRefused", "frozen", "nullSnapshot", "snapshotThrows", "statusThrows", "noModule"]) {
  test(`with the store ${state}, JS saves nothing for the rest of the session`, () => {
    const r = run(state);
    assert.equal(r.started, null, "startPersistence doesn't throw");
    assert.deepEqual(r.readsAtStart.filter((name) => name === "session.json" || name === "downloads.json"), [], "the JS session isn't read");
    assert.deepEqual(r.changes.filter((change) => USER_DATA.test(change)), [], "no user data is written or removed, before or after a resumed quit");
    assert.ok(r.session && r.downloads, "session.json and downloads.json are byte-identical");
    assert.equal(r.launchLook, false, "no launch-look.json at either final flush");
    assert.equal(r.latch, true, "the persistence latch is set");
    assert.equal(r.sync?.status, "unavailable", "sync is held");
    assert.ok(r.errors.some((e) => e.includes("saves nothing")), r.errors.join("\n"));
    assert.equal(r.presented.length, 1, "the native window is asked for once");
    assert.equal(r.alerts, 0, "no Alert when the native window shows");
    assert.match(r.live, /Live Folders are paused/, "Live Folders commands are held");
    assert.equal(r.onboardingStarted, false, "onboarding doesn't start, so its native session never writes onboarding.json");
  });
}

for (const state of ["inactive", "noModule"]) for (const message of ["missing", "refuses", "throws"]) {
  test(`${state}: when the native window ${message === "missing" ? "isn't in this build" : message === "refuses" ? "declines" : "throws"}, the Alert shows instead and nothing is saved`, () => {
    const r = run(state, message);
    assert.equal(r.alerts, 1);
    assert.equal(r.latch, true);
    assert.deepEqual(r.changes.filter((change) => USER_DATA.test(change)), []);
  });
}

test("control: an owned store hydrates from native, sets no latch and writes launch-look.json at quit", () => {
  const r = run("owned");
  assert.equal(r.latch, false);
  assert.equal(r.presented.length, 0);
  assert.equal(r.alerts, 0);
  assert.equal(r.launchLook, true);
  assert.doesNotMatch(r.live, /paused/, "Live Folders commands aren't held");
  assert.deepEqual(r.changes.filter((change) => /^(write|save) (session|downloads)\.json/.test(change)), [], "the native store owns the session files");
});

test("a handed-off launch saves nothing, even after a resumed quit, and asks for no window", () => {
  const r = run("handoff");
  assert.equal(r.presented.length, 0);
  assert.equal(r.alerts, 0);
  assert.equal(r.latch, true);
  assert.equal(r.launchLook, false);
  assert.match(r.live, /Live Folders are paused/);
  assert.deepEqual(r.changes.filter((change) => USER_DATA.test(change)), []);
});
