import assert from "node:assert/strict";
import { test } from "node:test";
import { profileLaunchTargets, regularEngineFor } from "./profileLoading.ts";

const profile = (id, dataId) => ({ id, ...(dataId ? { dataId } : {}) });
const state = () => ({
  profiles: Object.fromEntries(["default", ...Array.from({ length: 7 }, (_, i) => `p${i + 1}`)].map((id) => [id, profile(id)])),
  windows: { first: { profileId: "p3", incognito: false }, second: { profileId: "p5", incognito: false } },
  settings: { loadAllProfilesAtLaunch: false },
});

test("eight saved profiles request only the two profiles shown in restored windows", () => {
  assert.deepEqual(profileLaunchTargets(state()), ["p3", "p5"]);
});

test("the launch preference admits all distinct regular engines", () => {
  const s = state();
  s.settings.loadAllProfilesAtLaunch = true;
  s.profiles.p7.dataId = "p3";
  assert.deepEqual(profileLaunchTargets(s), ["", "p1", "p2", "p3", "p4", "p5", "p6"]);
});

test("private windows request their original engine without creating a private context", () => {
  const s = state();
  s.windows = { private: { incognito: true, profileId: "incognito:private@p7", originalProfileId: "p7" } };
  s.profiles.p7.dataId = "default";
  assert.deepEqual(profileLaunchTargets(s), [""]);
  assert.equal(regularEngineFor(s, "incognito:private@p7"), "");
});

test("shared aliases and repeated windows cannot duplicate startup work", () => {
  const s = state();
  s.profiles.p5.dataId = "p3";
  assert.deepEqual(profileLaunchTargets(s), ["p3"]);
});

test("no windows, stale window routes and deleted profiles do not implicitly load Default", () => {
  const s = state();
  s.windows = {};
  assert.deepEqual(profileLaunchTargets(s), []);
  s.windows.old = { profileId: "gone", incognito: false };
  assert.deepEqual(profileLaunchTargets(s), []);
  assert.equal(regularEngineFor(s, "gone"), null);
});

test("a switch requests the new profile without requiring its tabs or metadata from Chrome", () => {
  const s = state();
  s.windows.first.profileId = "p6";
  assert.deepEqual(profileLaunchTargets(s), ["p6", "p5"]);
});
